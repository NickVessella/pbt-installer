# PBT Dashboard

Live: <https://pbt-dashboard.vercel.app>

## Fresh-clone setup

A fresh clone has no `.env.local` and no `.vercel/` link by design.

```bash
cd dashboard
npm install
vercel link               # link to the existing pbt-dashboard Vercel project
vercel env pull           # pulls BLOB_READ_WRITE_TOKEN from Vercel
```

## Deploy

```bash
vercel --prod
```

## Required env vars (set in Vercel project, not in the repo)

| Var | Purpose |
|---|---|
| `BLOB_READ_WRITE_TOKEN` | Vercel Blob access for `api/log.js` and `api/entries.js`. |

## Auth note

The dashboard is behind Vercel deployment protection. Programmatic POSTs to `/api/log` (e.g. from Cursor stop hooks) include the `x-vercel-protection-bypass` header. The bypass token is baked into `install.sh` and refreshed when rotated.

## Architecture

- `api/log.js` — POST endpoint. Each entry is its own blob at `pbt-entry/{ts}-{user}-{rand}.json` to avoid concurrent-write races.
- `api/entries.js` — GET endpoint. Aggregates entries from both the legacy `pbt-entries.jsonl` blob and the per-entry `pbt-entry/` prefix.
- `scripts/backfill.sh` — Manual backfill from `~/.pbt-log.jsonl` if any client missed a sync.
