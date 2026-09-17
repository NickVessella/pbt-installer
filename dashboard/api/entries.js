const { list } = require('@vercel/blob');

const LEGACY_PREFIX = 'pbt-entries.jsonl';
const PER_ENTRY_PREFIX = 'pbt-entry/';
const LIST_PAGE_SIZE = 1000;
/** Cap concurrent blob downloads to avoid EMFILE / DNS EBUSY in serverless. */
const FETCH_CONCURRENCY = 20;

async function mapPool(items, concurrency, fn) {
  const results = new Array(items.length);
  let next = 0;

  async function worker() {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  }

  const workers = Array.from({ length: Math.min(concurrency, items.length) }, () => worker());
  await Promise.all(workers);
  return results;
}

async function fetchBlobText(blob) {
  const headers = {};
  const token = process.env.BLOB_READ_WRITE_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;

  // A thrown fetch — which is exactly what EMFILE/DNS exhaustion produces —
  // used to reject the whole pool and 500 the entire dashboard load. One bad
  // socket should cost one entry, not the page. Returning '' drops just this
  // blob; the caller already filters empties.
  try {
    const response = await fetch(blob.downloadUrl, {
      headers,
      cache: 'no-store',
    });
    if (!response.ok) return '';
    return await response.text();
  } catch (err) {
    console.error('Blob read failed for', blob.pathname, '-', String(err && err.message || err));
    return '';
  }
}

async function readLegacy() {
  const { blobs } = await list({ prefix: LEGACY_PREFIX, limit: 1 });
  if (blobs.length === 0) return [];
  const text = await fetchBlobText(blobs[0]);
  if (!text) return [];
  return text
    .split('\n')
    .filter((line) => line.trim())
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function readPerEntry() {
  const all = [];
  let cursor;
  do {
    const result = await list({
      prefix: PER_ENTRY_PREFIX,
      limit: LIST_PAGE_SIZE,
      cursor,
    });
    all.push(...result.blobs);
    cursor = result.cursor;
  } while (cursor);

  const texts = await mapPool(all, FETCH_CONCURRENCY, fetchBlobText);
  return texts
    .map((text) => {
      if (!text) return null;
      try {
        return JSON.parse(text);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Cache-Control', 's-maxage=10, stale-while-revalidate=30');

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const limit = Math.min(parseInt(req.query.limit) || 1000, 5000);
  const offset = parseInt(req.query.offset) || 0;

  try {
    const [legacy, perEntry] = await Promise.all([readLegacy(), readPerEntry()]);
    const entries = [...legacy, ...perEntry];

    entries.sort((a, b) => {
      const ta = new Date(a.ts).getTime() || 0;
      const tb = new Date(b.ts).getTime() || 0;
      return tb - ta;
    });

    const total = entries.length;
    const page = entries.slice(offset, offset + limit);

    return res.status(200).json({ entries: page, total, limit, offset });
  } catch (err) {
    console.error('Blob read error:', err);
    return res.status(500).json({ error: 'Failed to read entries', detail: String(err) });
  }
};
