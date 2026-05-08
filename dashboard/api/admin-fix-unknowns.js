// One-shot admin migration + introspection.
const { list, put } = require('@vercel/blob');

const ADMIN_KEY = '40b23014-2e88-4139-8916-311ea6d4ec43';
const SHOULD_FIX = (u) => u === undefined || u === null || u === '' || u === 'unknown';

async function fetchBlobText(blob) {
  const r = await fetch(blob.downloadUrl, {
    headers: { Authorization: `Bearer ${process.env.BLOB_READ_WRITE_TOKEN}` },
    cache: 'no-store',
  });
  if (!r.ok) throw new Error(`fetch ${blob.pathname}: ${r.status}`);
  return r.text();
}

async function listAllBlobs() {
  const all = [];
  let cursor;
  do {
    const r = await list({ limit: 1000, cursor });
    all.push(...r.blobs);
    cursor = r.cursor;
  } while (cursor);
  return all;
}

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST required' });
  if (req.headers['x-admin-key'] !== ADMIN_KEY) {
    return res.status(401).json({ error: 'invalid admin key' });
  }
  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const action = body.action || 'inspect';
  const targetUser = body.targetUser;
  const dryRun = body.dryRun !== false;

  try {
    const all = await listAllBlobs();

    // Group blobs by inferred kind
    const byPrefix = {};
    for (const b of all) {
      const seg = b.pathname.split('/')[0];
      const kind = seg.includes('.jsonl') ? 'jsonl-files' : seg;
      byPrefix[kind] = byPrefix[kind] || [];
      byPrefix[kind].push(b);
    }

    if (action === 'inspect') {
      const summary = {};
      for (const [kind, blobs] of Object.entries(byPrefix)) {
        let unknownLines = 0;
        let totalLines = 0;
        const samples = [];
        for (const b of blobs) {
          let text;
          try { text = await fetchBlobText(b); } catch (e) { continue; }
          const lines = text.split('\n').filter(l => l.trim());
          totalLines += lines.length;
          for (const ln of lines) {
            try {
              const e = JSON.parse(ln);
              if (SHOULD_FIX(e.user)) {
                unknownLines += 1;
                if (samples.length < 3) {
                  samples.push({ blob: b.pathname, ts: e.ts, user: e.user });
                }
              }
            } catch {}
          }
        }
        summary[kind] = {
          blobCount: blobs.length,
          totalSize: blobs.reduce((s, b) => s + (b.size || 0), 0),
          totalLines,
          unknownLines,
          samples,
          allPaths: blobs.slice(0, 10).map(b => `${b.pathname} (${b.size}B)`),
        };
      }
      return res.status(200).json({ ok: true, totalBlobs: all.length, summary });
    }

    if (action === 'fix') {
      if (!targetUser) return res.status(400).json({ error: 'targetUser required for fix action' });
      let totalFixed = 0;
      const blobsRewritten = [];
      for (const b of all) {
        if (b.pathname.includes('.jsonl')) {
          // jsonl-style multi-line file
          let text;
          try { text = await fetchBlobText(b); } catch (e) { continue; }
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
          if (fixed > 0) {
            if (!dryRun) {
              await put(b.pathname, out.join('\n'), {
                access: 'private', addRandomSuffix: false, allowOverwrite: true,
                contentType: 'application/json',
              });
            }
            totalFixed += fixed;
            blobsRewritten.push({ pathname: b.pathname, type: 'jsonl', fixed, applied: !dryRun });
          }
        } else {
          // single-entry json
          let text;
          try { text = await fetchBlobText(b); } catch (e) { continue; }
          let entry;
          try { entry = JSON.parse(text); } catch { continue; }
          if (SHOULD_FIX(entry.user)) {
            if (!dryRun) {
              entry.user = targetUser;
              await put(b.pathname, JSON.stringify(entry), {
                access: 'private', addRandomSuffix: false, allowOverwrite: true,
                contentType: 'application/json',
              });
            }
            totalFixed += 1;
            blobsRewritten.push({ pathname: b.pathname, type: 'json', fixed: 1, applied: !dryRun });
          }
        }
      }
      return res.status(200).json({
        ok: true, targetUser, dryRun, totalFixed,
        rewritten: blobsRewritten.slice(0, 20),
        rewrittenCount: blobsRewritten.length,
      });
    }

    return res.status(400).json({ error: 'unknown action; use inspect or fix' });
  } catch (err) {
    return res.status(500).json({ error: String(err), stack: err && err.stack });
  }
};
