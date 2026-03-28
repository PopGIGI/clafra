#!/usr/bin/env bash
# parse-log.sh — Abstraction layer for Claude Code JSONL session logs
#
# Usage: parse-log.sh [session-log-path]
#        If no path given, finds the most recent session log.
#
# Detects format version, normalizes output.
# Exit codes: 0=success, 1=format error, 2=no log found

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --------------------------------------------------
# Locate session log
# --------------------------------------------------
find_latest_log() {
    local claude_dir="${HOME}/.claude"
    local projects_dir="${claude_dir}/projects"

    if [[ ! -d "$projects_dir" ]]; then
        echo -e "${RED}Claude Code projects directory not found:${NC} ${projects_dir}" >&2
        return 2
    fi

    # Find the most recently modified JSONL file across all projects
    local latest
    latest=$(find "$projects_dir" -name "*.jsonl" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | head -1 \
        | cut -d' ' -f2-)

    if [[ -z "$latest" ]]; then
        echo "No JSONL session logs found" >&2
        return 2
    fi

    echo "$latest"
}

LOG_PATH="${1:-}"
if [[ -z "$LOG_PATH" ]]; then
    LOG_PATH=$(find_latest_log) || exit $?
fi

if [[ ! -f "$LOG_PATH" ]]; then
    echo -e "${RED}Log file not found:${NC} ${LOG_PATH}" >&2
    exit 2
fi

# --------------------------------------------------
# Detect format version
# --------------------------------------------------
# Read first valid JSON line and check for expected fields
FIRST_LINE=$(head -1 "$LOG_PATH" 2>/dev/null)

if [[ -z "$FIRST_LINE" ]]; then
    echo "Empty log file: ${LOG_PATH}" >&2
    exit 1
fi

if ! echo "$FIRST_LINE" | jq empty 2>/dev/null; then
    echo -e "${RED}First line is not valid JSON — format may have changed${NC}" >&2
    echo "File: ${LOG_PATH}" >&2
    exit 1
fi

# Check for known fields to identify format
HAS_TYPE=$(echo "$FIRST_LINE" | jq 'has("type")' 2>/dev/null)
HAS_ROLE=$(echo "$FIRST_LINE" | jq 'has("role")' 2>/dev/null)
HAS_MESSAGE=$(echo "$FIRST_LINE" | jq 'has("message")' 2>/dev/null)

FORMAT="unknown"
if [[ "$HAS_TYPE" == "true" ]]; then
    FORMAT="v1_typed"
elif [[ "$HAS_ROLE" == "true" && "$HAS_MESSAGE" == "true" ]]; then
    FORMAT="v1_conversation"
elif [[ "$HAS_ROLE" == "true" ]]; then
    FORMAT="v1_role"
fi

if [[ "$FORMAT" == "unknown" ]]; then
    echo -e "${YELLOW}Warning: Unrecognized log format${NC}" >&2
    echo "Expected fields: 'type', 'role', or 'message'" >&2
    echo "First line keys: $(echo "$FIRST_LINE" | jq -r 'keys | join(", ")')" >&2
    echo "File: ${LOG_PATH}" >&2
    # Still try to output — may partially work
fi

# --------------------------------------------------
# Normalize and output
# --------------------------------------------------
# Output normalized JSONL with consistent schema:
#   { "type": "...", "content": "...", "timestamp": "...", "tool": "...", "error": bool }

case "$FORMAT" in
    v1_typed)
        jq -c '{
            type: .type,
            content: (.content // .text // .message // ""),
            timestamp: (.timestamp // .ts // ""),
            tool: (.tool_name // .tool // null),
            error: (if .type == "error" or .error == true then true else false end)
        }' "$LOG_PATH" 2>/dev/null
        ;;
    v1_conversation|v1_role)
        jq -c '{
            type: (.type // .role // "unknown"),
            content: (.message // .content // .text // ""),
            timestamp: (.timestamp // .ts // .created_at // ""),
            tool: (.tool_use.name // .tool_name // null),
            error: (if .role == "error" or .error == true then true else false end)
        }' "$LOG_PATH" 2>/dev/null
        ;;
    *)
        # Best-effort passthrough with normalization attempt
        jq -c '{
            type: (.type // .role // .kind // "unknown"),
            content: (.content // .message // .text // .body // "" | tostring),
            timestamp: (.timestamp // .ts // .created_at // .time // ""),
            tool: (.tool_name // .tool // .tool_use.name // null),
            error: (if .error == true or .type == "error" then true else false end)
        }' "$LOG_PATH" 2>/dev/null
        ;;
esac

echo '{"_meta": {"format": "'"$FORMAT"'", "source": "'"$LOG_PATH"'"}}' >&2
