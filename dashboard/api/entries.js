const { list } = require('@vercel/blob');

const LEGACY_PREFIX = 'pbt-entries.jsonl';
const PER_ENTRY_PREFIX = 'pbt-entry/';
const LIST_PAGE_SIZE = 1000;

async function fetchBlobText(blob) {
  const response = await fetch(blob.downloadUrl, {
    headers: { Authorization: `Bearer ${process.env.BLOB_READ_WRITE_TOKEN}` },
    cache: 'no-store',
  });
  if (!response.ok) return '';
  return response.text();
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

  const texts = await Promise.all(all.map(fetchBlobText));
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
