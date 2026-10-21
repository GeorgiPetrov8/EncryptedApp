'use strict';

const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

/**
 * A from-scratch RFC 6455 WebSocket server: handshake + frame codec, with no
 * dependency on the `ws` package, so there is exactly one thing to audit at the
 * "read frames off a socket" trust boundary.
 *
 * Scope, deliberately: text frames, ping/pong, close, reassembly of fragmented
 * incoming messages, masking. No extensions (permessage-deflate etc.), so
 * `Sec-WebSocket-Extensions` is never acknowledged.
 *
 * Hardened against a hostile client:
 *   - the size of a whole message (not just one frame) is capped, and the cap is
 *     tiny until the connection has authenticated;
 *   - reserved bits, unknown opcodes, oversized or fragmented control frames,
 *     bad continuation order and invalid UTF-8 close the connection;
 *   - a listener that throws can't take the process down;
 *   - a peer that doesn't read can't make us buffer without limit.
 */
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OPCODE = { CONTINUATION: 0x0, TEXT: 0x1, BINARY: 0x2, CLOSE: 0x8, PING: 0x9, PONG: 0xa };
const VALID_OPCODES = new Set(Object.values(OPCODE));
const MAX_WRITE_BACKLOG_BYTES = 1024 * 1024;
const KEY_RE = /^[A-Za-z0-9+/]{22}==$/; // base64 of 16 bytes

const utf8 = new TextDecoder('utf-8', { fatal: true });

function acceptKeyFor(secWebSocketKey) {
  return crypto.createHash('sha1').update(secWebSocketKey + GUID, 'utf8').digest('base64');
}

/** True if this HTTP upgrade request is a well-formed WebSocket handshake. */
function isWebSocketUpgrade(req) {
  const key = req.headers['sec-websocket-key'];
  return (
    (req.headers['upgrade'] || '').toLowerCase() === 'websocket' &&
    (req.headers['connection'] || '').toLowerCase().includes('upgrade') &&
    typeof key === 'string' && KEY_RE.test(key) &&
    req.headers['sec-websocket-version'] === '13'
  );
}

