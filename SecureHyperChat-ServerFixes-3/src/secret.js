'use strict';

const crypto = require('node:crypto');

/**
 * The server-side secret for keyed hashes (recovery codes, decoy challenges).
 * Required in production; generated per process in development.
 */
let developmentSecret = null;

function serverSecret() {
  if (process.env.CODE_SECRET) return process.env.CODE_SECRET;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('CODE_SECRET is required in production (openssl rand -hex 32)');
  }
  developmentSecret ??= crypto.randomBytes(32).toString('hex');
  return developmentSecret;
}

module.exports = { serverSecret };
