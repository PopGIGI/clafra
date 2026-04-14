#!/usr/bin/env bash
# cron-dispatch.sh — Multi-repo orchestrator for clafra cron maintenance
#
# Iterates through repos listed in repos.json, runs cron-gather.sh for each,
# then invokes claude CLI (headless) to analyze the artifact and write results.
#
# Usage: cron-dispatch.sh [--dry-run]
#   --dry-run   Gather artifacts only, skip LLM analysis

set -euo pipefail

CLAFRA_SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
GATHER_SCRIPT="${CLAFRA_SOURCE}/scripts/cron-gather.sh"
REPOS_FILE="${CLAFRA_SOURCE}/.clafra/repos.json"
CRON_LOG="${CLAFRA_SOURCE}/.clafra/cron.log"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# --------------------------------------------------
# Helpers
# --------------------------------------------------
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
    local msg="[$(now_iso)] $1"
    echo "$msg"
    echo "$msg" >> "$CRON_LOG"
}

die() { log "ERROR: $1"; exit 1; }

# --------------------------------------------------
# Preflight
# --------------------------------------------------
[[ -f "$GATHER_SCRIPT" ]] || die "cron-gather.sh not found at $GATHER_SCRIPT"
[[ -f "$REPOS_FILE" ]] || die "repos.json not found at $REPOS_FILE"
command -v jq &>/dev/null || die "jq is required"
command -v claude &>/dev/null || die "claude CLI not found"

# --------------------------------------------------
# Check claude auth
# --------------------------------------------------
check_auth() {
    # Try a minimal claude invocation to verify auth
    if claude -p "echo ok" --max-turns 1 --dangerously-skip-permissions &>/dev/null; then
        return 0
    else
        return 1
    fi
}

AUTH_OK=true
if [[ "$DRY_RUN" == "false" ]]; then
    if ! check_auth; then
        AUTH_OK=false
        log "WARNING: Claude auth failed (token expired?). Gathering artifacts only — LLM analysis skipped."
        log "Re-auth by running 'claude' interactively, then re-run: $0"
    fi
fi

# --------------------------------------------------
# LLM prompt template
# --------------------------------------------------
build_prompt() {
    local artifact="$1"
    local repo_name="$2"
    local repo_path="$3"

    cat <<'PROMPT_HEADER'
You are a clafra governance maintenance agent. You receive a pre-computed artifact from cron-gather.sh containing concrete facts about a repository. Your job is to produce a structured JSON result file.

RULES:
1. Every conclusion you draw MUST cite a specific field from the gathered artifact. If the artifact does not contain evidence for a claim, do not make the claim.
2. You MUST NOT speculate about what code does. All evidence is in the artifact.
3. For Tier 1 (mechanical fixes), you may ONLY propose fixes where the artifact provides an unambiguous mapping (e.g., a file rename where old_path appears in a criterion and new_path exists).
4. For Tier 2 (proposals), you MUST include the concrete evidence from the artifact that supports each proposal.
5. If no_changes is true and all criteria pass, output a minimal result with empty arrays and exit.
6. If no_tools is true, check only patterns_flagged for new tool candidates.

PROMPT_HEADER

    echo ""
    echo "GATHERED ARTIFACT:"
    echo "<artifact>"
    echo "$artifact"
    echo "</artifact>"
    echo ""

    cat <<'PROMPT_TASK'
TASK:
Analyze the artifact and output ONLY valid JSON (no markdown fences, no explanation) with this schema:

{
  "run_at": "<current ISO timestamp>",
  "commit_range": "<from artifact>",
  "tier1": {
    "dead_criteria": [
      {"tool": "", "criterion": "", "reason": "<cite artifact field>", "proposed_fix": "", "confidence": "high|medium|low"}
    ],
    "renamed_references": [
      {"tool": "", "old_path": "", "new_path": "", "criterion_before": "", "criterion_after": "", "confidence": "high|medium|low"}
    ],
    "missing_stack_deps": [
      {"tool": "", "dep": "", "reason": ""}
    ]
  },
  "tier2": {
    "new_tool_candidates": [
      {"pattern": "", "description": "", "frequency": 0, "reason": ""}
    ],
    "deprecation_flags": [
      {"tool": "", "reason": "", "evidence": ""}
    ],
    "consolidation_suggestions": [
      {"tools": [], "reason": "", "evidence": ""}
    ]
  },
  "summary": "<one-line summary of findings>"
}

If there are no findings for a category, use an empty array [].
Output ONLY the JSON object, nothing else.
PROMPT_TASK
}

# --------------------------------------------------
# Process each repo
# --------------------------------------------------
TOTAL=0
PROCESSED=0
SKIPPED=0
ERRORS=0

