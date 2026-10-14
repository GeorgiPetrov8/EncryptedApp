'use strict';

/**
 * Outbound email, no dependencies.
 *
 * Production: set RESEND_API_KEY and MAIL_FROM (any provider with a simple
 * HTTPS JSON API works the same way).
 * Development: with no key, the message is printed to the console so codes can
 * be read from the terminal. In production that is OFF unless MAIL_DEV_LOG=1 —
 * a code in a log file is a code anyone with log access can use.
 *
 * Never throws; returns whether the provider accepted the message. Callers must
 * not tell the client — that would reveal which usernames have a recovery email.
 */
function isConfigured() {
  return Boolean(process.env.RESEND_API_KEY && process.env.MAIL_FROM);
}

async function sendMail({ to, subject, text }) {
  if (!isConfigured()) {
    if (process.env.NODE_ENV !== 'production' || process.env.MAIL_DEV_LOG === '1') {
      console.log(`\n[mail] to=${to}\n[mail] subject=${subject}\n${text}\n`);
    } else {
      console.error('[mail] not configured (RESEND_API_KEY / MAIL_FROM): a message was NOT sent');
    }
    return false;
  }
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: process.env.MAIL_FROM, to: [to], subject, text }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      const detail = (await res.text().catch(() => '')).slice(0, 300);
      console.error(`[mail] provider rejected message: HTTP ${res.status} ${detail}`);
    }
    return res.ok;
  } catch (err) {
    console.error('[mail] send failed:', err.message);
    return false;
  }
}

module.exports = { sendMail, isConfigured };
