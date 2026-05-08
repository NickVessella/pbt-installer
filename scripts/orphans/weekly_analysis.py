#!/usr/bin/env python3
"""
PBT Weekly Analysis

Reads structured log entries from ~/.pbt-log.jsonl (local) or a Slack channel
and produces a markdown report with metrics, trends, and specific
recommendations for improving the plan-build-test skill.

No dependencies required for local mode. For Slack mode: pip install slack-sdk

Usage:
    # Local mode (default) — reads from ~/.pbt-log.jsonl
    python weekly_analysis.py                  # last 7 days
    python weekly_analysis.py --days 14        # last 14 days
    python weekly_analysis.py --all            # all entries ever
    python weekly_analysis.py --output report.md

    # Slack mode — reads from a Slack channel
    export SLACK_BOT_TOKEN=xoxb-your-token
    export PBT_SLACK_CHANNEL=C0123456789
    python weekly_analysis.py --source slack
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOG_FILE = Path.home() / ".pbt-log.jsonl"


def fetch_local_entries(oldest_ts=None):
    """Read entries from the local JSONL log file."""
    if not LOG_FILE.exists():
        print(f"Log file not found: {LOG_FILE}", file=sys.stderr)
        print("The skill hasn't logged any tasks yet. Use Cursor with the", file=sys.stderr)
        print("plan-build-test skill to generate entries.", file=sys.stderr)
        sys.exit(0)

    entries = []
    for line_num, line in enumerate(LOG_FILE.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            print(f"Skipping malformed line {line_num} in {LOG_FILE}", file=sys.stderr)
            continue

        if oldest_ts and entry.get("ts"):
            try:
                entry_dt = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
                if entry_dt.timestamp() < oldest_ts:
                    continue
            except (ValueError, TypeError):
                pass

        entries.append(entry)

    return entries


def fetch_slack_entries(oldest_ts):
    """Fetch PBT log entries from a Slack channel."""
    try:
        from slack_sdk import WebClient
        from slack_sdk.errors import SlackApiError
    except ImportError:
        print("Slack mode requires slack-sdk: pip install slack-sdk", file=sys.stderr)
        sys.exit(1)

    token = os.environ.get("SLACK_BOT_TOKEN")
    channel = os.environ.get("PBT_SLACK_CHANNEL")
    if not token or not channel:
        print("Set SLACK_BOT_TOKEN and PBT_SLACK_CHANNEL for Slack mode.", file=sys.stderr)
        sys.exit(1)

    client = WebClient(token=token)
    messages = []
    cursor = None
    while True:
        try:
            resp = client.conversations_history(
                channel=channel, oldest=str(oldest_ts), limit=200, cursor=cursor,
            )
        except SlackApiError as e:
            print(f"Slack API error: {e.response['error']}", file=sys.stderr)
            sys.exit(1)

        for msg in resp.get("messages", []):
            payload = extract_slack_payload(msg)
            if payload:
                messages.append(payload)

        if not resp.get("has_more"):
            break
        cursor = resp.get("response_metadata", {}).get("next_cursor")

    return messages


def extract_slack_payload(msg):
    """Extract the JSON payload from a PBT Slack message's context block."""
    blocks = msg.get("blocks", [])
    for block in blocks:
        if block.get("type") == "context":
            for el in block.get("elements", []):
                text = el.get("text", "")
                match = re.search(r"```(\{.*\})```", text, re.DOTALL)
                if match:
                    try:
                        return json.loads(match.group(1))
                    except json.JSONDecodeError:
                        continue
    return None


