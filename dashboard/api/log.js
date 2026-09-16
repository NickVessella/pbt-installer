const { put } = require('@vercel/blob');
const crypto = require('crypto');

// Generated from shared/lib/pbt_schema.py — the single source of truth for the
// 27-field contract. This handler used to carry its own
// ['ts','triage','task'] check, which was the fourth hand-copied version of a
// rule already replaced everywhere else; entries stored here were unvalidated
// for the other 24 fields.
const { normalize } = require('./_pbt-schema');

function safeSegment(value, max = 64) {
  return String(value || 'unknown')
    .replace(/[^A-Za-z0-9._-]/g, '_')
    .slice(0, max);
}

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  // Fail closed. This used to read `if (token) { ...require it... }`, which
  // meant "authenticate only if someone remembered to configure it" — and
  // PBT_API_TOKEN was never set on the project, so the branch never ran and
  // this write endpoint had no application-level auth at all. Vercel
  // Deployment Protection was the only gate, and its bypass secret had been
  // published through a public CDN.
  //
  // A missing token is now a server misconfiguration (503), not an open door.
  const token = process.env.PBT_API_TOKEN;
  if (!token) {
    console.error('PBT_API_TOKEN is not configured — refusing writes');
    return res.status(503).json({
      error: 'Server misconfigured: PBT_API_TOKEN is not set. ' +
             'Writes are refused rather than accepted unauthenticated.',
    });
  }

  const auth = req.headers.authorization || '';
  const expected = `Bearer ${token}`;
  const provided = Buffer.from(auth);
  const wanted = Buffer.from(expected);
  // Constant-time compare; lengths must match first or timingSafeEqual throws.
  if (provided.length !== wanted.length || !crypto.timingSafeEqual(provided, wanted)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  // Normalize rather than reject: a 400 here used to mean the entry was lost
  // outright (see the HTTP 400 skips in ~/.pbt-sync-errors.log for lines 837,
  // 1089, 1122 and 1144 — four entries the local gate let through and the
  // dashboard then dropped). Now only an unrecoverable entry is refused, and
  // everything else is stored in canonical 27-field shape.
  const { entry, changes, fatal } = normalize(req.body);
  if (fatal.length) {
    return res.status(400).json({ error: fatal.join('; ') });
  }
  if (changes.length) {
    console.log('normalized entry', entry.ts, changes.length, 'field(s):', changes.join('; '));
  }

  // Per-entry storage: each POST writes its own blob, eliminating the
  // read-modify-write race that lost concurrent writes under shared-file storage.
  const ts = safeSegment(entry.ts);
  const user = safeSegment(entry.user || 'unknown', 32);
  const rand = crypto.randomBytes(4).toString('hex');
  const pathname = `pbt-entry/${ts}-${user}-${rand}.json`;

  try {
    await put(pathname, JSON.stringify(entry), {
      access: 'private',
      addRandomSuffix: false,
      allowOverwrite: false,
      contentType: 'application/json',
    });
    return res.status(201).json({ ok: true, ts: entry.ts, pathname });
  } catch (err) {
    console.error('Blob write error:', err);
    return res.status(500).json({ error: 'Failed to store entry', detail: String(err) });
  }
};
