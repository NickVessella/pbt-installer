// GENERATED FILE — do not edit by hand.
//
// Source: shared/lib/pbt_schema.py
// Regenerate: python3 scripts/generate-dashboard-schema.py
//
// The 27-field PBT log contract, emitted from the Python module so the
// dashboard cannot drift from the local write path. Mirrors
// pbt_schema.normalize(): repair what is recoverable, reject only an entry
// whose meaning is unrecoverable.

const FIELD_ORDER = [
  "ts",
  "user",
  "project",
  "triage",
  "task",
  "files_changed",
  "files_created",
  "tests_written",
  "tests_fixed",
  "all_tests_passed",
  "risks_identified",
  "risks_mitigated",
  "risks_out_of_scope",
  "risks_ask_user",
  "stopped_to_ask_user",
  "plan_deviations",
  "pre_existing_issues",
  "language",
  "visual_check",
  "visual_issues_found",
  "escalated",
  "escalated_from",
  "spiked",
  "spike_resolved",
  "mid_plan_spike",
  "duration_min",
  "notes"
];

// field -> [kind, default, nullable]
const SCHEMA = {
  "ts": [
    "str",
    null,
    false
  ],
  "user": [
    "str",
    "unknown",
    false
  ],
  "project": [
    "str",
    "unknown",
    false
  ],
  "triage": [
    "str",
    null,
    false
  ],
  "task": [
    "str",
    null,
    false
  ],
  "files_changed": [
    "int",
    0,
    false
  ],
  "files_created": [
    "int",
    0,
    false
  ],
  "tests_written": [
    "int",
    0,
    false
  ],
  "tests_fixed": [
    "int",
    0,
    false
  ],
  "all_tests_passed": [
    "bool",
    null,
    true
  ],
  "risks_identified": [
    "int",
    0,
    false
  ],
  "risks_mitigated": [
    "int",
    0,
    false
  ],
  "risks_out_of_scope": [
    "int",
    0,
    false
  ],
  "risks_ask_user": [
    "int",
    0,
    false
  ],
  "stopped_to_ask_user": [
    "bool",
    false,
    false
  ],
  "plan_deviations": [
    "int",
    0,
    false
  ],
  "pre_existing_issues": [
    "list",
    [],
    false
  ],
  "language": [
    "str",
    "unknown",
    false
  ],
  "visual_check": [
    "bool",
    false,
    false
  ],
  "visual_issues_found": [
    "int",
    0,
    false
  ],
  "escalated": [
    "bool",
    false,
    false
  ],
  "escalated_from": [
    "str",
    null,
    true
  ],
  "spiked": [
    "bool",
    false,
    false
  ],
  "spike_resolved": [
    "bool",
    false,
    false
  ],
  "mid_plan_spike": [
    "bool",
    false,
    false
  ],
  "duration_min": [
    "int",
    null,
    true
  ],
  "notes": [
    "str",
    null,
    true
  ]
};

const TRIAGE_VALUES = [
  "Trivial",
  "Small Scope",
  "Complex",
  "Investigative"
];
const TRIAGE_PREFIXES = [
  "p.b.t.",
  "pbt"
];
const TRIAGE_LEGACY = {
  "quick": "Trivial",
  "small": "Small Scope",
  "investigate": "Investigative",
  "investigation": "Investigative"
};
const ALIAS_MAP = {
  "timestamp": "ts",
  "tier": "triage",
  "files_touched": "files_changed",
  "goal": "task",
  "tests_added": "tests_written",
  "escalation_count": null
};
const ATTRIBUTION_FIELDS = [
  "user",
  "project",
  "language"
];
const SALVAGE_TAG = "[pbt-salvage]";

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const BASIC_OFFSET = /([+-])(\d{2})(\d{2})$/;
const LEADING_INT = /^\s*(-?\d+)/;

function normalizeTs(value) {
  if (typeof value !== 'string' || !value.trim()) return [null, 'ts is not a string'];
  const raw = value.trim();
  if (DATE_ONLY.test(raw)) return [raw + 'T00:00:00Z', 'original ts was date-only: ' + raw];
  const candidate = raw.replace(BASIC_OFFSET, '$1$2:$3');
  if (Number.isNaN(Date.parse(candidate))) {
    return [null, 'ts is not an ISO-8601 datetime: ' + JSON.stringify(value)];
  }
  return [candidate, null];
}

function coerceTriage(value) {
  if (Array.isArray(value) && value.length === 1) value = value[0];
  if (typeof value !== 'string') return null;
  let raw = value.replace(/\s+/g, ' ').trim().replace(/[.,;:!-]+$/, '').trim();
  if (!raw) return null;
  let lowered = raw.toLowerCase();
  for (const prefix of TRIAGE_PREFIXES) {
    if (lowered.startsWith(prefix)) {
      raw = raw.slice(prefix.length).trim().replace(/^\.+/, '').trim();
      lowered = raw.toLowerCase();
      break;
    }
  }
  for (const valid of TRIAGE_VALUES) {
    if (lowered === valid.toLowerCase()) return valid;
  }
  if (Object.prototype.hasOwnProperty.call(TRIAGE_LEGACY, lowered)) return TRIAGE_LEGACY[lowered];
  return null;
}

