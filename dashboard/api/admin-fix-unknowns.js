// One-shot admin migration: rewrite user="unknown"|null|"" to a target user
// across the legacy pbt-entries.jsonl blob and per-entry pbt-entry/*.json blobs.
//
// SECURITY: gated by a hardcoded admin key. Will be removed after migration.

const { list, put } = require('@vercel/blob');

const ADMIN_KEY = '40b23014-2e88-4139-8916-311ea6d4ec43';
const LEGACY_PATH = 'pbt-entries.jsonl';
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

// Fix EVERY blob whose pathname starts with pbt-entries.jsonl (handles versioning suffixes).
async function fixLegacy(targetUser, dryRun) {
  const all = [];
  let cursor;
  do {
    const r = await list({ prefix: LEGACY_PATH, limit: 100, cursor });
    all.push(...r.blobs);
    cursor = r.cursor;
  } while (cursor);

  const result = { matchedBlobs: all.length, blobs: [] };
  for (const blob of all) {
    const text = await fetchBlobText(blob);
    const lines = text.split('\n');
    let fixed = 0;
    const out = [];
    for (const line of lines) {
      if (!line.trim()) { out.push(line); continue; }
      let entry;
      try { entry = JSON.parse(line); } catch { out.push(line); continue; }
      if (SHOULD_FIX(entry.user)) {
        entry.user = targetUser;
        fixed += 1;
      }
      out.push(JSON.stringify(entry));
    }
    const blobInfo = {
      pathname: blob.pathname,
      sizeBytes: blob.size,
      totalLines: lines.length,
      fixed,
      applied: false,
    };
    if (fixed > 0 && !dryRun) {
      await put(blob.pathname, out.join('\n'), {
        access: 'private',
        addRandomSuffix: false,
        allowOverwrite: true,
        contentType: 'application/json',
      });
      blobInfo.applied = true;
    }
    result.blobs.push(blobInfo);
  }
  return result;
}

async function fixPerEntry(targetUser, dryRun) {
  const all = [];
  let cursor;
  do {
    const r = await list({ prefix: PER_ENTRY_PREFIX, limit: 1000, cursor });
    all.push(...r.blobs);
    cursor = r.cursor;
  } while (cursor);

  let fixed = 0;
  const errors = [];
  for (const b of all) {
    let entry;
    try {
      const txt = await fetchBlobText(b);
      entry = JSON.parse(txt);
    } catch (e) {
      errors.push({ pathname: b.pathname, error: String(e).slice(0, 120) });
      continue;
    }
    if (!SHOULD_FIX(entry.user)) continue;
    if (!dryRun) {
      entry.user = targetUser;
      await put(b.pathname, JSON.stringify(entry), {
        access: 'private',
        addRandomSuffix: false,
        allowOverwrite: true,
        contentType: 'application/json',
      });
    }
    fixed += 1;
  }
  return { totalBlobs: all.length, fixed, errors, applied: !dryRun };
}

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST required' });
  if (req.headers['x-admin-key'] !== ADMIN_KEY) {
    return res.status(401).json({ error: 'invalid admin key' });
  }
  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const targetUser = body.targetUser;
  const dryRun = body.dryRun !== false;
  if (!targetUser) return res.status(400).json({ error: 'targetUser required' });
  try {
    const t0 = Date.now();
    const legacy = await fixLegacy(targetUser, dryRun);
    const perEntry = await fixPerEntry(targetUser, dryRun);
    return res.status(200).json({
      ok: true, targetUser, dryRun, durationMs: Date.now() - t0, legacy, perEntry,
    });
  } catch (err) {
    return res.status(500).json({ error: String(err), stack: err && err.stack });
  }
};
