#!/usr/bin/env python3
"""
PBT Data Accuracy Audit

Deterministic validation of PBT log entries and dashboard metrics.
Checks schema compliance, cross-field integrity, arithmetic accuracy,
local-vs-remote drift, and recommendation thresholds.

Outputs a structured JSON report to stdout.

Usage:
    python3 pbt-audit.py                    # full audit (local + remote)
    python3 pbt-audit.py --local-only       # skip remote comparison
    python3 pbt-audit.py --remote-only      # validate Vercel Blob data only (no local file needed)
    python3 pbt-audit.py --verbose          # include per-entry details
    python3 pbt-audit.py --fix-summary      # also print human-readable summary
"""

import argparse
import json
import os
import ssl
import sys
import urllib.request
import urllib.error
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

LOG_FILE = Path.home() / ".pbt-log.jsonl"
QUARANTINE_FILE = Path.home() / ".pbt-log-quarantine.jsonl"

DASHBOARD_URL = os.environ.get(
    "PBT_DASHBOARD_URL", "https://pbt-dashboard.vercel.app"
)
VERCEL_BYPASS = os.environ.get("PBT_VERCEL_BYPASS", "uuN7ItKyFWWg5ypAFwWBjhqFJIkxiv6d")

VALID_TRIAGE = {"Trivial", "Small Scope", "Complex", "Investigative"}

REQUIRED_FIELDS = {
    "ts": str,
    "user": str,
    "project": str,
    "triage": str,
    "task": str,
    "files_changed": int,
    "files_created": int,
    "tests_written": int,
    "tests_fixed": int,
    "all_tests_passed": bool,
    "risks_identified": int,
    "risks_mitigated": int,
    "risks_out_of_scope": int,
    "risks_ask_user": int,
    "stopped_to_ask_user": bool,
    "plan_deviations": int,
    "pre_existing_issues": list,
    "language": str,
    "visual_check": bool,
    "visual_issues_found": int,
    "escalated": bool,
    "escalated_from": (str, type(None)),
    "spiked": bool,
    "spike_resolved": bool,
    "mid_plan_spike": bool,
}

OPTIONAL_FIELDS = {
    "duration_min": (int, float, type(None)),
    "notes": (str, type(None)),
}

LEGACY_LINE_THRESHOLD = 100  # Entries below this line number predate the current schema

LEGACY_ALIASES = {
    "timestamp": "ts",
    "tier": "triage",
    "goal": "task",
    "files_touched": "files_changed",
}


def parse_iso(ts_str):
    """Parse ISO 8601 timestamp, return timezone-aware datetime or None."""
    if not isinstance(ts_str, str):
        return None
    try:
        ts_str = ts_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


