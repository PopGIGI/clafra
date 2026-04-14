#!/usr/bin/env bash
# cron-gather.sh — Pure-bash artifact collector for cron maintenance
#
# Collects concrete facts about a single repo: git diffs since last cron run,
# success_criteria pass/fail, stack dependency existence, flagged patterns.
# Outputs a single JSON document to stdout. No LLM calls.
#
# Usage: cron-gather.sh [/path/to/repo]
#   If no path given, uses current git repo root.

set -euo pipefail

REPO_PATH="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
REPO_PATH="$(cd "$REPO_PATH" && pwd)"  # resolve to absolute
CLAFRA_DIR="${REPO_PATH}/.clafra"
CRON_STATE="${CLAFRA_DIR}/cron-state.json"
REPO_NAME=$(basename "$REPO_PATH")

# Path regex reused from build-summon-index.sh:33
PATH_REGEX='[a-zA-Z_][a-zA-Z0-9_/.-]*\.[a-zA-Z]{1,5}'

# --------------------------------------------------
# Helpers
# --------------------------------------------------
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
    # Escape string for JSON embedding
    printf '%s' "$1" | jq -Rs '.'
}

die() { echo "cron-gather: error: $1" >&2; exit 1; }

# --------------------------------------------------
# Preflight
# --------------------------------------------------
[[ -d "$REPO_PATH" ]] || die "repo path does not exist: $REPO_PATH"
git -C "$REPO_PATH" rev-parse --git-dir &>/dev/null || die "not a git repo: $REPO_PATH"
command -v jq &>/dev/null || die "jq is required"

# --------------------------------------------------
# Read cron state (last processed commit)
# --------------------------------------------------
CURRENT_COMMIT=""
CURRENT_COMMIT_SHORT="none"
if git -C "$REPO_PATH" rev-parse HEAD &>/dev/null; then
    CURRENT_COMMIT=$(git -C "$REPO_PATH" rev-parse HEAD)
    CURRENT_COMMIT_SHORT=$(git -C "$REPO_PATH" rev-parse --short HEAD)
fi

# Handle repos with no commits
if [[ -z "$CURRENT_COMMIT" ]]; then
    jq -n \
        --arg repo "$REPO_PATH" \
        --arg repo_name "$REPO_NAME" \
        --arg gathered_at "$(now_iso)" \
        '{repo: $repo, repo_name: $repo_name, gathered_at: $gathered_at, no_changes: true, no_tools: true, skipped: "no commits in repo"}'
    exit 0
fi

LAST_CRON_COMMIT=""
if [[ -f "$CRON_STATE" ]]; then
    LAST_CRON_COMMIT=$(jq -r '.last_cron_commit // ""' "$CRON_STATE" 2>/dev/null)
fi

# If no prior state, use the commit from 7 days ago as baseline
if [[ -z "$LAST_CRON_COMMIT" ]]; then
    LAST_CRON_COMMIT=$(git -C "$REPO_PATH" rev-list -1 --before="7 days ago" HEAD 2>/dev/null || echo "")
fi

# --------------------------------------------------
# Detect changes
# --------------------------------------------------
NO_CHANGES=false
RENAMED_FILES="[]"
DELETED_FILES="[]"
NEW_FILES="[]"
DIFF_STAT=""

if [[ -z "$LAST_CRON_COMMIT" || "$LAST_CRON_COMMIT" == "$CURRENT_COMMIT" ]]; then
    NO_CHANGES=true
else
    # Verify the last commit still exists in the repo
    if ! git -C "$REPO_PATH" cat-file -e "$LAST_CRON_COMMIT" 2>/dev/null; then
        # Commit was rebased away or repo was reset; fall back to 7-day window
        LAST_CRON_COMMIT=$(git -C "$REPO_PATH" rev-list -1 --before="7 days ago" HEAD 2>/dev/null || echo "")
        if [[ -z "$LAST_CRON_COMMIT" ]]; then
            NO_CHANGES=true
        fi
    fi
fi

if [[ "$NO_CHANGES" == "false" ]]; then
    COMMIT_RANGE="${LAST_CRON_COMMIT}..${CURRENT_COMMIT}"

    # Diff stat
    DIFF_STAT=$(git -C "$REPO_PATH" diff --stat "$COMMIT_RANGE" 2>/dev/null || echo "")

    # Renamed files: old_path -> new_path
    RENAMED_FILES=$(git -C "$REPO_PATH" diff --diff-filter=R --name-status "$COMMIT_RANGE" 2>/dev/null | \
        awk -F'\t' '{print "{\"old\":" $2 ",\"new\":" $3 "}"}' | \
        jq -Rs '[split("\n")[] | select(length > 0) | fromjson? // empty]' 2>/dev/null || echo "[]")

    # Use jq properly for renamed files
    RENAMED_FILES=$(git -C "$REPO_PATH" diff --diff-filter=R --name-status "$COMMIT_RANGE" 2>/dev/null | \
        awk -F'\t' '{print $2 "\t" $3}' | \
        jq -Rn '[inputs | split("\t") | select(length == 2) | {old: .[0], new: .[1]}]' 2>/dev/null || echo "[]")

    # Deleted files
    DELETED_FILES=$(git -C "$REPO_PATH" diff --diff-filter=D --name-only "$COMMIT_RANGE" 2>/dev/null | \
        jq -Rn '[inputs | select(length > 0)]' 2>/dev/null || echo "[]")

    # New files
    NEW_FILES=$(git -C "$REPO_PATH" diff --diff-filter=A --name-only "$COMMIT_RANGE" 2>/dev/null | \
        jq -Rn '[inputs | select(length > 0)]' 2>/dev/null || echo "[]")
