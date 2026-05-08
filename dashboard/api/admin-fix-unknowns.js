// One-shot admin migration: rewrite user="unknown"|null|"" to a target user
// across the legacy pbt-entries.jsonl blob and per-entry pbt-entry/*.json blobs.
//
// SECURITY: gated by a hardcoded admin key. This file is committed only for
// the duration of the migration, then removed in a follow-up commit. Do NOT
// leave deployed.
//
// Usage:
//   POST /api/admin-fix-unknowns
//   Header: x-admin-key: <key>
//   Header: x-vercel-protection-bypass: <bypass>
//   Body:   {"targetUser":"nick.vessella","dryRun":false}

const { list, put } = require('@vercel/blob');

const ADMIN_KEY = '40b23014-2e88-4139-8916-311ea6d4ec43';
const LEGACY_KEY = 'pbt-entries.jsonl';
const PER_ENTRY_PREFIX = 'pbt-entry/';

const SHOULD_FIX = (u) => u === undefined || u === null || u === '' || u === 'unknown';

async function fetchBlobText(blob) {
  const r = await fetch(blob.downloadUrl, {
    headers: { Authorization: `Bearer ${process.env.BLOB_READ_WRITE_TOKEN}` },
    cache: 'no-store',
  });
  if (!r.ok) throw new Error(`fetch ${blob.pathname}: ${r.status}`);
  return r.text();
}

async function fixLegacy(targetUser, dryRun) {
  const result = await list({ prefix: LEGACY_KEY, limit: 5 });
  const blob = result.blobs.find((b) => b.pathname === LEGACY_KEY);
  if (!blob) return { found: false, fixed: 0 };

  const text = await fetchBlobText(blob);
  const lines = text.split('\n');
  let fixed = 0;
  const out = [];
  const samples = [];
  for (const line of lines) {
    if (!line.trim()) { out.push(line); continue; }
    let entry;
    try { entry = JSON.parse(line); } catch { out.push(line); continue; }
    if (SHOULD_FIX(entry.user)) {
      if (samples.length < 3) {
        samples.push({ ts: entry.ts, was: entry.user, task: (entry.task || '').slice(0, 60) });
      }
      entry.user = targetUser;
      fixed += 1;
    }
    out.push(JSON.stringify(entry));
  }

  if (fixed > 0 && !dryRun) {
    await put(LEGACY_KEY, out.join('\n'), {
      access: 'public',
      addRandomSuffix: false,
      allowOverwrite: true,
      contentType: 'application/json',
    });
  }

  return { found: true, totalLines: lines.length, fixed, samples, applied: !dryRun };
}

async function fixPerEntry(targetUser, dryRun) {
  const all = [];
  let cursor;
  do {
    const r = await list({ prefix: PER_ENTRY_PREFIX, limit: 1000, cursor });
    all.push(...r.blobs);
    cursor = r.cursor;
  } while (cursor);

  const samples = [];
  let fixed = 0;
  let scanned = 0;
  const errors = [];

  for (const b of all) {
    scanned += 1;
    let entry;
    try {
      const txt = await fetchBlobText(b);
      entry = JSON.parse(txt);
    } catch (e) {
      errors.push({ pathname: b.pathname, error: String(e).slice(0, 120) });
      continue;
    }
    if (!SHOULD_FIX(entry.user)) continue;
    if (samples.length < 3) {
      samples.push({ ts: entry.ts, was: entry.user, pathname: b.pathname });
    }
    if (!dryRun) {
      entry.user = targetUser;
      await put(b.pathname, JSON.stringify(entry), {
        access: 'public',
        addRandomSuffix: false,
        allowOverwrite: true,
        contentType: 'application/json',
      });
    }
    fixed += 1;
  }

  return { totalBlobs: all.length, scanned, fixed, samples, errors, applied: !dryRun };
}

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'POST required' });
  }
  const key = req.headers['x-admin-key'];
  if (key !== ADMIN_KEY) {
    return res.status(401).json({ error: 'invalid admin key' });
  }

  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const targetUser = body.targetUser;
  const dryRun = body.dryRun !== false;

  if (!targetUser || typeof targetUser !== 'string') {
    return res.status(400).json({ error: 'targetUser required' });
  }

  try {
    const t0 = Date.now();
    const legacy = await fixLegacy(targetUser, dryRun);
    const perEntry = await fixPerEntry(targetUser, dryRun);
    return res.status(200).json({
      ok: true,
      targetUser,
      dryRun,
      durationMs: Date.now() - t0,
      legacy,
      perEntry,
    });
  } catch (err) {
    return res.status(500).json({ error: String(err), stack: err && err.stack });
  }
};