def read_local_entries():
    """Read and parse all entries from the local log file."""
    if not LOG_FILE.exists():
        return [], ["Log file not found: " + str(LOG_FILE)]

    entries = []
    parse_errors = []
    for line_num, line in enumerate(LOG_FILE.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            entry["_line"] = line_num
            entries.append(entry)
        except json.JSONDecodeError as e:
            parse_errors.append({"line": line_num, "issue": f"Invalid JSON: {e}"})

    return entries, parse_errors


def fetch_remote_entries():
    """Fetch all entries from the Vercel dashboard API."""
    url = f"{DASHBOARD_URL}/api/entries?limit=5000"
    headers = {"x-vercel-protection-bypass": VERCEL_BYPASS}

    req = urllib.request.Request(url, headers=headers)
    for ctx in (ssl.create_default_context(), ssl._create_unverified_context()):
        try:
            with urllib.request.urlopen(req, timeout=15, context=ctx) as resp:
                data = json.loads(resp.read().decode())
                return data.get("entries", []), data.get("total", 0), None
        except urllib.error.HTTPError as e:
            return [], 0, f"HTTP {e.code}: {e.reason}"
        except (urllib.error.URLError, ssl.SSLError):
            continue
        except Exception as e:
            return [], 0, str(e)
    return [], 0, "SSL verification failed (tried both verified and unverified)"


def validate_entry(entry, line_num):
    """Validate a single entry against the schema. Returns list of violations."""
    violations = []

    for field, expected_type in REQUIRED_FIELDS.items():
        if field not in entry:
            violations.append({
                "line": line_num, "field": field,
                "issue": f"Missing required field: {field}",
            })
            continue

        val = entry[field]
        if isinstance(expected_type, tuple):
            if not isinstance(val, expected_type):
                violations.append({
                    "line": line_num, "field": field,
                    "issue": f"Wrong type: expected {expected_type}, got {type(val).__name__}={val!r}",
                })
        else:
            if not isinstance(val, expected_type):
                if expected_type is int and isinstance(val, bool):
                    violations.append({
                        "line": line_num, "field": field,
                        "issue": f"Boolean where int expected: {val!r}",
                    })
                elif expected_type is int and isinstance(val, float) and val == int(val):
                    pass  # 0.0 for 0 is acceptable
                elif expected_type is bool and isinstance(val, int):
                    violations.append({
                        "line": line_num, "field": field,
                        "issue": f"Int where bool expected: {val!r} (use true/false)",
                    })
                else:
                    violations.append({
                        "line": line_num, "field": field,
                        "issue": f"Wrong type: expected {expected_type.__name__}, got {type(val).__name__}={val!r}",
                    })

    for field, expected_type in OPTIONAL_FIELDS.items():
        if field in entry:
            val = entry[field]
            if not isinstance(val, expected_type):
                violations.append({
                    "line": line_num, "field": field,
                    "issue": f"Wrong type: expected {expected_type}, got {type(val).__name__}={val!r}",
                })

    if entry.get("triage") and entry["triage"] not in VALID_TRIAGE:
        violations.append({
            "line": line_num, "field": "triage",
            "issue": f"Invalid triage value: {entry['triage']!r}",
        })

    if entry.get("ts") and parse_iso(entry["ts"]) is None:
        violations.append({
            "line": line_num, "field": "ts",
            "issue": f"Invalid ISO 8601 timestamp: {entry['ts']!r}",
        })

    ri = entry.get("risks_identified", 0) or 0
    rm = entry.get("risks_mitigated", 0) or 0
    ro = entry.get("risks_out_of_scope", 0) or 0
    ra = entry.get("risks_ask_user", 0) or 0
    if isinstance(ri, int) and isinstance(rm, int) and isinstance(ro, int) and isinstance(ra, int):
        if rm + ro + ra > ri:
            violations.append({
                "line": line_num, "field": "risks_*",
                "issue": f"Risk resolution exceeds identified: {rm}+{ro}+{ra}={rm+ro+ra} > {ri}",
            })

    if entry.get("stopped_to_ask_user") is True and entry.get("risks_ask_user", 0) == 0:
        violations.append({
            "line": line_num, "field": "stopped_to_ask_user",
            "issue": "stopped_to_ask_user=true but risks_ask_user=0 (contradiction)",
        })

    if entry.get("all_tests_passed") is True and entry.get("tests_written", 0) == 0:
        if entry.get("triage") not in ("Trivial", None):
            violations.append({
                "line": line_num, "field": "tests_written",
                "issue": f"all_tests_passed=true but tests_written=0 for {entry.get('triage')} task (potential gap)",
                "severity": "warning",
            })

    fc = entry.get("files_changed", 0) or 0
    fcr = entry.get("files_created", 0) or 0
    if entry.get("triage") == "Trivial" and isinstance(fc, int) and isinstance(fcr, int):
        if fc + fcr > 5:
            violations.append({
                "line": line_num, "field": "triage",
                "issue": f"Trivial task but files_changed+files_created={fc+fcr} (possible under-classification)",
                "severity": "warning",
            })

    for legacy_name in LEGACY_ALIASES:
        if legacy_name in entry:
            violations.append({
                "line": line_num, "field": legacy_name,
                "issue": f"Legacy field name '{legacy_name}' (should be '{LEGACY_ALIASES[legacy_name]}')",
                "severity": "legacy",
            })

    return violations


def compute_arithmetic(entries):
    """Recompute all dashboard KPIs and verify correctness."""
    total = len(entries)
    if total == 0:
        return {"note": "No entries to compute", "ok": True}

    triage_counts = Counter(e.get("triage", "Unknown") for e in entries)
    risks_identified = sum(e.get("risks_identified", 0) or 0 for e in entries)
    risks_mitigated = sum(e.get("risks_mitigated", 0) or 0 for e in entries)
    escalated_count = sum(1 for e in entries if e.get("escalated") is True)
    visual_checks = sum(1 for e in entries if e.get("visual_check") is True)
    visual_issue_tasks = sum(1 for e in entries if (e.get("visual_issues_found") or 0) > 0)
    spiked_count = sum(1 for e in entries if e.get("spiked") is True)

    timestamps = [parse_iso(e.get("ts", "")) for e in entries]
    valid_ts = [t for t in timestamps if t is not None]

    metrics = {}

    if risks_identified > 0:
        pct = round(risks_mitigated / risks_identified * 100, 1)
        metrics["risk_mitigation_pct"] = {
            "computed": pct,
            "formula": f"{risks_mitigated}/{risks_identified}*100",
            "denominator": f"risks_identified={risks_identified}",
            "ok": 0 <= pct <= 100,
        }
        if pct > 100:
            metrics["risk_mitigation_pct"]["issue"] = "Exceeds 100%"
    else:
        metrics["risk_mitigation_pct"] = {
            "computed": None,
            "formula": "N/A (denominator=0)",
            "denominator": "risks_identified=0",
            "ok": True,
        }

    esc_rate = round(escalated_count / total * 100, 1)
    metrics["escalation_rate"] = {
        "computed": esc_rate,
        "formula": f"{escalated_count}/{total}*100",
        "denominator": f"total={total}",
        "ok": 0 <= esc_rate <= 100,
    }

    vis_rate = round(visual_checks / total * 100, 1)
    metrics["visual_check_rate"] = {
        "computed": vis_rate,
        "formula": f"{visual_checks}/{total}*100",
        "denominator": f"total={total}",
        "ok": 0 <= vis_rate <= 100,
    }

    if visual_checks > 0:
        vis_issue_rate = round(visual_issue_tasks / visual_checks * 100, 1)
        metrics["visual_issue_rate"] = {
            "computed": vis_issue_rate,
            "formula": f"{visual_issue_tasks}/{visual_checks}*100",
            "denominator": f"visual_checks={visual_checks}",
            "ok": 0 <= vis_issue_rate <= 100,
        }
    else:
        metrics["visual_issue_rate"] = {
            "computed": None,
            "formula": "N/A (no visual checks)",
            "denominator": "visual_checks=0",
            "ok": True,
        }

    if len(valid_ts) >= 2:
        earliest = min(valid_ts)
        latest = max(valid_ts)
        days = max((latest - earliest).days + 1, 1)
        weeks = max(days / 7, 1)
        metrics["tasks_per_day"] = {
            "computed": round(total / days, 2),
            "formula": f"{total}/{days}",
            "denominator": f"days={days}",
            "ok": True,
        }
        metrics["tasks_per_week"] = {
            "computed": round(total / weeks, 1),
            "formula": f"{total}/{weeks:.1f}",
            "denominator": f"weeks={weeks:.1f}",
            "ok": True,
        }

    triage_pcts = {}
    for tier, count in triage_counts.items():
        pct = round(count / total * 100, 1)
        triage_pcts[tier] = {"count": count, "pct": pct}
    metrics["triage_distribution"] = triage_pcts

    all_pcts_ok = all(
        m.get("ok", True)
        for m in metrics.values()
        if isinstance(m, dict) and "ok" in m
    )

    return {"metrics": metrics, "ok": all_pcts_ok}


def check_drift(local_entries, remote_entries, remote_total, remote_error):
    """Compare local log file against remote Vercel Blob data."""
    result = {
        "local_count": len(local_entries),
        "remote_count": remote_total,
        "remote_error": remote_error,
        "local_only": 0,
        "remote_only": 0,
        "duplicates_local": 0,
        "duplicates_remote": 0,
        "old_schema_entries": 0,
    }

    if remote_error:
        result["note"] = f"Remote unavailable: {remote_error}. Drift check skipped."
        return result

    def entry_key(e):
        return (e.get("ts", ""), e.get("task", ""), e.get("user", ""))

    local_keys = Counter(entry_key(e) for e in local_entries)
    remote_keys = Counter(entry_key(e) for e in remote_entries)

    local_set = set(local_keys.keys())
    remote_set = set(remote_keys.keys())

    result["local_only"] = len(local_set - remote_set)
    result["remote_only"] = len(remote_set - local_set)
    result["duplicates_local"] = sum(1 for c in local_keys.values() if c > 1)
    result["duplicates_remote"] = sum(1 for c in remote_keys.values() if c > 1)

    old_schema_count = 0
    for e in local_entries:
        if any(alias in e for alias in LEGACY_ALIASES):
            old_schema_count += 1
    result["old_schema_entries"] = old_schema_count

    if result["local_only"] > 0 or result["remote_only"] > 0:
        missing_remote_samples = []
        for key in list(local_set - remote_set)[:5]:
            missing_remote_samples.append({"ts": key[0], "task": key[1][:60], "user": key[2]})
        if missing_remote_samples:
            result["local_only_samples"] = missing_remote_samples

        missing_local_samples = []
        for key in list(remote_set - local_set)[:5]:
            missing_local_samples.append({"ts": key[0], "task": key[1][:60], "user": key[2]})
        if missing_local_samples:
            result["remote_only_samples"] = missing_local_samples

    return result


def check_thresholds(entries):
    """Check recommendation thresholds from weekly_analysis."""
    total = len(entries)
    if total == 0:
        return {"note": "No entries", "ok": True}

    non_trivial = [e for e in entries if e.get("triage") != "Trivial"]
    complex_entries = [e for e in entries if e.get("triage") == "Complex"]

    complex_rate = round(len(complex_entries) / total * 100, 1) if total > 0 else 0

    non_trivial_no_tests = sum(
        1 for e in non_trivial if (e.get("tests_written") or 0) == 0
    )
    test_gap = round(non_trivial_no_tests / len(non_trivial) * 100, 1) if non_trivial else 0

    avg_risks = round(
        sum(e.get("risks_identified", 0) or 0 for e in entries) / total, 2
    )

    escalation_count = sum(1 for e in entries if e.get("escalated") is True)

    thresholds = {
        "complex_rate": {
            "value": complex_rate,
            "threshold": 60,
            "flagged": complex_rate > 60,
            "rule": ">60% Complex = over-classification",
        },
        "test_gap": {
            "value": test_gap,
            "threshold": 15,
            "flagged": test_gap > 15,
            "rule": ">15% non-trivial with zero tests = test gap",
            "detail": f"{non_trivial_no_tests}/{len(non_trivial)} non-trivial tasks have 0 tests",
        },
        "risk_under_id": {
            "value": avg_risks,
            "threshold": 1.0,
            "flagged": avg_risks < 1.0,
            "rule": "avg risks_identified < 1.0 = under-identification",
        },
        "escalation_present": {
            "value": escalation_count,
            "threshold": 0,
            "flagged": escalation_count > 0,
            "rule": "any escalations = triage miss flag",
            "detail": f"{escalation_count} escalated tasks",
        },
    }

    any_flagged = any(t["flagged"] for t in thresholds.values())
    return {"thresholds": thresholds, "ok": not any_flagged}


def check_quarantine():
    """Count lines in ~/.pbt-log-quarantine.jsonl if present."""
    if not QUARANTINE_FILE.exists():
        return {"path": str(QUARANTINE_FILE), "exists": False, "quarantine_count": 0}
    try:
        count = sum(1 for line in QUARANTINE_FILE.read_text().splitlines() if line.strip())
    except OSError as exc:
        return {
            "path": str(QUARANTINE_FILE),
            "exists": True,
            "quarantine_count": 0,
            "error": str(exc),
        }
    return {"path": str(QUARANTINE_FILE), "exists": True, "quarantine_count": count}


def run_audit(local_only=False, remote_only=False, verbose=False):
    """Run the full audit and return structured report."""
    report = {
        "run_ts": datetime.now(timezone.utc).isoformat(),
        "mode": "remote-only" if remote_only else ("local-only" if local_only else "full"),
    }

    if remote_only:
        remote_entries, remote_total, remote_error = fetch_remote_entries()
        if remote_error:
            report["remote_error"] = remote_error
            report["remote_count"] = 0
            report["summary"] = "UNABLE_TO_VERIFY"
            report["issues_found"] = 0
            report["warnings_found"] = 0
            report["legacy_fields_found"] = 0
            report["note"] = f"Remote fetch failed: {remote_error}"
            quarantine = check_quarantine()
            report["quarantine"] = quarantine
            report["quarantine_count"] = quarantine.get("quarantine_count", 0)
            return report

        for i, entry in enumerate(remote_entries):
            entry["_line"] = i + 1

        entries = remote_entries
        report["remote_count"] = remote_total
        report["parse_errors"] = []
    else:
        local_entries, parse_errors = read_local_entries()
        entries = local_entries
        report["local_count"] = len(local_entries)
        report["parse_errors"] = parse_errors

    all_violations = []
    error_count = 0
    warning_count = 0
    legacy_count = 0
    legacy_error_count = 0
    recent_error_count = 0

    for entry in entries:
        line_num = entry.get("_line", 0)
        violations = validate_entry(entry, line_num)
        for v in violations:
            severity = v.get("severity", "error")
            if severity == "error":
                error_count += 1
                if line_num < LEGACY_LINE_THRESHOLD:
                    legacy_error_count += 1
                else:
                    recent_error_count += 1
            elif severity == "warning":
                warning_count += 1
            elif severity == "legacy":
                legacy_count += 1
        all_violations.extend(violations)

    source_label = "remote" if remote_only else "local"
    report["entry_validation"] = {
        "source": source_label,
        "total_checked": len(entries),
        "errors": error_count,
        "legacy_errors": legacy_error_count,
        "recent_errors": recent_error_count,
        "warnings": warning_count,
        "legacy_fields": legacy_count,
    }
    if verbose:
        report["entry_violations"] = all_violations
    elif all_violations:
        errors_only = [v for v in all_violations if v.get("severity", "error") == "error"]
        recent_errors = [v for v in errors_only if v.get("line", 0) >= LEGACY_LINE_THRESHOLD]
        legacy_errors = [v for v in errors_only if v.get("line", 0) < LEGACY_LINE_THRESHOLD]
        # Always surface all recent violations; fill remainder of sample with legacy examples
        sample = recent_errors + legacy_errors[:max(0, 20 - len(recent_errors))]
        report["recent_violations"] = recent_errors  # full list, never sampled
        report["entry_violations_sample"] = sample

    arithmetic = compute_arithmetic(entries)
    report["arithmetic"] = arithmetic

    if remote_only:
        report["drift"] = {"note": "Skipped (--remote-only, no local file to compare)"}
    else:
        remote_entries, remote_total, remote_error = [], 0, None
        if not local_only:
            remote_entries, remote_total, remote_error = fetch_remote_entries()
        report["remote_count"] = remote_total
        drift = check_drift(entries, remote_entries, remote_total, remote_error if not local_only else "Skipped (--local-only)")
        report["drift"] = drift

    thresholds = check_thresholds(entries)
    report["thresholds"] = thresholds

    issues = error_count + len(report.get("parse_errors", []))
    drift_data = report.get("drift", {})
    if drift_data.get("local_only", 0) > 0 or drift_data.get("remote_only", 0) > 0:
        issues += 1
    if not arithmetic.get("ok", True):
        issues += 1
    if not thresholds.get("ok", True):
        for t in thresholds.get("thresholds", {}).values():
            if t.get("flagged"):
                issues += 1

    report["issues_found"] = issues
    report["warnings_found"] = warning_count
    report["legacy_fields_found"] = legacy_count

    quarantine = check_quarantine()
    report["quarantine"] = quarantine
    qcount = quarantine.get("quarantine_count", 0)
    report["quarantine_count"] = qcount
    if qcount > 0:
        warning_count += 1
        report["warnings_found"] = warning_count

    if issues == 0 and warning_count == 0:
        report["summary"] = "VERIFIED"
    elif issues == 0 and warning_count > 0:
        report["summary"] = "VERIFIED_WITH_WARNINGS"
    else:
        report["summary"] = "DISCREPANCY"

    return report


def print_human_summary(report):
    """Print a human-readable summary of the audit report."""
    summary = report["summary"]
    issues = report["issues_found"]
    warnings = report["warnings_found"]
    legacy = report["legacy_fields_found"]
    entry_count = report.get("remote_count") if report.get("mode") == "remote-only" else report.get("local_count", 0)
    source = "remote" if report.get("mode") == "remote-only" else "local"

    if summary == "UNABLE_TO_VERIFY":
        print(f"\n  UNABLE TO VERIFY -- {report.get('note', 'Unknown error')}")
        return
    elif summary == "VERIFIED":
        print(f"\n  VERIFIED -- All {entry_count} {source} entries valid, metrics consistent.")
    elif summary == "VERIFIED_WITH_WARNINGS":
        print(f"\n  VERIFIED WITH WARNINGS -- {warnings} warnings across {entry_count} {source} entries.")
    else:
        print(f"\n  DISCREPANCY FOUND -- {issues} issues, {warnings} warnings across {entry_count} {source} entries.")

    ev = report.get("entry_validation", {})
    print(f"\n  Schema:     {ev.get('errors', 0)} errors, {ev.get('warnings', 0)} warnings, {ev.get('legacy_fields', 0)} legacy fields")

    qcount = report.get("quarantine_count", 0)
    if qcount > 0:
        print(f"  Quarantine: {qcount} line(s) in ~/.pbt-log-quarantine.jsonl (rejected by pbt-log.sh gate)")
    else:
        print("  Quarantine: empty / absent")

    arith = report.get("arithmetic", {})
    if arith.get("ok"):
        print("  Arithmetic: All metrics within expected bounds")
    else:
        print("  Arithmetic: ISSUES FOUND in metric calculations")

    drift = report.get("drift", {})
    if drift.get("note") and "Skipped" in drift.get("note", ""):
        print(f"  Drift:      {drift['note']}")
    else:
        local_c = drift.get("local_count", "?")
        remote_c = drift.get("remote_count", "?")
        lo = drift.get("local_only", 0)
        ro = drift.get("remote_only", 0)
        print(f"  Drift:      Local={local_c}, Remote={remote_c}, local-only={lo}, remote-only={ro}")
        if drift.get("remote_error"):
            print(f"              (remote error: {drift['remote_error']})")

    thresh = report.get("thresholds", {}).get("thresholds", {})
    flagged = [name for name, t in thresh.items() if t.get("flagged")]
    if flagged:
        print(f"  Thresholds: FLAGGED -- {', '.join(flagged)}")
        for name in flagged:
            t = thresh[name]
            print(f"              {name}: {t['value']} (threshold: {t['threshold']}) -- {t['rule']}")
    else:
        print("  Thresholds: All within acceptable bounds")

    if report.get("parse_errors"):
        print(f"\n  Parse errors ({len(report['parse_errors'])}):")
        for pe in report["parse_errors"][:5]:
            print(f"    Line {pe['line']}: {pe['issue']}")

    violations = report.get("entry_violations_sample", report.get("entry_violations", []))
    errors = [v for v in violations if v.get("severity", "error") == "error"]
    if errors:
        print(f"\n  Entry errors (showing {min(len(errors), 10)}/{ev.get('errors', 0)}):")
        for v in errors[:10]:
            print(f"    Line {v['line']}: [{v['field']}] {v['issue']}")

    print()


def main():
    parser = argparse.ArgumentParser(description="PBT Data Accuracy Audit")
    source_group = parser.add_mutually_exclusive_group()
    source_group.add_argument("--local-only", action="store_true", help="Skip remote API comparison")
    source_group.add_argument("--remote-only", action="store_true", help="Validate Vercel Blob data only (no local file needed)")
    parser.add_argument("--verbose", action="store_true", help="Include all violation details")
    parser.add_argument("--fix-summary", action="store_true", help="Print human-readable summary")
    parser.add_argument("--json", action="store_true", help="Output raw JSON (default if no --fix-summary)")
    args = parser.parse_args()

    report = run_audit(local_only=args.local_only, remote_only=args.remote_only, verbose=args.verbose)

    if args.fix_summary:
        print_human_summary(report)

    if args.json or not args.fix_summary:
        print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