def compute_metrics(entries):
    """Compute all metrics from a list of log entries."""
    if not entries:
        return None

    m = {
        "total_tasks": len(entries),
        "triage_counts": Counter(),
        "by_user": defaultdict(list),
        "by_project": defaultdict(list),
        "by_language": Counter(),
        "total_files_changed": 0,
        "total_files_created": 0,
        "total_tests_written": 0,
        "total_tests_fixed": 0,
        "total_risks_identified": 0,
        "total_risks_mitigated": 0,
        "total_risks_out_of_scope": 0,
        "total_risks_ask_user": 0,
        "ask_user_stops": 0,
        "all_tests_passed_count": 0,
        "plan_deviations": 0,
        "escalations": 0,
        "pre_existing_issues": [],
        "tasks_with_zero_tests": 0,
        "non_simple_tasks": 0,
        "non_simple_zero_tests": 0,
        "spike_count": 0,
        "mid_plan_spikes": 0,
        "spike_opportunity_gap": 0,
    }

    for e in entries:
        triage = e.get("triage", "UNKNOWN")
        m["triage_counts"][triage] += 1
        m["by_user"][e.get("user", "unknown")].append(e)
        m["by_project"][e.get("project", "unknown")].append(e)
        m["by_language"][e.get("language", "unknown")] += 1
        m["total_files_changed"] += e.get("files_changed", 0)
        m["total_files_created"] += e.get("files_created", 0)
        m["total_tests_written"] += e.get("tests_written", 0)
        m["total_tests_fixed"] += e.get("tests_fixed", 0)
        m["total_risks_identified"] += e.get("risks_identified", 0)
        m["total_risks_mitigated"] += e.get("risks_mitigated", 0)
        m["total_risks_out_of_scope"] += e.get("risks_out_of_scope", 0)
        m["total_risks_ask_user"] += e.get("risks_ask_user", 0)
        if e.get("stopped_to_ask_user"):
            m["ask_user_stops"] += 1
        if e.get("all_tests_passed"):
            m["all_tests_passed_count"] += 1
        m["plan_deviations"] += e.get("plan_deviations", 0)
        if e.get("escalated"):
            m["escalations"] += 1
        if e.get("spiked"):
            m["spike_count"] += 1
        if e.get("mid_plan_spike"):
            m["mid_plan_spikes"] += 1
        if e.get("plan_deviations", 0) > 0 and not e.get("spiked"):
            m["spike_opportunity_gap"] += 1
        for issue in e.get("pre_existing_issues", []):
            m["pre_existing_issues"].append(issue)

        is_non_simple = triage in ("QUICK", "COMPLEX")
        if is_non_simple:
            m["non_simple_tasks"] += 1
            if e.get("tests_written", 0) == 0:
                m["non_simple_zero_tests"] += 1

        if e.get("tests_written", 0) == 0:
            m["tasks_with_zero_tests"] += 1

    return m


