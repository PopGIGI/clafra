#!/usr/bin/env bash
# reduce-log.sh — Reduce session log to decisions and gaps
#
# Usage: reduce-log.sh [session-log-path]
#        Reads normalized output from parse-log.sh
#        Outputs reduced JSON summary of patterns found
#
# Extracts: tool calls, errors, repeated operations, decision points

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAFRA_DIR="${CLAFRA_ROOT}/.clafra"
PARSE_LOG="${CLAFRA_DIR}/parse-log.sh"

LOG_PATH="${1:-}"

# --------------------------------------------------
# Parse the log
# --------------------------------------------------
if [[ -n "$LOG_PATH" ]]; then
    PARSED=$("$PARSE_LOG" "$LOG_PATH" 2>/dev/null) || exit $?
else
    PARSED=$("$PARSE_LOG" 2>/dev/null) || exit $?
fi

[[ -n "$PARSED" ]] || { echo "No log data to reduce" >&2; exit 0; }

# --------------------------------------------------
# Extract patterns
# --------------------------------------------------
# 1. Tool usage frequency — which tools were called and how often
TOOL_FREQ=$(echo "$PARSED" | jq -s '
    [.[] | select(.tool != null) | .tool] |
    group_by(.) |
    map({tool: .[0], count: length}) |
    sort_by(-.count)
')

# 2. Error patterns — recurring errors
ERROR_PATTERNS=$(echo "$PARSED" | jq -s '
    [.[] | select(.error == true) | .content] |
    group_by(.) |
    map({error: .[0], count: length}) |
    sort_by(-.count) |
    .[:10]
')

# 3. Repeated content patterns — content that appears multiple times
CONTENT_PATTERNS=$(echo "$PARSED" | jq -s '
    [.[] | select(.content != "" and .content != null) | (.content | tostring)[:100]] |
    group_by(.) |
    map(select(length > 1) | {pattern: .[0], count: length}) |
    sort_by(-.count) |
    .[:20]
')

# --------------------------------------------------
# Build reduced summary
# --------------------------------------------------
SESSION_ID=$(date +%s | sha256sum | head -c 12)
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
    --arg session_id "$SESSION_ID" \
    --arg reduced_at "$NOW" \
    --argjson tool_freq "$TOOL_FREQ" \
    --argjson errors "$ERROR_PATTERNS" \
    --argjson content "$CONTENT_PATTERNS" \
    '{
        session_id: $session_id,
        reduced_at: $reduced_at,
        tool_usage: $tool_freq,
        error_patterns: $errors,
        content_patterns: $content,
        decisions: [],
        gaps: []
    }'
