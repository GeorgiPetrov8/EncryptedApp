'use strict';

/** Converts a `pending_envelopes` row back into the wire-shape `EnvelopeDTO` JSON. */
function rowToEnvelopeDTO(row) {
  return {
    id: row.envelope_id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    recipientId: row.recipient_id,
    kind: row.kind,
    handshake: row.handshake_json ? JSON.parse(row.handshake_json) : null,
    ratchetMessage: row.ratchet_message, // already base64
    contentType: row.content_type,
    createdAt: row.created_at, // already ISO-8601
  };
}

module.exports = { rowToEnvelopeDTO };