def generate_recommendations(m):
    """Produce specific, actionable recommendations based on metrics."""
    recs = []

    # Triage distribution
    total = m["total_tasks"]
    complex_pct = m["triage_counts"].get("COMPLEX", 0) / total * 100 if total else 0
    simple_pct = m["triage_counts"].get("SIMPLE", 0) / total * 100 if total else 0
    quick_pct = m["triage_counts"].get("QUICK", 0) / total * 100 if total else 0

    if complex_pct > 60:
        recs.append(
            f"**Triage may be over-classifying.** {complex_pct:.0f}% of tasks are COMPLEX. "
            "Review recent COMPLEX tasks — if many are contained changes (2-3 files, low risk), "
            "consider adding more QUICK examples to the skill for those patterns."
        )
    if simple_pct > 70:
        recs.append(
            f"**Most tasks are SIMPLE ({simple_pct:.0f}%).** The skill is adding minimal value "
            "for this project's typical workload. Consider whether the team is using it for the "
            "right kind of work, or if the project genuinely has mostly trivial changes."
        )
    if quick_pct < 10 and total > 10:
        recs.append(
            "**QUICK tier is underused** (<10% of tasks). Team members may be unfamiliar with "
            "QUICK or the triage criteria may be pushing borderline tasks to COMPLEX. Review "
            "recent COMPLEX tasks for candidates that should have been QUICK."
        )

    # Test compliance
    if m["non_simple_tasks"] > 0:
        zero_test_rate = m["non_simple_zero_tests"] / m["non_simple_tasks"] * 100
        if zero_test_rate > 15:
            recs.append(
                f"**Test compliance gap.** {zero_test_rate:.0f}% of QUICK/COMPLEX tasks had "
                "zero new tests written. The skill says 'Write new tests for every new behavior' "
                "but the model isn't always following through. Consider adding a stronger "
                "reinforcement: 'Before declaring the task complete, verify tests_written > 0 "
                "for any task that introduced new behavior.'"
            )
        elif zero_test_rate > 0:
            recs.append(
                f"**Minor test gap.** {m['non_simple_zero_tests']} QUICK/COMPLEX task(s) had "
                "zero new tests. Spot-check these to see if tests were genuinely unnecessary "
                "or if the model skipped them."
            )

    # Risk identification
    if m["non_simple_tasks"] > 5:
        avg_risks = m["total_risks_identified"] / m["non_simple_tasks"]
        if avg_risks < 0.5:
            recs.append(
                f"**Low risk identification** (avg {avg_risks:.1f} per QUICK/COMPLEX task). "
                "Either the tasks are genuinely low-risk, or the model is not surfacing risks "
                "in plans. Spot-check recent COMPLEX plans for missing risk analysis."
            )

    # Ask-user stops
    if m["total_risks_ask_user"] > 0 and m["ask_user_stops"] == 0:
        recs.append(
            "**Ask-user compliance failure.** Risks were marked 'Ask user' but the agent "
            "never stopped to ask. This is the most dangerous failure mode — strengthen "
            "the STOP instruction or add a second reminder."
        )

    # Plan deviations
    complex_count = m["triage_counts"].get("COMPLEX", 0)
    if complex_count > 3:
        deviation_rate = m["plan_deviations"] / complex_count
        if deviation_rate > 2:
            recs.append(
                f"**High plan deviation rate** ({deviation_rate:.1f} per COMPLEX task). "
                "Plans are frequently inaccurate. Review whether the Approach section needs "
                "more guidance for common task patterns, or if the 25-line cap is forcing "
                "plans to omit important details."
            )

    # Escalations
    if m["escalations"] > 0:
        recs.append(
            f"**{m['escalations']} task(s) escalated** from QUICK to COMPLEX mid-task. "
            "Review these to see if the triage criteria should have caught the complexity "
            "upfront. If a pattern emerges, add it as a COMPLEX example."
        )

    # Spike analysis
    non_trivial = m["non_simple_tasks"]
    if non_trivial > 5:
        gap_rate = m["spike_opportunity_gap"] / non_trivial
        if gap_rate > 0.15:
            recs.append(
                f"**Spike opportunity gap is high** ({m['spike_opportunity_gap']}/{non_trivial} "
                f"non-trivial tasks = {gap_rate:.0%}). These tasks had plan deviations but were "
                "not spiked. Broaden the Investigative triggers or lower the threshold for the "
                "speculation circuit breaker."
            )
    if m["mid_plan_spikes"] > 0:
        recs.append(
            f"**Speculation circuit breaker fired {m['mid_plan_spikes']} time(s).** "
            "This is a healthy signal — the agent detected uncertainty mid-plan and escalated "
            "to Investigative. Review whether those tasks could have been triaged Investigative "
            "from the start."
        )

    # Pre-existing issues
    if m["pre_existing_issues"]:
        issue_counts = Counter(m["pre_existing_issues"])
        top_issues = issue_counts.most_common(3)
        issue_str = ", ".join(f"{name} ({count}x)" for name, count in top_issues)
        recs.append(
            f"**Pre-existing issues surfaced:** {issue_str}. The skill is catching tech debt. "
            "Consider tracking these separately for a tech-debt reduction initiative."
        )

    if not recs:
        recs.append("No issues detected. The skill is performing well across all metrics.")

    return recs


