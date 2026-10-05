'use strict';

/**
 * Outbound email, zero dependencies.
 *
 * Production: set RESEND_API_KEY and MAIL_FROM (any provider with a simple
 * HTTPS JSON API works the same way — swap the URL/body below).
 * Development: with no key configured the message is printed to the server
 * console, so verification codes can be read from the terminal.
 *
 * Never throws. Callers must not reveal to the client whether a mail was
 * actually sent — that would let anyone probe which usernames have a
 * recovery email.
 */
async function sendMail({ to, subject, text }) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    console.log(`\n[mail] to=${to}\n[mail] subject=${subject}\n${text}\n`);
    return;
  }
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: process.env.MAIL_FROM, to: [to], subject, text }),
    });
    if (!res.ok) console.error(`[mail] provider rejected message: HTTP ${res.status}`);
  } catch (err) {
    console.error('[mail] send failed:', err.message);
  }
}

module.exports = { sendMail };