function coerceInt(value) {
  if (typeof value === 'boolean') return [value ? 1 : 0, null];
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return [null, 'non-finite number'];
    const rounded = Math.round(value);
    return [rounded, rounded === value ? null : value];
  }
  if (Array.isArray(value)) {
    const items = value.filter((x) => String(x).trim());
    return [items.length, items.length ? items : null];
  }
  if (value && typeof value === 'object') return [null, value];
  if (typeof value === 'string') {
    const raw = value.trim();
    if (!raw) return [0, null];
    if (/^-?\d+$/.test(raw)) return [parseInt(raw, 10), null];
    const lead = LEADING_INT.exec(raw);
    if (lead) return [parseInt(lead[1], 10), raw];
    if (/[,/\\.]/.test(raw)) {
      const parts = raw.split(/[,\n]/).map((p) => p.trim()).filter(Boolean);
      if (parts.length) return [parts.length, parts.length > 1 ? parts : raw];
    }
    return [null, raw];
  }
  if (value === null || value === undefined) return [0, null];
  return [null, value];
}

const TRUE_WORDS = new Set(['true', 'yes', '1', 'pass', 'passed', 'success', 'ok']);
const FALSE_WORDS = new Set(['false', 'no', '0', 'fail', 'failed', 'failure', 'error']);

function coerceBool(value) {
  if (typeof value === 'boolean') return [value, null];
  if (value === 0 || value === 1) return [Boolean(value), null];
  if (typeof value === 'string') {
    const low = value.trim().toLowerCase();
    if (TRUE_WORDS.has(low)) return [true, null];
    if (FALSE_WORDS.has(low)) return [false, null];
  }
  return [null, value];
}

/**
 * Normalize one entry. Returns { entry, changes, fatal }.
 * A non-empty `fatal` array means the caller should reject with 400.
 */
function normalize(input) {
  const changes = [];
  const salvage = {};
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { entry: null, changes, fatal: ['body must be a JSON object'] };
  }

  const entry = Object.assign({}, input);

  for (const [alias, target] of Object.entries(ALIAS_MAP)) {
    if (!(alias in entry)) continue;
    const value = entry[alias];
    delete entry[alias];
    if (target && !(target in entry)) {
      entry[target] = value;
      changes.push('alias ' + alias + ' -> ' + target);
    } else {
      salvage[alias] = value;
    }
  }

  const triage = coerceTriage(entry.triage);
  const fatal = [];
  if (triage === null) fatal.push('missing or unrecognizable triage: ' + JSON.stringify(entry.triage));
  else if (triage !== entry.triage) {
    changes.push('triage ' + JSON.stringify(entry.triage) + ' -> ' + JSON.stringify(triage));
    salvage._triage_corrected_from = entry.triage;
  }
  if (!entry.task || !String(entry.task).trim()) fatal.push('missing task');
  if (fatal.length) return { entry: null, changes, fatal };

  const [canonicalTs, tsNote] = normalizeTs(entry.ts);
  if (canonicalTs === null) return { entry: null, changes, fatal: [tsNote] };
  if (canonicalTs !== entry.ts) {
    changes.push('ts ' + JSON.stringify(entry.ts) + ' -> ' + JSON.stringify(canonicalTs));
    entry.ts = canonicalTs;
  }
  if (tsNote) salvage.ts_original = input.ts;

  const out = {};
  for (const field of FIELD_ORDER) {
    const [kind, def, nullable] = SCHEMA[field];
    const blank = Array.isArray(def) ? def.slice() : def;

    if (field === 'triage') { out[field] = triage; continue; }
    if (field === 'notes') continue;

    if (!(field in entry)) {
      out[field] = blank;
      changes.push('filled missing ' + field);
      if (ATTRIBUTION_FIELDS.includes(field)) {
        (salvage._defaulted_attribution = salvage._defaulted_attribution || []).push(field);
      }
      continue;
    }

    const value = entry[field];
    if (value === null || value === undefined) {
      if (nullable) { out[field] = null; }
      else {
        out[field] = blank;
        changes.push('null ' + field);
        if (ATTRIBUTION_FIELDS.includes(field)) {
          (salvage._defaulted_attribution = salvage._defaulted_attribution || []).push(field);
        }
      }
      continue;
    }

    if (kind === 'int') {
      const [num, extra] = coerceInt(value);
      if (num === null) { out[field] = blank; salvage[field] = extra; }
      else {
        out[field] = num;
        if (typeof value !== 'number' || num !== value) changes.push(field + ' coerced to int');
        if (extra !== null && extra !== undefined) salvage[field] = extra;
      }
    } else if (kind === 'bool') {
      const [bool, extra] = coerceBool(value);
      if (bool === null) { out[field] = blank; salvage[field] = extra; }
      else { out[field] = bool; if (bool !== value) changes.push(field + ' coerced to bool'); }
    } else if (kind === 'list') {
      if (Array.isArray(value)) out[field] = value;
      else if (typeof value === 'string' && value.trim()) { out[field] = [value.trim()]; changes.push(field + ' str -> list'); }
      else { out[field] = blank; salvage[field] = value; }
    } else {
      if (typeof value === 'string') out[field] = value;
      else { out[field] = String(value); salvage[field] = value; }
    }
  }

  for (const key of Object.keys(entry)) {
    if (!(key in SCHEMA)) salvage[key] = entry[key];
  }

  let notes = typeof entry.notes === 'string' ? entry.notes : (entry.notes == null ? null : String(entry.notes));
  if (Object.keys(salvage).length) {
    const block = SALVAGE_TAG + ' ' + JSON.stringify(salvage);
    notes = notes ? notes + ' ' + block : block;
  }
  out.notes = notes;

  const ordered = {};
  for (const field of FIELD_ORDER) ordered[field] = out[field];
  return { entry: ordered, changes, fatal: [] };
}

module.exports = { normalize, FIELD_ORDER, SCHEMA, TRIAGE_VALUES, SALVAGE_TAG };
