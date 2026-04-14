#!/usr/bin/env bash
# summon.sh — Claude Code PreToolUse hook for context injection
#
# Reads the file path from the Edit tool input, looks up the summon index,
# and outputs relevant tool constraints. Zero output for unmatched files.

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAFRA_DIR="${CLAFRA_ROOT}/.clafra"
INDEX_FILE="${CLAFRA_DIR}/summon-index.json"
TOOLS_DIR="${CLAFRA_ROOT}/tools"
SKILLS_DIR="${CLAFRA_ROOT}/skills"

[[ -f "$INDEX_FILE" ]] || exit 0

# Read tool input from stdin
INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -n "$FILE_PATH" ]] || exit 0

# Make path relative to project root
REL_PATH="${FILE_PATH#$CLAFRA_ROOT/}"

# Look up in index
MATCHED_TOOLS=$(jq -r --arg path "$REL_PATH" '.index[$path][]? // empty' "$INDEX_FILE" 2>/dev/null | sort -u)
[[ -n "$MATCHED_TOOLS" ]] || exit 0

# Output constraints
echo "⚡ clafra constraints for ${REL_PATH}:"
for tool_name in $MATCHED_TOOLS; do
    # Check both tools/ and skills/
    tool_file=""
    [[ -f "${TOOLS_DIR}/${tool_name}.json" ]] && tool_file="${TOOLS_DIR}/${tool_name}.json"
    [[ -f "${SKILLS_DIR}/${tool_name}.json" ]] && tool_file="${SKILLS_DIR}/${tool_name}.json"
    [[ -n "$tool_file" ]] || continue

    intent=$(jq -r '.intent' "$tool_file")
    criteria=$(jq -r '.success_criteria[]?' "$tool_file" 2>/dev/null)

    echo "  → ${tool_name}: ${intent}"
    if [[ -n "$criteria" ]]; then
        while IFS= read -r c; do
            echo "    check: ${c}"
        done <<< "$criteria"
    fi
done
