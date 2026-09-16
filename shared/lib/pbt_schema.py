"""PBT log schema — the single source of truth.

Consumed by:
  - pbt-log.sh      (write-time gate: normalize-then-append)
  - pbt-repair.py   (one-time history backfill)
  - the Monday audit (read-time reporting)

Canonical schema mirrors ~/.pbt/log-schema.md. If that file changes, change
this one in the same commit — they are the same contract in two formats.

Design principle: NORMALIZE, don't reject. A missing integer becomes 0; a
`files_changed` that arrived as a list of filenames becomes the list's length
with the filenames preserved. Only entries whose meaning cannot be recovered
(unparseable JSON, no `ts`, no `task`, unrecognizable `triage`) go to
quarantine. A write path that throws work away is a write path people bypass.

Second principle: NEVER silently change a value. Every coercion, default-fill
and dropped key is recorded — in the `changes` list for the caller, and for
anything carrying data, in a machine-readable salvage block appended to
`notes`. If a number in this log is wrong, the original is recoverable.
"""

import datetime as _dt
import json as _json
import re as _re

TRIAGE_VALUES = ("Trivial", "Small Scope", "Complex", "Investigative")

# Junk prefixes observed on `triage` in the wild (lines 1089/1122/1144,
# 2026-08-19..25).
TRIAGE_PREFIXES = ("p.b.t.", "pbt")

# Legacy / short forms seen in Feb-May 2026 entries.
TRIAGE_LEGACY = {
    "quick": "Trivial",
    "small": "Small Scope",
    "investigate": "Investigative",
    "investigation": "Investigative",
}

# Off-schema keys whose meaning is unambiguous. Mapped to the real field rather
# than merely salvaged into notes, so the metric is not lost to free text.
ALIAS_MAP = {
    "timestamp": "ts",
    "tier": "triage",
    "files_touched": "files_changed",
    "goal": "task",
    "tests_added": "tests_written",
    "escalation_count": None,   # known-but-unmappable: salvage only
}

SALVAGE_TAG = "[pbt-salvage]"

# Fields whose absence is real information loss rather than routine omission.
# When one of these gets defaulted, the entry records it so the audit can
# measure emitter quality straight from the log.
#
# Why this exists: normalizing turned a loud failure into a quiet one. Before
# the gate, a missing `project` was a schema violation the audit shouted about;
# now it silently becomes "unknown" and the entry is technically valid. On
# 2026-09-16, 3 of 7 new entries had no project, language or user, and nothing
# in the report would have said so. Defaulting the routine fields
# (`visual_issues_found=0` and friends) is not worth recording; losing
# attribution is.
ATTRIBUTION_FIELDS = ("user", "project", "language")

INT, BOOL, STR, LIST = "int", "bool", "str", "list"

# field -> (type, default, nullable)
SCHEMA = {
    "ts":                   (STR,  None,      False),
    "user":                 (STR,  "unknown", False),
    "project":              (STR,  "unknown", False),
    "triage":               (STR,  None,      False),
    "task":                 (STR,  None,      False),
    "files_changed":        (INT,  0,         False),
    "files_created":        (INT,  0,         False),
    "tests_written":        (INT,  0,         False),
    "tests_fixed":          (INT,  0,         False),
    # Nullable on purpose. Defaulting an absent value to `true` would assert
    # that tests passed for an entry that never said so — and the Monday audit
    # computes pass rate from this field, so 92 backfilled `true`s would have
    # silently inflated it. `null` means "not recorded" and is excluded from
    # the rate, which is the honest reading.
    "all_tests_passed":     (BOOL, None,      True),
    "risks_identified":     (INT,  0,         False),
    "risks_mitigated":      (INT,  0,         False),
    "risks_out_of_scope":   (INT,  0,         False),
    "risks_ask_user":       (INT,  0,         False),
    "stopped_to_ask_user":  (BOOL, False,     False),
    "plan_deviations":      (INT,  0,         False),
    "pre_existing_issues":  (LIST, [],        False),
    "language":             (STR,  "unknown", False),
    "visual_check":         (BOOL, False,     False),
    "visual_issues_found":  (INT,  0,         False),
    "escalated":            (BOOL, False,     False),
    "escalated_from":       (STR,  None,      True),
    "spiked":               (BOOL, False,     False),
    "spike_resolved":       (BOOL, False,     False),
    "mid_plan_spike":       (BOOL, False,     False),
    "duration_min":         (INT,  None,      True),
    "notes":                (STR,  None,      True),
}

