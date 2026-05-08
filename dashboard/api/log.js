const { put } = require('@vercel/blob');
const crypto = require('crypto');

const REQUIRED_FIELDS = ['ts', 'triage', 'task'];
const VALID_TIERS = ['Trivial', 'Small Scope', 'Complex', 'Investigative'];

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

  const token = process.env.PBT_API_TOKEN;
  if (token) {
    const auth = req.headers.authorization;
    if (!auth || auth !== `Bearer ${token}`) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  }

  const entry = req.body;
  if (!entry || typeof entry !== 'object') {
    return res.status(400).json({ error: 'Body must be a JSON object' });
  }

  for (const field of REQUIRED_FIELDS) {
    if (!entry[field]) {
      return res.status(400).json({ error: `Missing required field: ${field}` });
    }
  }

  if (!VALID_TIERS.includes(entry.triage)) {
    return res.status(400).json({ error: `Invalid triage tier: ${entry.triage}` });
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