REPO_COUNT=$(jq '.repos | length' "$REPOS_FILE")
log "=== clafra cron dispatch starting: ${REPO_COUNT} repos ==="

for i in $(seq 0 $((REPO_COUNT - 1))); do
    repo_path=$(jq -r ".repos[$i].path" "$REPOS_FILE")
    repo_name=$(jq -r ".repos[$i].name" "$REPOS_FILE")
    TOTAL=$((TOTAL + 1))

    log "--- Processing: ${repo_name} (${repo_path}) ---"

    # Check repo exists
    if [[ ! -d "$repo_path" ]]; then
        log "SKIP: ${repo_name} — directory does not exist"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check repo has .clafra
    if [[ ! -d "${repo_path}/.clafra" ]]; then
        log "SKIP: ${repo_name} — no .clafra directory (not initialized)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Run gather
    local_artifact=""
    if ! local_artifact=$("$GATHER_SCRIPT" "$repo_path" 2>&1); then
        log "ERROR: ${repo_name} — gather failed"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Check if skipped (no commits)
    if echo "$local_artifact" | jq -e '.skipped' &>/dev/null; then
        skip_reason=$(echo "$local_artifact" | jq -r '.skipped')
        log "SKIP: ${repo_name} — ${skip_reason}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Ensure cron-results directory exists
    mkdir -p "${repo_path}/.clafra/cron-results"

    TODAY=$(date -u +%Y-%m-%d)
    RESULT_FILE="${repo_path}/.clafra/cron-results/${TODAY}.json"
    PENDING_FILE="${repo_path}/.clafra/cron-results/${TODAY}-pending.json"

    # Check for no-op: no changes and all criteria pass
    no_changes=$(echo "$local_artifact" | jq -r '.no_changes')
    no_tools=$(echo "$local_artifact" | jq -r '.no_tools')
    all_pass=$(echo "$local_artifact" | jq '[.tools[]?.criteria[]?.passes // true] | all' 2>/dev/null || echo "true")

    if [[ "$no_changes" == "true" && "$all_pass" == "true" && "$no_tools" == "true" ]]; then
        log "SKIP: ${repo_name} — no changes, no tools"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "$DRY_RUN" == "true" || "$AUTH_OK" == "false" ]]; then
        # Save artifact as pending for later processing
        echo "$local_artifact" > "$PENDING_FILE"
        log "PENDING: ${repo_name} — artifact saved to ${PENDING_FILE}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Invoke Claude CLI with the artifact
    prompt=$(build_prompt "$local_artifact" "$repo_name" "$repo_path")

    llm_result=""
    if llm_result=$(echo "$prompt" | claude -p \
        --max-turns 1 \
        --dangerously-skip-permissions \
        --allowedTools "" \
        --output-format json \
        2>/dev/null); then

        # Extract the text result from claude's JSON output
        result_text=$(echo "$llm_result" | jq -r '.result // empty' 2>/dev/null || echo "$llm_result")

        # Try to parse as JSON; if it fails, wrap in an error result
        if echo "$result_text" | jq empty 2>/dev/null; then
            # Add reviewed field and write
            echo "$result_text" | jq '. + {reviewed: false}' > "$RESULT_FILE"
        else
            # LLM returned non-JSON; save raw for debugging
            jq -n \
                --arg run_at "$(now_iso)" \
                --arg error "LLM returned non-JSON output" \
                --arg raw "$result_text" \
                '{run_at: $run_at, error: $error, raw_output: $raw, reviewed: false}' > "$RESULT_FILE"
            log "WARNING: ${repo_name} — LLM returned non-JSON, saved raw output"
        fi

        # Update cron state
        current_commit=$(echo "$local_artifact" | jq -r '.current_commit')
        jq -n \
            --arg last_cron_commit "$current_commit" \
            --arg last_cron_run "$(now_iso)" \
            --arg last_cron_result ".clafra/cron-results/${TODAY}.json" \
            '{last_cron_commit: $last_cron_commit, last_cron_run: $last_cron_run, last_cron_result: $last_cron_result}' \
            > "${repo_path}/.clafra/cron-state.json"

        # Remove pending file if it exists
        rm -f "$PENDING_FILE"

        log "OK: ${repo_name} — results written to ${RESULT_FILE}"
        PROCESSED=$((PROCESSED + 1))
    else
        # Claude invocation failed; save artifact as pending
        echo "$local_artifact" > "$PENDING_FILE"
        log "ERROR: ${repo_name} — claude invocation failed, artifact saved as pending"
        ERRORS=$((ERRORS + 1))
    fi
done

log "=== dispatch complete: ${PROCESSED} processed, ${SKIPPED} skipped, ${ERRORS} errors (of ${TOTAL} total) ==="