FIELD_ORDER = list(SCHEMA.keys())
REQUIRED = ("ts", "triage", "task")

# Sanity bounds. Outside these a value is almost certainly a units or parsing
# error rather than a real measurement, so it is flagged (not silently fixed).
MAX_COUNT = 100_000
MAX_DURATION_MIN = 60 * 24 * 14  # two weeks

_DATE_ONLY = _re.compile(r"^\d{4}-\d{2}-\d{2}$")
_BASIC_OFFSET = _re.compile(r"([+-])(\d{2})(\d{2})$")
_FRACTIONAL = _re.compile(r"\.(\d{7,})")          # >6 fractional digits
_LEADING_INT = _re.compile(r"^\s*(-?\d+)")
_ISO_SHAPE = _re.compile(
    r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?"
    r"(Z|[+-]\d{2}:?\d{2})?$"
)


# --------------------------------------------------------------------------
# JSON loading that notices duplicate keys
# --------------------------------------------------------------------------

def loads(raw):
    """json.loads, but duplicate keys are reported instead of silently lost.

    Returns (obj, duplicates) where duplicates maps key -> [shadowed values].
    """
    dupes = {}

    def hook(pairs):
        seen = {}
        for key, value in pairs:
            if key in seen:
                dupes.setdefault(key, []).append(seen[key])
            seen[key] = value
        return seen

    return _json.loads(raw, object_pairs_hook=hook), dupes


# --------------------------------------------------------------------------
# timestamps
# --------------------------------------------------------------------------

def _parse_dt(text):
    """Tolerant ISO-8601 parse. Returns datetime or None.

    Independent of the host Python's `fromisoformat` capabilities so that
    whether an entry is accepted never depends on which python3 is on PATH.
    """
    candidate = _BASIC_OFFSET.sub(r"\1\2:\3", text.strip())
    # fromisoformat before 3.11 rejects 'Z' and >6 fractional digits.
    candidate = _FRACTIONAL.sub(lambda m: "." + m.group(1)[:6], candidate)
    normalized = candidate[:-1] + "+00:00" if candidate.endswith("Z") else candidate
    try:
        return _dt.datetime.fromisoformat(normalized)
    except (ValueError, OverflowError):
        return None


def normalize_ts(value):
    """Return (canonical_ts, note_or_None); canonical_ts is None if unusable."""
    if not isinstance(value, str) or not value.strip():
        return None, "ts is not a string: %r" % (value,)
    raw = value.strip()

    if _DATE_ONLY.match(raw):
        return raw + "T00:00:00Z", "original ts was date-only: %s" % raw

    if not _ISO_SHAPE.match(_BASIC_OFFSET.sub(r"\1\2:\3", raw)):
        return None, "ts is not an ISO-8601 datetime: %r" % (value,)
    if _parse_dt(raw) is None:
        return None, "ts is not a valid datetime: %r" % (value,)

    canonical = _BASIC_OFFSET.sub(r"\1\2:\3", raw)
    return canonical, None


def is_iso_datetime(value):
    if not isinstance(value, str) or _DATE_ONLY.match(value.strip()):
        return False
    return normalize_ts(value)[0] is not None


def ts_sort_key(value):
    """Timezone-aware sort key; naive timestamps are assumed UTC."""
    parsed = _parse_dt(value) if isinstance(value, str) else None
    if parsed is None:
        return _dt.datetime.min.replace(tzinfo=_dt.timezone.utc)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed


# --------------------------------------------------------------------------
# coercion
# --------------------------------------------------------------------------

def _coerce_int(value):
    """Return (int_value, salvage_or_None) or (None, reason) if uncoercible."""
    if isinstance(value, bool):
        return int(value), None
    if isinstance(value, int):
        return value, None
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return None, "non-finite number"
        rounded = int(round(value))
        return rounded, (None if rounded == value else value)
    if isinstance(value, list):
        items = [x for x in value if str(x).strip()]
        return len(items), (items if items else None)
    if isinstance(value, dict):
        return None, value
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return 0, None
        try:
            return int(raw), None
        except ValueError:
            pass
        # A leading number with trailing prose: "12 files" -> 12.
        match = _LEADING_INT.match(raw)
        if match:
            return int(match.group(1)), raw
        # Filenames where a count was expected. A single path counts as 1 —
        # returning 0 for "viteConfig.test.ts" would understate real work.
        # Requires a path-ish signal so that prose ("about an hour") stays
        # uncoercible rather than being silently counted as one of something.
        if any(ch in raw for ch in ",/\\."):
            parts = [p.strip() for p in _re.split(r"[,\n]", raw) if p.strip()]
            if parts:
                return len(parts), parts if len(parts) > 1 else raw
        return None, raw
    if value is None:
        return 0, None
    return None, value