else
    COMMIT_RANGE="none"
fi

# --------------------------------------------------
# Collect tool/skill data
# --------------------------------------------------
NO_TOOLS=true
TOOLS_JSON="[]"

collect_tools() {
    local dir="$1"  # "tools" or "skills"
    for tool_file in "${REPO_PATH}/${dir}"/*.json; do
        [[ -f "$tool_file" ]] || continue
        NO_TOOLS=false

        local tool_name tool_status staleness_days last_validated
        tool_name=$(jq -r '.name // "unknown"' "$tool_file" 2>/dev/null)
        tool_status=$(jq -r '.status // "unknown"' "$tool_file" 2>/dev/null)
        staleness_days=$(jq -r '.staleness_days // 30' "$tool_file" 2>/dev/null)
        last_validated=$(jq -r '.last_validated // ""' "$tool_file" 2>/dev/null)

        # Skip deprecated tools
        [[ "$tool_status" == "deprecated" ]] && continue

        # Calculate days since validation
        local days_stale=0
        if [[ -n "$last_validated" && "$last_validated" != "null" ]]; then
            local ts_epoch now_epoch
            ts_epoch=$(date -d "$last_validated" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            days_stale=$(( (now_epoch - ts_epoch) / 86400 ))
        else
            days_stale=999
        fi

        # Evaluate each success criterion
        local criteria_json="[]"
        while IFS= read -r criterion; do
            [[ -n "$criterion" ]] || continue

            local passes=true
            local match_count=0

            if ! (cd "$REPO_PATH" && eval "$criterion" &>/dev/null); then
                passes=false
            fi

            # For grep-based criteria, get match count
            if [[ "$passes" == "true" ]] && echo "$criterion" | grep -qE '^grep'; then
                # Replace -q with -c to count matches
                local count_cmd
                count_cmd=$(echo "$criterion" | sed 's/grep -rq/grep -rc/; s/grep -q/grep -c/')
                match_count=$(cd "$REPO_PATH" && eval "$count_cmd" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}' || echo "0")
            fi

            # Extract file paths from criterion
            local files_in_criterion="[]"
            local extracted_paths
            extracted_paths=$(echo "$criterion" | grep -oE "$PATH_REGEX" 2>/dev/null || true)
            if [[ -n "$extracted_paths" ]]; then
                files_in_criterion=$(echo "$extracted_paths" | jq -Rn '[inputs | select(length > 0)]')
            fi

            # Check which referenced files exist
            local files_exist="[]"
            if [[ -n "$extracted_paths" ]]; then
                files_exist=$(echo "$extracted_paths" | while read -r fpath; do
                    if [[ -f "${REPO_PATH}/${fpath}" ]]; then
                        echo "true"
                    else
                        echo "false"
                    fi
                done | jq -Rn '[inputs | select(length > 0) | test("true")]')
            fi

            criteria_json=$(echo "$criteria_json" | jq \
                --arg cmd "$criterion" \
                --argjson passes "$passes" \
                --argjson count "$match_count" \
                --argjson files "$files_in_criterion" \
                --argjson exists "$files_exist" \
                '. + [{command: $cmd, passes: $passes, match_count: $count, files_referenced: $files, files_exist: $exists}]')

        done < <(jq -r '.success_criteria[]?' "$tool_file" 2>/dev/null)

        # Check stack_dependencies existence
        local stack_deps deps_exist
        stack_deps=$(jq -r '.stack_dependencies[]?' "$tool_file" 2>/dev/null)
        local deps_json="[]"
        local deps_exist_json="[]"
        if [[ -n "$stack_deps" ]]; then
            deps_json=$(jq '.stack_dependencies // []' "$tool_file" 2>/dev/null)
            deps_exist_json=$(jq -r '.stack_dependencies[]?' "$tool_file" 2>/dev/null | while read -r dep; do
                if [[ -f "${REPO_PATH}/${dep}" ]]; then
                    echo "true"
                else
                    echo "false"
                fi
            done | jq -Rn '[inputs | select(length > 0) | test("true")]' 2>/dev/null || echo "[]")
        fi

        # Build tool entry
        local rel_path="${dir}/$(basename "$tool_file")"
        TOOLS_JSON=$(echo "$TOOLS_JSON" | jq \
            --arg name "$tool_name" \
            --arg file "$rel_path" \
            --arg status "$tool_status" \
            --argjson criteria "$criteria_json" \
            --argjson stack_deps "$deps_json" \
            --argjson deps_exist "$deps_exist_json" \
            --argjson days_stale "$days_stale" \
            --argjson staleness_days "$staleness_days" \
            '. + [{
                name: $name,
                file: $file,
                status: $status,
                criteria: $criteria,
                stack_dependencies: $stack_deps,
                deps_exist: $deps_exist,
                days_since_validated: $days_stale,
                staleness_threshold: $staleness_days
            }]')
    done
}

collect_tools "tools"
collect_tools "skills"

# --------------------------------------------------
# Flagged patterns from patterns.json
# --------------------------------------------------
PATTERNS_FLAGGED="[]"
PATTERNS_FILE="${REPO_PATH}/patterns.json"
if [[ -f "$PATTERNS_FILE" ]]; then
    PATTERNS_FLAGGED=$(jq '[.patterns[]? | select(.status == "flagged")]' "$PATTERNS_FILE" 2>/dev/null || echo "[]")
fi

# --------------------------------------------------
# Validation log tail (last 20 lines)
# --------------------------------------------------
VALIDATION_LOG_TAIL=""
VALIDATION_LOG="${CLAFRA_DIR}/validation.log"
if [[ -f "$VALIDATION_LOG" ]]; then
    VALIDATION_LOG_TAIL=$(tail -20 "$VALIDATION_LOG" 2>/dev/null || echo "")
fi

# --------------------------------------------------
# Cross-reference: renamed/deleted files vs criteria
# --------------------------------------------------
AFFECTED_CRITERIA="[]"
if [[ "$NO_CHANGES" == "false" && "$NO_TOOLS" == "false" ]]; then
    # Extract all file paths from all criteria
    ALL_CRITERIA_FILES=$(echo "$TOOLS_JSON" | jq -r '.[].criteria[].files_referenced[]?' 2>/dev/null | sort -u)

    # Check renamed files against criteria
    if [[ "$RENAMED_FILES" != "[]" ]]; then
        while IFS= read -r old_path; do
            [[ -n "$old_path" ]] || continue
            new_path=$(echo "$RENAMED_FILES" | jq -r --arg old "$old_path" '.[] | select(.old == $old) | .new' 2>/dev/null)
            if echo "$ALL_CRITERIA_FILES" | grep -qF "$old_path" 2>/dev/null; then
                AFFECTED_CRITERIA=$(echo "$AFFECTED_CRITERIA" | jq \
                    --arg old "$old_path" \
                    --arg new "$new_path" \
                    '. + [{type: "renamed", old_path: $old, new_path: $new}]')
            fi
        done < <(echo "$RENAMED_FILES" | jq -r '.[].old' 2>/dev/null)
    fi

    # Check deleted files against criteria
    if [[ "$DELETED_FILES" != "[]" ]]; then
        while IFS= read -r del_path; do
            [[ -n "$del_path" ]] || continue
            if echo "$ALL_CRITERIA_FILES" | grep -qF "$del_path" 2>/dev/null; then
                AFFECTED_CRITERIA=$(echo "$AFFECTED_CRITERIA" | jq \
                    --arg path "$del_path" \
                    '. + [{type: "deleted", path: $path}]')
            fi
        done < <(echo "$DELETED_FILES" | jq -r '.[]' 2>/dev/null)
    fi
fi

# --------------------------------------------------
# Output JSON artifact
# --------------------------------------------------
jq -n \
    --arg repo "$REPO_PATH" \
    --arg repo_name "$REPO_NAME" \
    --arg gathered_at "$(now_iso)" \
    --arg last_cron_commit "${LAST_CRON_COMMIT:-none}" \
    --arg current_commit "$CURRENT_COMMIT_SHORT" \
    --arg commit_range "$COMMIT_RANGE" \
    --argjson no_changes "$NO_CHANGES" \
    --argjson no_tools "$NO_TOOLS" \
    --arg diff_stat "$DIFF_STAT" \
    --argjson renamed_files "$RENAMED_FILES" \
    --argjson deleted_files "$DELETED_FILES" \
    --argjson new_files "$NEW_FILES" \
    --argjson tools "$TOOLS_JSON" \
    --argjson affected_criteria "$AFFECTED_CRITERIA" \
    --argjson patterns_flagged "$PATTERNS_FLAGGED" \
    --arg validation_log_tail "$VALIDATION_LOG_TAIL" \
    '{
        repo: $repo,
        repo_name: $repo_name,
        gathered_at: $gathered_at,
        last_cron_commit: $last_cron_commit,
        current_commit: $current_commit,
        commit_range: $commit_range,
        no_changes: $no_changes,
        no_tools: $no_tools,
        diff_stat: $diff_stat,
        renamed_files: $renamed_files,
        deleted_files: $deleted_files,
        new_files: $new_files,
        tools: $tools,
        affected_criteria: $affected_criteria,
        patterns_flagged: $patterns_flagged,
        validation_log_tail: $validation_log_tail
    }'
