# PBT Metrics Setup Guide

Two-part setup: a **Slack Incoming Webhook** for logging, and a **Slack Bot** for the weekly analysis script to read messages back.

---

## Part 1: Slack Webhook (for logging)

This is what the skill uses to send metrics after each task.

### 1. Create a Slack app

1. Go to https://api.slack.com/apps
2. Click **Create New App** → **From scratch**
3. Name: `PBT Metrics` (or whatever you prefer)
4. Workspace: select your team workspace
5. Click **Create App**

### 2. Enable Incoming Webhooks

1. In the app settings, go to **Incoming Webhooks** (left sidebar)
2. Toggle **Activate Incoming Webhooks** → On
3. Click **Add New Webhook to Workspace**
4. Choose the channel (create `#pbt-metrics` first if it doesn't exist)
5. Click **Allow**
6. Copy the webhook URL — it looks like `https://hooks.slack.com/services/T00000/B00000/XXXXXXXX`

### 3. Set the environment variable

Add this to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
export PBT_SLACK_WEBHOOK="https://hooks.slack.com/services/T00000/B00000/XXXXXXXX"
```

Then reload: `source ~/.zshrc`

### 4. Test it

```bash
curl -s -X POST "$PBT_SLACK_WEBHOOK" \
  -H "Content-type: application/json" \
  -d '{"text":"PBT webhook test — if you see this, it works."}'
```

You should see the message in your `#pbt-metrics` channel.

### 5. Share with teammates

Each teammate adds the same `PBT_SLACK_WEBHOOK` export to their shell profile. Everyone uses the same webhook URL — all logs go to the same channel.

---

## Part 2: Slack Bot Token (for the analysis script)

The weekly analysis script needs to READ messages from the channel, which requires a bot token (webhooks are write-only).

### 1. Add Bot Token Scopes

In your Slack app settings (same app from Part 1):

1. Go to **OAuth & Permissions** (left sidebar)
2. Under **Bot Token Scopes**, add:
   - `channels:history` — to read messages from public channels
   - `channels:read` — to list channels
3. Click **Install to Workspace** (or **Reinstall** if already installed)
4. Copy the **Bot User OAuth Token** — starts with `xoxb-`

### 2. Get the channel ID

1. In Slack, right-click the `#pbt-metrics` channel name → **View channel details**
2. At the bottom of the details panel, copy the **Channel ID** (starts with `C`)

### 3. Set environment variables

Add to your shell profile:

```bash
export SLACK_BOT_TOKEN="xoxb-your-bot-token"
export PBT_SLACK_CHANNEL="C0123456789"
```

### 4. Install the script dependency

```bash
pip install slack-sdk
```

### 5. Run the analysis

```bash
# Last 7 days (default)
python3 ~/.cursor/skills/plan-build-test/scripts/weekly_analysis.py

# Last 14 days
python3 ~/.cursor/skills/plan-build-test/scripts/weekly_analysis.py --days 14

# Save to file
python3 ~/.cursor/skills/plan-build-test/scripts/weekly_analysis.py --output ~/Desktop/pbt-report.md

# Raw JSON (for piping to other tools)
python3 ~/.cursor/skills/plan-build-test/scripts/weekly_analysis.py --json
```

### 6. Automate weekly (optional)

Add a cron job to run every Monday morning:

```bash
crontab -e
```

Add this line (runs every Monday at 9am):

```
0 9 * * 1 SLACK_BOT_TOKEN=xoxb-your-token PBT_SLACK_CHANNEL=C0123456789 python3 ~/.cursor/skills/plan-build-test/scripts/weekly_analysis.py --output ~/Documents/pbt-reports/report-$(date +\%Y-\%W).md
```

---

## What the report shows

The weekly analysis produces:

- **Triage distribution** — SIMPLE/QUICK/COMPLEX breakdown with percentages
- **Output metrics** — files changed, tests written, tests fixed per task
- **Risk analysis** — risks identified, mitigated, escalated to user
- **Usage by team member** — who's using it, how productive each person is
- **Usage by project** — which repos benefit most
- **Language distribution** — JS, TS, Python, etc.
- **Compliance scorecard** — test coverage rate, ask-user stop compliance
- **Recommendations** — specific, actionable suggestions for improving the skill

## Example recommendations the script produces

- "Triage may be over-classifying. 68% of tasks are COMPLEX. Review recent COMPLEX tasks..."
- "Test compliance gap. 20% of QUICK/COMPLEX tasks had zero new tests..."
- "Ask-user compliance failure. Risks were marked 'Ask user' but agent never stopped..."
- "3 tasks escalated from QUICK to COMPLEX. Review these to adjust triage criteria..."