_TRUE = {"true", "yes", "1", "pass", "passed", "success", "ok"}
_FALSE = {"false", "no", "0", "fail", "failed", "failure", "error"}


def _coerce_bool(value):
    """Return (bool, salvage_or_None) or (None, reason)."""
    if isinstance(value, bool):
        return value, None
    if isinstance(value, int) and value in (0, 1):
        return bool(value), None
    if isinstance(value, str):
        low = value.strip().lower()
        if low in _TRUE:
            return True, None
        if low in _FALSE:
            return False, None
    return None, value


def _coerce_triage(value):
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if not isinstance(value, str):
        return None
    # Collapse internal whitespace, drop trailing punctuation.
    raw = _re.sub(r"\s+", " ", value).strip().strip(".,;:!-").strip()
    if not raw:
        return None

    lowered = raw.lower()
    for prefix in TRIAGE_PREFIXES:
        if lowered.startswith(prefix):
            raw = raw[len(prefix):].strip().strip(".").strip()
            lowered = raw.lower()
            break

    for valid in TRIAGE_VALUES:
        if lowered == valid.lower():
            return valid
    if lowered in TRIAGE_LEGACY:
        return TRIAGE_LEGACY[lowered]
    return None


# --------------------------------------------------------------------------
# normalize
# --------------------------------------------------------------------------

def _append_salvage(notes, payload):
    """Append a machine-readable salvage block to a notes string."""
    if not payload:
        return notes
    try:
        # Compact separators so this matches JSON.stringify byte-for-byte.
        # The dashboard normalizes with a JS port generated from this module,
        # and Python's default ", "/": " spacing made the two emit different
        # `notes` strings for identical input — indistinguishable from a real
        # divergence when comparing the two implementations.
        blob = _json.dumps(payload, ensure_ascii=False, default=str,
                           separators=(",", ":"))
    except Exception:
        blob = _json.dumps({"unserializable": str(payload)[:500]})
    block = "%s %s" % (SALVAGE_TAG, blob)
    return ("%s %s" % (notes, block)) if notes else block


def has_salvage(entry):
    return isinstance(entry.get("notes"), str) and SALVAGE_TAG in entry["notes"]


