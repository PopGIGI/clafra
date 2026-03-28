# SKILL-GOVERNANCE — Master Context

This is the user-level governance layer. It applies to **all projects** and supersedes project-level CLAUDE.md files.

## Rules (Constitutional)

You MUST follow these rules in every session, in every project:

1. **Read `SKILL-GOVERNANCE.md`** at session start if the project has one. It is the full constitutional reference.
2. **Never create tools/skills manually.** Always use `.clafra/create-tool.sh` which enforces creation rules (pattern threshold ≥3, similarity check, mandatory fields).
3. **Never delete tools/skills.** Use `.clafra/deprecate.sh` to move them to `deprecated/` with an audit trail.
4. **Run `.clafra/validate.sh --session-start`** at the beginning of each session to surface actionable issues (staleness, pending reviews, stack drift).
5. **Before creating any tool or skill**, check for semantic overlap with existing ones. The creation script handles this automatically.
6. **Respect the deprecation path.** Tools marked stale for 2+ milestones are candidates for deprecation. Flag them — do not silently ignore.
7. **Do not modify SKILL-GOVERNANCE.md** without explicit human approval. It is constitutional.

## Governance Scripts

When a project has `.clafra/` installed, the following scripts are available:

| Script | Purpose |
|--------|---------|
| `.clafra/validate.sh --session-start` | Lightweight session check |
| `.clafra/validate.sh --full` | Full milestone audit |
| `.clafra/create-tool.sh` | Guided tool/skill creation |
| `.clafra/deprecate.sh` | Deprecate with audit trail |
| `.clafra/clafra-doctor.sh` | Health & prerequisite check |

## Detection

A project uses clafra governance if any of these exist:
- `SKILL-GOVERNANCE.md` in the project root
- `.clafra/` directory in the project root
- `tools/` or `skills/` directories with `.json` files