/** Writes the 101 response. Returns `head` — bytes that arrived with the request. */
function performHandshake(req, socket, head) {
  const acceptKey = acceptKeyFor(req.headers['sec-websocket-key']);
  socket.write([
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${acceptKey}`,
    '', '',
  ].join('\r\n'));
  return head;
}

function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[1] = len;
  } else if (len <= 0xffff) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  header[0] = 0x80 | opcode; // FIN=1: outgoing messages are always one frame
  // Server-to-client frames must NOT be masked (RFC 6455 §5.1).
  return Buffer.concat([header, payload]);
}

class WebSocketConnection extends EventEmitter {
  /**
   * @param {import('node:net').Socket} socket
   * @param {{maxMessageBytes?: number}} [options]
   */
  constructor(socket, { maxMessageBytes = 4096 } = {}) {
    super();
    this.socket = socket;
    this._maxMessageBytes = maxMessageBytes;
    this._buffer = Buffer.alloc(0);
    this._fragments = null; // { opcode, chunks } while reassembling
    this._fragmentBytes = 0;
    this._closed = false;

    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('close', () => this._onSocketClose());
    socket.on('error', () => this._onSocketClose());
  }

  /** Raise the per-message cap once the peer has authenticated. */
  setMaxMessageBytes(bytes) {
    this._maxMessageBytes = bytes;
  }

  /** Feeds bytes that arrived before this object existed (the upgrade `head`). */
  feed(chunk) {
    if (chunk && chunk.length) this._onData(chunk);
  }

  sendText(str) {
    if (this._closed) return;
    // A client that stopped reading would otherwise make us queue without limit.
    if (this.socket.writableLength > MAX_WRITE_BACKLOG_BYTES) {
      this.close(1013, 'slow consumer');
      return;
    }
    this.socket.write(encodeFrame(OPCODE.TEXT, Buffer.from(str, 'utf8')));
  }

  ping() {
    if (this._closed) return;
    this.socket.write(encodeFrame(OPCODE.PING, Buffer.alloc(0)));
  }

  close(code = 1000, reason = '') {
    if (this._closed) return;
    const reasonBuf = Buffer.from(reason, 'utf8').subarray(0, 123);
    const payload = Buffer.alloc(2 + reasonBuf.length);
    payload.writeUInt16BE(code, 0);
    reasonBuf.copy(payload, 2);
    try {
      this.socket.write(encodeFrame(OPCODE.CLOSE, payload));
    } catch {
      // socket may already be gone
    }
    this._teardown();
  }

  _onSocketClose() {
    if (this._closed) return;
    this._teardown();
  }

  _teardown() {
    this._closed = true;
    this._buffer = Buffer.alloc(0);
    this._fragments = null;
    this.emit('close');
    try {
      // end() flushes the close frame just written; destroy() would drop it.
      this.socket.end();
      setTimeout(() => this.socket.destroy(), 1000).unref();
    } catch {
      // already destroyed
    }
  }

  _onData(chunk) {
    if (this._closed) return;
    this._buffer = this._buffer.length ? Buffer.concat([this._buffer, chunk]) : chunk;
    while (this._tryParseFrame()) { /* drain every complete frame */ }
  }

  _tryParseFrame() {
    if (this._closed) return false;
    const buf = this._buffer;
    if (buf.length < 2) return false;

    const fin = (buf[0] & 0x80) !== 0;
    if ((buf[0] & 0x70) !== 0) { this.close(1002, 'reserved bits set'); return false; }
    const opcode = buf[0] & 0x0f;
    if (!VALID_OPCODES.has(opcode)) { this.close(1002, 'unknown opcode'); return false; }
    // A conforming client always masks; a server MUST reject unmasked frames.
    if ((buf[1] & 0x80) === 0) { this.close(1002, 'client frames must be masked'); return false; }

    let payloadLen = buf[1] & 0x7f;
    let offset = 2;
    if (payloadLen === 126) {
      if (buf.length < offset + 2) return false;
      payloadLen = buf.readUInt16BE(offset);
      offset += 2;
    } else if (payloadLen === 127) {
      if (buf.length < offset + 8) return false;
      const big = buf.readBigUInt64BE(offset);
      if (big > BigInt(this._maxMessageBytes)) { this.close(1009, 'message too big'); return false; }
      payloadLen = Number(big);
      offset += 8;
    }

    if (opcode >= OPCODE.CLOSE && (!fin || payloadLen > 125)) {
      this.close(1002, 'invalid control frame');
      return false;
    }
    // Checked as soon as the header is read, so a hostile length never makes us
    // wait for (and buffer) a huge payload.
    if (payloadLen > this._maxMessageBytes) { this.close(1009, 'message too big'); return false; }

    if (buf.length < offset + 4) return false;
    const maskKey = buf.subarray(offset, offset + 4);
    offset += 4;
    if (buf.length < offset + payloadLen) return false; // not fully arrived yet

    const masked = buf.subarray(offset, offset + payloadLen);
    const payload = Buffer.alloc(payloadLen);
    for (let i = 0; i < payloadLen; i++) payload[i] = masked[i] ^ maskKey[i % 4];
    this._buffer = buf.subarray(offset + payloadLen);

    this._handleFrame(fin, opcode, payload);
    return !this._closed && this._buffer.length > 0;
  }

  _handleFrame(fin, opcode, payload) {
    if (opcode === OPCODE.CLOSE) {
      this.close(1000, '');
      return;
    }
    if (opcode === OPCODE.PING) {
      if (!this._closed) this.socket.write(encodeFrame(OPCODE.PONG, payload));
      return;
    }
    if (opcode === OPCODE.PONG) {
      this.emit('pong');
      return;
    }

    if (opcode === OPCODE.CONTINUATION) {
      if (!this._fragments) { this.close(1002, 'unexpected continuation'); return; }
      this._fragmentBytes += payload.length;
      // The cap applies to the WHOLE message: it used to apply per frame only,
      // so an endless run of continuation frames could exhaust memory.
      if (this._fragmentBytes > this._maxMessageBytes) { this.close(1009, 'message too big'); return; }
      this._fragments.chunks.push(payload);
    } else {
      if (this._fragments) { this.close(1002, 'new message inside a fragmented one'); return; }
      this._fragments = { opcode, chunks: [payload] };
      this._fragmentBytes = payload.length;
    }

    if (!fin) return;

    const full = Buffer.concat(this._fragments.chunks);
    const finishedOpcode = this._fragments.opcode;
    this._fragments = null;
    this._fragmentBytes = 0;

    if (finishedOpcode !== OPCODE.TEXT) return; // binary frames aren't part of this protocol

    let text;
    try {
      text = utf8.decode(full);
    } catch {
      this.close(1007, 'invalid UTF-8');
      return;
    }
    try {
      this.emit('message', text);
    } catch (err) {
      // A throwing listener runs inside the socket's 'data' handler; letting it
      // escape would be an uncaught exception and kill the whole server.
      console.error('[ws] message listener threw:', err && err.message);
    }
  }
}

module.exports = { isWebSocketUpgrade, performHandshake, WebSocketConnection };