def normalize(entry, duplicates=None):
    """Normalize one parsed entry against the schema.

    Returns (normalized_dict_or_None, changes, fatal_problems).
    Non-empty fatal_problems means the entry must be quarantined.
    """
    changes, fatal, salvage = [], [], {}

    if not isinstance(entry, dict):
        return None, changes, ["body must be a JSON object"]

    entry = dict(entry)

    # --- fold known aliases onto their real fields first -------------------
    for alias, target in ALIAS_MAP.items():
        if alias not in entry:
            continue
        value = entry.pop(alias)
        if target and target not in entry:
            entry[target] = value
            changes.append("alias %s -> %s" % (alias, target))
        else:
            salvage[alias] = value
            changes.append("alias %s salvaged (%s already set)" % (alias, target))

    if duplicates:
        salvage["_duplicate_keys"] = duplicates
        changes.append("duplicate JSON keys shadowed: %s" % sorted(duplicates))

    # --- triage (fatal) ---------------------------------------------------
    triage = _coerce_triage(entry.get("triage"))
    if triage is None:
        fatal.append("missing or unrecognizable triage: %r" % (entry.get("triage"),))
    elif triage != entry.get("triage"):
        changes.append("triage %r -> %r" % (entry.get("triage"), triage))
        # Recorded on the entry, not just on stderr. The `P.B.T. ` prefix comes
        # from the rules file's own mandate that the triage LABEL open every
        # response; an agent reusing that label verbatim as the field value
        # produces "P.B.T. Complex". Without this we cannot tell whether that
        # instruction is still leaking into the data.
        salvage["_triage_corrected_from"] = entry.get("triage")

    if not entry.get("task") or not str(entry.get("task")).strip():
        fatal.append("missing task")

    if fatal:
        return None, changes, fatal

    # --- ts (fatal if unparseable) ----------------------------------------
    ts_before = entry.get("ts")
    canonical_ts, ts_note = normalize_ts(ts_before)
    if canonical_ts is None:
        return None, changes, [ts_note]
    if canonical_ts != ts_before:
        changes.append("ts %r -> %r" % (ts_before, canonical_ts))
        entry["ts"] = canonical_ts
    if ts_note:
        # The ORIGINAL, captured before the replacement above. Reading
        # entry["ts"] here recorded the already-promoted value, which
        # round-tripped the very thing the marker exists to preserve.
        salvage["ts_original"] = ts_before

    # --- typed fields -----------------------------------------------------
    out = {}
    for field in FIELD_ORDER:
        kind, default, nullable = SCHEMA[field]
        blank_default = list(default) if isinstance(default, list) else default

        if field == "triage":
            out[field] = triage
            continue
        if field == "notes":
            continue  # written last, after salvage is complete

        if field not in entry:
            out[field] = blank_default
            changes.append("filled missing %s=%r" % (field, blank_default))
            if field in ATTRIBUTION_FIELDS:
                salvage.setdefault("_defaulted_attribution", []).append(field)
            continue

        value = entry[field]

        if value is None:
            if nullable:
                out[field] = None
            else:
                out[field] = blank_default
                changes.append("null %s -> %r" % (field, blank_default))
                if field in ATTRIBUTION_FIELDS:
                    salvage.setdefault("_defaulted_attribution", []).append(field)
            continue

        if kind == INT:
            new, extra = _coerce_int(value)
            if new is None:
                out[field] = blank_default
                salvage[field] = extra
                changes.append("uncoercible %s (salvaged) -> %r" % (field, blank_default))
            else:
                if isinstance(value, bool) or not isinstance(value, int) or new != value:
                    changes.append("%s %r -> %d" % (field, value, new))
                out[field] = new
                if extra is not None:
                    salvage[field] = extra

        elif kind == BOOL:
            new, extra = _coerce_bool(value)
            if new is None:
                out[field] = blank_default
                salvage[field] = extra
                changes.append("uncoercible %s=%r (salvaged) -> %r"
                               % (field, value, blank_default))
            else:
                if new is not value:
                    changes.append("%s %r -> %r" % (field, value, new))
                out[field] = new

        elif kind == LIST:
            if isinstance(value, list):
                out[field] = value
            elif isinstance(value, str) and value.strip():
                out[field] = [value.strip()]
                changes.append("%s str -> list" % field)
            else:
                out[field] = list(blank_default)
                salvage[field] = value
                changes.append("%s %r (salvaged) -> []" % (field, value))

        else:  # STR
            if isinstance(value, str):
                out[field] = value
            else:
                out[field] = str(value)
                salvage[field] = value
                changes.append("%s %r -> str" % (field, value))

    # --- unknown keys: preserve, never discard ----------------------------
    unknown = [k for k in entry if k not in SCHEMA]
    if unknown:
        for key in sorted(unknown):
            salvage[key] = entry[key]
        changes.append("off-schema keys salvaged: %s" % sorted(unknown))

    # --- notes last, carrying the salvage block ---------------------------
    notes_value = entry.get("notes")
    if notes_value is not None and not isinstance(notes_value, str):
        salvage["notes_original"] = notes_value
        notes_value = str(notes_value)
        changes.append("notes coerced to str")
    out["notes"] = _append_salvage(notes_value, salvage)

    return {k: out[k] for k in FIELD_ORDER}, changes, []


# --------------------------------------------------------------------------
# read-only reporting (used by the Monday audit)
# --------------------------------------------------------------------------