def build_report(m, entries, days):
    """Build a markdown report from computed metrics."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    total = m["total_tasks"]

    lines = [
        f"# PBT Weekly Analysis — {now}",
        f"",
        f"**Period:** Last {days} days | **Total tasks:** {total}",
        f"",
        f"---",
        f"",
        f"## Triage Distribution",
        f"",
        f"| Classification | Count | % |",
        f"|---------------|-------|---|",
    ]

    for level in ("SIMPLE", "QUICK", "COMPLEX"):
        count = m["triage_counts"].get(level, 0)
        pct = count / total * 100 if total else 0
        bar = "█" * int(pct / 5) + "░" * (20 - int(pct / 5))
        lines.append(f"| {level} | {count} | {pct:.0f}% {bar} |")

    lines += [
        f"",
        f"## Output Metrics",
        f"",
        f"| Metric | Total | Per task |",
        f"|--------|-------|----------|",
        f"| Files changed | {m['total_files_changed']} | {m['total_files_changed']/total:.1f} |",
        f"| Files created | {m['total_files_created']} | {m['total_files_created']/total:.1f} |",
        f"| Tests written | {m['total_tests_written']} | {m['total_tests_written']/total:.1f} |",
        f"| Tests fixed (pre-existing) | {m['total_tests_fixed']} | {m['total_tests_fixed']/total:.1f} |",
        f"| Test pass rate | {m['all_tests_passed_count']}/{total} | {m['all_tests_passed_count']/total*100:.0f}% |",
        f"",
        f"## Risk Analysis",
        f"",
        f"| Metric | Count |",
        f"|--------|-------|",
        f"| Risks identified | {m['total_risks_identified']} |",
        f"| → Mitigated | {m['total_risks_mitigated']} |",
        f"| → Out of scope | {m['total_risks_out_of_scope']} |",
        f"| → Ask user | {m['total_risks_ask_user']} |",
        f"| Ask-user stops (agent actually stopped) | {m['ask_user_stops']} |",
        f"| Plan deviations | {m['plan_deviations']} |",
        f"| QUICK → COMPLEX escalations | {m['escalations']} |",
        f"",
        f"## Spike Analysis",
        f"",
        f"| Metric | Count |",
        f"|--------|-------|",
        f"| Tasks spiked | {m['spike_count']} |",
        f"| Mid-plan spikes (circuit breaker) | {m['mid_plan_spikes']} |",
        f"| Spike opportunity gap (deviations without spike) | {m['spike_opportunity_gap']} |",
        f"| Spike rate (of non-trivial) | {m['spike_count']}/{m['non_simple_tasks']} ({m['spike_count']/m['non_simple_tasks']*100:.0f}%) |" if m['non_simple_tasks'] else f"| Spike rate (of non-trivial) | N/A |",
    ]

    # User breakdown
    lines += [
        f"",
        f"## Usage by Team Member",
        f"",
        f"| User | Tasks | Tests written | Risks caught |",
        f"|------|-------|---------------|-------------|",
    ]
    for user, user_entries in sorted(m["by_user"].items(), key=lambda x: -len(x[1])):
        t = len(user_entries)
        tests = sum(e.get("tests_written", 0) for e in user_entries)
        risks = sum(e.get("risks_identified", 0) for e in user_entries)
        lines.append(f"| {user} | {t} | {tests} | {risks} |")

    # Project breakdown
    lines += [
        f"",
        f"## Usage by Project",
        f"",
        f"| Project | Tasks | Primary language |",
        f"|---------|-------|-----------------|",
    ]
    for proj, proj_entries in sorted(m["by_project"].items(), key=lambda x: -len(x[1])):
        t = len(proj_entries)
        langs = Counter(e.get("language", "?") for e in proj_entries)
        top_lang = langs.most_common(1)[0][0] if langs else "?"
        lines.append(f"| {proj} | {t} | {top_lang} |")

    # Language breakdown
    lines += [
        f"",
        f"## Language Distribution",
        f"",
        f"| Language | Tasks |",
        f"|----------|-------|",
    ]
    for lang, count in m["by_language"].most_common():
        lines.append(f"| {lang} | {count} |")

    # Compliance scorecard
    non_simple = m["non_simple_tasks"]
    test_compliance = ((non_simple - m["non_simple_zero_tests"]) / non_simple * 100) if non_simple else 100
    ask_user_compliance = "N/A"
    if m["total_risks_ask_user"] > 0:
        ask_user_compliance = f"{m['ask_user_stops']}/{m['total_risks_ask_user']}"

    lines += [
        f"",
        f"## Compliance Scorecard",
        f"",
        f"| Check | Score | Status |",
        f"|-------|-------|--------|",
        f"| Test coverage (QUICK/COMPLEX tasks with tests) | {test_compliance:.0f}% | {'✅' if test_compliance >= 85 else '⚠️' if test_compliance >= 70 else '❌'} |",
        f"| Test pass rate | {m['all_tests_passed_count']/total*100:.0f}% | {'✅' if m['all_tests_passed_count']/total >= 0.9 else '⚠️'} |",
        f"| Ask-user stops | {ask_user_compliance} | {'✅' if ask_user_compliance == 'N/A' or m['ask_user_stops'] == m['total_risks_ask_user'] else '❌'} |",
    ]

    # Recommendations
    recs = generate_recommendations(m)
    lines += [
        f"",
        f"---",
        f"",
        f"## Recommendations for Skill Improvement",
        f"",
    ]
    for i, rec in enumerate(recs, 1):
        lines.append(f"{i}. {rec}")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="PBT Weekly Analysis")
    parser.add_argument("--days", type=int, default=7, help="Number of days to analyze (default: 7)")
    parser.add_argument("--all", action="store_true", help="Analyze all entries regardless of date")
    parser.add_argument("--output", type=str, help="Output file path (default: stdout)")
    parser.add_argument("--json", action="store_true", help="Output raw metrics as JSON instead of markdown")
    parser.add_argument("--source", choices=["local", "slack"], default="local",
                        help="Data source: local file (default) or slack channel")
    args = parser.parse_args()

    oldest = datetime.now(timezone.utc) - timedelta(days=args.days)
    oldest_ts = None if args.all else oldest.timestamp()

    label = "all time" if args.all else f"the last {args.days} days"
    print(f"Fetching PBT logs from {label}...", file=sys.stderr)

    if args.source == "slack":
        entries = fetch_slack_entries(oldest_ts or 0)
    else:
        entries = fetch_local_entries(oldest_ts)

    print(f"Found {len(entries)} log entries.", file=sys.stderr)

    if not entries:
        print("No PBT log entries found for this period.", file=sys.stderr)
        sys.exit(0)

    m = compute_metrics(entries)

    if args.json:
        output = json.dumps({
            "period_days": args.days,
            "total_tasks": m["total_tasks"],
            "triage_counts": dict(m["triage_counts"]),
            "total_tests_written": m["total_tests_written"],
            "total_risks_identified": m["total_risks_identified"],
            "ask_user_stops": m["ask_user_stops"],
            "test_compliance_pct": ((m["non_simple_tasks"] - m["non_simple_zero_tests"]) / m["non_simple_tasks"] * 100) if m["non_simple_tasks"] else 100,
            "escalations": m["escalations"],
            "spike_count": m["spike_count"],
            "mid_plan_spikes": m["mid_plan_spikes"],
            "spike_opportunity_gap": m["spike_opportunity_gap"],
            "entries": entries,
        }, indent=2)
    else:
        output = build_report(m, entries, "all time" if args.all else f"{args.days}")

    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Report written to {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
