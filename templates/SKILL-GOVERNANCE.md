# SKILL-GOVERNANCE

Meta-skill. Governs creation, validation, testing, and deprecation of all tools and skills in this
repository. This file is constitutional — change it rarely and intentionally.

---

## Principles

- Tools and skills are **not append-only**. Every creation path requires a deprecation path.
- Summoning is **runtime** — invisible, fast, zero friction.
- Testing is **validation** — explicit, logged, comparable.
- The system runs on rhythms already in place: git commits and session starts.

---

## Tool / Skill Structure

Every tool and skill must carry the following fields at creation:

```json
{
  "name": "",
  "intent": "",
  "stack_dependencies": [],
  "success_criteria": [],
  "created_at": "",
  "last_validated": "",
  "validation_trigger": "on_change | on_dependency_change",
  "status": "active | stale | deprecated",
  "staleness_days": 30
}
```

`intent` is the canonical description used for similarity matching before creation.
`success_criteria` is what the validation pass checks — not a test suite, just enough to detect drift.
`stack_dependencies` flags which tools need revalidation when the stack changes.
`staleness_days` is configurable per-tool (default: 30 days).

---

## Creation Rules

Before any pattern graduates to a tool or skill:

1. **Threshold** — Pattern must appear in at least 3 sessions. Single-session patterns stay in
   `patterns.json` only.
2. **Similarity check** — Run intent matching against all existing tools and skills. Match on
   meaning, not name. If intent overlaps significantly, update the existing tool rather than
   creating a new one.
3. **Stack binding** — Declare `stack_dependencies` explicitly. Undeclared dependencies
   default to a full revalidation on any stack change.
4. **Success criteria** — Must be written at creation. A tool without success criteria cannot be
   validated and defaults to `stale` immediately.

---

## Validation

### When it runs

- **Session start** — lightweight pass. Surfaces only what is actionable in the current session.
  Not a full audit.
- **Pre-commit hook** — triggered when a tool/skill file changes, or when a declared
  `stack_dependency` changes (e.g. `package.json` diff). Blocks commit on schema violations.
- **Slow cadence** — full audit runs per milestone, not per session.

### What it checks

- `last_validated` timestamp against a staleness threshold (per-tool `staleness_days` or milestone
  boundary)
- `stack_dependencies` against current stack state
- `success_criteria` against current codebase behavior

### Output

- `active` — passes all checks
- `stale` — criteria unmet or threshold exceeded. Flagged at next session start if relevant to
  current work.
- `deprecated` — manually marked or stale for 2+ consecutive milestones. Moved to
  `/deprecated/`, not deleted.

---

## Testing vs Summoning

|            | Summoning               | Testing                        |
|------------|-------------------------|--------------------------------|
| When       | Runtime, during session | Pre-commit or session start    |
| Trigger    | Context — Claude calls  | Change signal or cadence       |
| Overhead   | Zero                    | Proportional to risk           |
| Output     | Result                  | Pass / stale / deprecated      |
| Logged     | No                      | Yes                            |

These must never be unified. A tool that tests itself on every call is not a tool.

---

## Stack Change Protocol

When `package.json` or equivalent changes:

1. Diff declared `stack_dependencies` against the change
2. Flag affected tools as `stale` pending revalidation
3. Surface at next session start — do not interrupt active session
4. Revalidation updates `last_validated` and restores `active` status

---

## Redundancy Prevention

Before creating any tool or skill:

- Retrieve all existing intents from `tools/` and `skills/`
- Run similarity pass — semantic match, not string match
- If overlap found: extend existing tool, do not create new one
- If ambiguous: flag for human decision, do not auto-create

### Two-Tier Similarity

- **Tier 1 (local)**: Token overlap cosine similarity. Immediate, no network. Blocks on >0.7 overlap.
- **Tier 2 (async)**: Queued for next session start. Sends to remote Claude via SSH for semantic review. Non-blocking.

---

## Deprecation Path

1. Tool marked `stale` for 2+ consecutive milestones → auto-flagged for deprecation
2. Human confirms or overrides at milestone boundary
3. Confirmed deprecated tools move to `/deprecated/` with a `deprecated_at` timestamp and reason
4. `/deprecated/` is never purged — it is the audit trail

---

## Session Log → Pattern Pipeline

```
git commit
→ post-commit hook reads session log
→ strips to decisions and gaps only
→ diffs against patterns.json
→ increments pattern frequency
→ patterns at threshold 3 → flagged for tool creation review
→ review occurs at session start, not mid-session
```

Session logs are never fed raw into pattern matching. They are reduced first.

---

## Self-Governance

This skill cannot validate itself with the system it governs.

- Changes to this file require explicit human decision
- No automated revalidation of SKILL-GOVERNANCE
- Review manually at each milestone boundary
- Version it in git — its history is its audit trail

---

## File Locations

```
/CLAUDE.md               — master context, session constitution
/SKILL-GOVERNANCE.md     — this file
/patterns.json           — aggregate pattern data
/tools/                  — active tools
/skills/                 — active skills
/deprecated/             — deprecated artifacts with audit trail
/.clafra/                — governance scripts
```