def violations(entry):
    """Report, rather than repair. The audit must tell the truth about disk."""
    problems = []
    if not isinstance(entry, dict):
        return ["not a JSON object"]

    for field in REQUIRED:
        if not entry.get(field):
            problems.append("missing required %s" % field)

    if entry.get("ts") and not is_iso_datetime(entry.get("ts")):
        problems.append("ts is not an ISO-8601 datetime: %r" % (entry.get("ts"),))

    if entry.get("triage") not in TRIAGE_VALUES:
        problems.append("invalid triage: %r" % (entry.get("triage"),))

    for field in FIELD_ORDER:
        if field not in entry:
            problems.append("missing field %s" % field)
            continue
        kind, _default, nullable = SCHEMA[field]
        value = entry[field]
        if value is None:
            if not nullable:
                problems.append("%s is null" % field)
            continue
        if kind == INT and (isinstance(value, bool) or not isinstance(value, int)):
            problems.append("%s is %s, expected int" % (field, type(value).__name__))
        elif kind == BOOL and not isinstance(value, bool):
            problems.append("%s is %s, expected bool" % (field, type(value).__name__))
        elif kind == LIST and not isinstance(value, list):
            problems.append("%s is %s, expected list" % (field, type(value).__name__))
        elif kind == STR and not isinstance(value, str):
            problems.append("%s is %s, expected str" % (field, type(value).__name__))

    for key in entry:
        if key not in SCHEMA:
            problems.append("off-schema key: %s" % key)

    problems.extend(implausible(entry))
    return problems


def salvage_payload(entry):
    """Parse the [pbt-salvage] block(s) back out of `notes`. {} if absent.

    Scans *every* occurrence of the tag and merges each one that decodes,
    rather than trusting the first. Two cases make that necessary, and both
    silently lost markers when this took the first match only:

      * an entry can legitimately carry more than one block — the repair
        appends a `ts_disambiguated_from` block after an existing one
      * the tag can appear inside the author's own `notes` prose, in which
        case the first match is not a JSON object at all and the real block
        sits further along

    Losing a block here would under-report the very emitter-quality signal
    these markers exist to provide, so it fails toward finding them.
    """
    notes = entry.get("notes")
    if not isinstance(notes, str) or SALVAGE_TAG not in notes:
        return {}

    merged = {}
    decoder = _json.JSONDecoder()
    position = notes.find(SALVAGE_TAG)
    while position != -1:
        blob = notes[position + len(SALVAGE_TAG):].lstrip()
        try:
            obj, _end = decoder.raw_decode(blob)
            if isinstance(obj, dict):
                merged.update(obj)
        except ValueError:
            pass
        position = notes.find(SALVAGE_TAG, position + len(SALVAGE_TAG))
    return merged


def emitter_quality(entries):
    """Measure how well the WRITE SIDE is behaving, not the log's validity.

    The log is guaranteed schema-clean by the gate, so `violations()` will
    report zero even when the emitter is producing near-empty payloads. This
    is the companion metric: it counts what the gate had to paper over.

    Returns a dict of counts plus the offending entries, for the audit's
    Attribution Quality section.
    """
    total = 0
    unattributed = []
    salvaged = []
    triage_corrected = []
    defaulted_attribution = []

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        total += 1

        if any(entry.get(f) == "unknown" for f in ATTRIBUTION_FIELDS):
            unattributed.append(entry)

        payload = salvage_payload(entry)
        if payload:
            salvaged.append(entry)
        if "_triage_corrected_from" in payload:
            triage_corrected.append((entry, payload["_triage_corrected_from"]))
        if payload.get("_defaulted_attribution"):
            defaulted_attribution.append((entry, payload["_defaulted_attribution"]))

    def pct(n):
        return round(100.0 * n / total, 1) if total else 0.0

    return {
        "total": total,
        "unattributed": len(unattributed),
        "unattributed_pct": pct(len(unattributed)),
        "unattributed_entries": unattributed,
        "salvaged": len(salvaged),
        "salvaged_pct": pct(len(salvaged)),
        "triage_corrected": triage_corrected,
        "defaulted_attribution": defaulted_attribution,
    }


def implausible(entry):
    """Values that are schema-valid but almost certainly wrong."""
    notes = []
    if not isinstance(entry, dict):
        return notes
    for field, (kind, _d, _n) in SCHEMA.items():
        if kind != INT:
            continue
        value = entry.get(field)
        if not isinstance(value, int) or isinstance(value, bool):
            continue
        if value < 0:
            notes.append("%s is negative (%d)" % (field, value))
        elif field == "duration_min" and value > MAX_DURATION_MIN:
            notes.append("duration_min implausibly large (%d)" % value)
        elif field != "duration_min" and value > MAX_COUNT:
            notes.append("%s implausibly large (%d)" % (field, value))
    return notes
