'use strict';

const { sendJson, sendError } = require('../json');
const { readBody } = require('../router');
const { requireAuth } = require('../auth');
const { rateLimit } = require('../rateLimit');
const { Ntfy } = require('../ntfy');

/** GET /devices/ntfy -> { enabled, topic } */
function getNtfyRoute(store, ntfy) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    const topic = ntfy.topicFor(req.userId);
    sendJson(res, 200, { enabled: Boolean(topic), topic });
  };
}

/** POST /devices/ntfy { topic } -> 204   (topic: null turns it off) */
function setNtfyRoute(store, limiters, ntfy) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.prekeys, req, res)) return;
    const body = await readBody(req);
    if (body.topic === null) {
      ntfy.removeTopic(req.userId);
      return res.writeHead(204).end();
    }
    if (!Ntfy.isValidTopic(body.topic)) {
      return sendError(res, 400, 'badRequest', 'The topic must be 20–64 letters, digits, - or _.');
    }
    ntfy.setTopic(req.userId, body.topic);
    res.writeHead(204).end();
  };
}

/** POST /devices/ntfy/test -> { sent } */
function testNtfyRoute(store, limiters, ntfy) {
  const auth = requireAuth(store);
  return async (req, res) => {
    if (!auth(req, res)) return;
    if (!rateLimit(limiters.auth, req, res)) return;
    const topic = ntfy.topicFor(req.userId);
    if (!topic) return sendError(res, 409, 'notEnabled', 'Turn notifications on first.');
    const sent = await ntfy.publish(topic, {
      title: 'HyperChat',
      body: 'Notifications are working.',
      tags: 'white_check_mark',
    });
    if (!sent) return sendError(res, 502, 'ntfyUnreachable', "Couldn't reach the notification service.");
    sendJson(res, 200, { sent: true });
  };
}

module.exports = { getNtfyRoute, setNtfyRoute, testNtfyRoute };
