'use strict';

const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');

/**
 * A from-scratch RFC 6455 WebSocket server: handshake + frame codec, with no
 * dependency on the `ws` package (which isn't installable in an offline
 * environment, but more importantly doesn't need to be — the protocol is
 * small enough to implement directly and this way there is exactly one thing
 * to audit for the "read frames off a socket" trust boundary).
 *
 * Scope, deliberately: this implements what a single-process chat relay
 * needs — text frames, ping/pong, close, fragmented-message reassembly for
 * *incoming* frames, masking/unmasking — and not permessage-deflate or any
 * other extension. `Sec-WebSocket-Extensions` is never acknowledged in the
 * handshake response, so compliant clients (including
 * `URLSessionWebSocketTask`) fall back to unextended frames automatically.
 */

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OPCODE = { CONTINUATION: 0x0, TEXT: 0x1, BINARY: 0x2, CLOSE: 0x8, PING: 0x9, PONG: 0xa };
const MAX_FRAME_PAYLOAD = 10 * 1024 * 1024; // guards against a peer claiming a huge length

function acceptKeyFor(secWebSocketKey) {
  return crypto.createHash('sha1').update(secWebSocketKey + GUID, 'utf8').digest('base64');
}

/** True if this HTTP upgrade request looks like a real WebSocket handshake. */
function isWebSocketUpgrade(req) {
  return (
    (req.headers['upgrade'] || '').toLowerCase() === 'websocket' &&
    (req.headers['connection'] || '').toLowerCase().includes('upgrade') &&
    typeof req.headers['sec-websocket-key'] === 'string' &&
    req.headers['sec-websocket-version'] === '13'
  );
}

function performHandshake(req, socket, head) {
  const acceptKey = acceptKeyFor(req.headers['sec-websocket-key']);
  const responseHeaders = [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${acceptKey}`,
    '', '',
  ].join('\r\n');
  socket.write(responseHeaders);
  return head;
}

function encodeFrame(opcode, payload) {
  const payloadLen = payload.length;
  let header;
  if (payloadLen < 126) {
    header = Buffer.alloc(2);
    header[1] = payloadLen;
  } else if (payloadLen <= 0xffff) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(payloadLen, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payloadLen), 2);
  }
  header[0] = 0x80 | opcode; // FIN=1, single-frame messages only (outgoing)
  // Server-to-client frames must NOT be masked (RFC 6455 §5.1).
  return Buffer.concat([header, payload]);
}

/**
 * One live connection. Wraps the raw `net.Socket` handed to us by the HTTP
 * server's `upgrade` event and speaks frames over it directly.
 */
class WebSocketConnection extends EventEmitter {
  constructor(socket) {
    super();
    this.socket = socket;
    this._buffer = Buffer.alloc(0);
    this._fragments = null; // { opcode, chunks: Buffer[] } while reassembling
    this._closed = false;

    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('close', () => this._onSocketClose());
    socket.on('error', () => this._onSocketClose());
  }

  sendText(str) {
    if (this._closed) return;
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
    this.emit('close');
    try {
      this.socket.destroy();
    } catch {
      // already destroyed
    }
  }

  _onData(chunk) {
    this._buffer = this._buffer.length ? Buffer.concat([this._buffer, chunk]) : chunk;
    // A single TCP read can contain several frames (or a partial one); drain
    // everything decodable and leave the remainder buffered for next time.
    while (this._tryParseFrame()) {
      /* loop */
    }
  }

  _tryParseFrame() {
    const buf = this._buffer;
    if (buf.length < 2) return false;

    const fin = (buf[0] & 0x80) !== 0;
    const opcode = buf[0] & 0x0f;
    const masked = (buf[1] & 0x80) !== 0;
    let payloadLen = buf[1] & 0x7f;
    let offset = 2;

    if (payloadLen === 126) {
      if (buf.length < offset + 2) return false;
      payloadLen = buf.readUInt16BE(offset);
      offset += 2;
    } else if (payloadLen === 127) {
      if (buf.length < offset + 8) return false;
      const big = buf.readBigUInt64BE(offset);
      if (big > BigInt(MAX_FRAME_PAYLOAD)) {
        this.close(1009, 'message too big');
        return false;
      }
      payloadLen = Number(big);
      offset += 8;
    }

    if (payloadLen > MAX_FRAME_PAYLOAD) {
      this.close(1009, 'message too big');
      return false;
    }

    // A conforming client always masks; a server MUST reject unmasked frames.
    if (!masked) {
      this.close(1002, 'client frames must be masked');
      return false;
    }
    if (buf.length < offset + 4) return false;
    const maskKey = buf.subarray(offset, offset + 4);
    offset += 4;

    if (buf.length < offset + payloadLen) return false; // frame not fully arrived yet

    const maskedPayload = buf.subarray(offset, offset + payloadLen);
    const payload = Buffer.alloc(payloadLen);
    for (let i = 0; i < payloadLen; i++) payload[i] = maskedPayload[i] ^ maskKey[i % 4];

    this._buffer = buf.subarray(offset + payloadLen);
    this._handleFrame(fin, opcode, payload);
    return this._buffer.length > 0;
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
      if (!this._fragments) return; // protocol error from peer; ignore defensively
      this._fragments.chunks.push(payload);
    } else {
      // Start of a new (possibly fragmented) message.
      this._fragments = { opcode, chunks: [payload] };
    }

    if (fin) {
      const full = Buffer.concat(this._fragments.chunks);
      const finishedOpcode = this._fragments.opcode;
      this._fragments = null;
      if (finishedOpcode === OPCODE.TEXT) {
        this.emit('message', full.toString('utf8'));
      }
      // Binary application frames aren't part of this protocol; ignore.
    }
  }
}

module.exports = { isWebSocketUpgrade, performHandshake, WebSocketConnection };
