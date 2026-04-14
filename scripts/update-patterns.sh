#!/usr/bin/env bash
# update-patterns.sh — Update patterns.json from reduced session log
#
# Usage: reduce-log.sh | update-patterns.sh
#        Reads reduced JSON from stdin.
#        Acquires flock, backs up, and updates patterns.json.

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
PATTERNS_FILE="${CLAFRA_ROOT}/patterns.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Read reduced data from stdin
REDUCED=$(cat)
[[ -n "$REDUCED" ]] || { echo "No input data" >&2; exit 0; }

# Validate input is JSON
if ! echo "$REDUCED" | jq empty 2>/dev/null; then
    echo -e "${RED}Invalid JSON input${NC}" >&2
    exit 1
fi

# Ensure patterns.json exists
if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo '{"version": 1, "patterns": [], "last_reduced": null}' > "$PATTERNS_FILE"
fi

SESSION_ID=$(echo "$REDUCED" | jq -r '.session_id // "unknown"')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
THRESHOLD=3

# --------------------------------------------------
# Acquire lock and update
# --------------------------------------------------
(
    flock -w 10 200 || { echo "Failed to acquire lock on patterns.json" >&2; exit 1; }

    # Backup
    cp "$PATTERNS_FILE" "${PATTERNS_FILE}.bak"

    # Extract pattern descriptions from reduced data
    # Combine tool usage patterns and content patterns into descriptions
    DESCRIPTIONS=$(echo "$REDUCED" | jq -r '
        (
            [.tool_usage[]? | select(.count >= 2) | "Frequent use of tool: \(.tool) (\(.count)x)"] +
            [.error_patterns[]? | select(.count >= 2) | "Recurring error: \(.error[:80])"] +
            [.content_patterns[]? | select(.count >= 3) | "Repeated pattern: \(.pattern[:80])"]
        ) | .[]
    ' 2>/dev/null || true)

    if [[ -z "$DESCRIPTIONS" ]]; then
        # Update last_reduced timestamp even if no patterns found
        UPDATED=$(jq --arg now "$NOW" '.last_reduced = $now' "$PATTERNS_FILE")
        echo "$UPDATED" > "$PATTERNS_FILE"
        echo "No significant patterns in this session" >&2
        exit 0
    fi

    # Process each description
    CURRENT=$(cat "$PATTERNS_FILE")

    while IFS= read -r desc; do
        [[ -n "$desc" ]] || continue

        # Generate a stable ID from the description
        PATTERN_ID="pattern-$(echo "$desc" | sha256sum | head -c 12)"

        # Check if pattern already exists
        EXISTS=$(echo "$CURRENT" | jq --arg id "$PATTERN_ID" '.patterns | map(select(.id == $id)) | length')

        if [[ "$EXISTS" -gt 0 ]]; then
            # Increment frequency, update last_seen, add session
            CURRENT=$(echo "$CURRENT" | jq \
                --arg id "$PATTERN_ID" \
                --arg now "$NOW" \
                --arg sid "$SESSION_ID" \
                '
                .patterns = [.patterns[] |
                    if .id == $id then
                        .frequency += 1 |
                        .last_seen = $now |
                        .sessions += [$sid] |
                        if .frequency >= 3 and .status == "observed" then .status = "flagged" else . end
                    else . end
                ]
                ')
        else
            # Add new pattern
            CURRENT=$(echo "$CURRENT" | jq \
                --arg id "$PATTERN_ID" \
                --arg desc "$desc" \
                --arg now "$NOW" \
                --arg sid "$SESSION_ID" \
                '
                .patterns += [{
                    id: $id,
                    description: $desc,
                    frequency: 1,
                    first_seen: $now,
                    last_seen: $now,
                    sessions: [$sid],
                    status: "observed"
                }]
                ')
        fi
    done <<< "$DESCRIPTIONS"

    # Update last_reduced
    CURRENT=$(echo "$CURRENT" | jq --arg now "$NOW" '.last_reduced = $now')

    # Write
    echo "$CURRENT" > "$PATTERNS_FILE"

    # Report flagged patterns
    FLAGGED=$(echo "$CURRENT" | jq '[.patterns[] | select(.status == "flagged")] | length')
    TOTAL=$(echo "$CURRENT" | jq '.patterns | length')

    echo -e "${GREEN}Patterns updated:${NC} ${TOTAL} total, ${FLAGGED} flagged (threshold: ${THRESHOLD})" >&2

    if [[ "$FLAGGED" -gt 0 ]]; then
        echo -e "${YELLOW}Flagged patterns ready for tool creation review:${NC}" >&2
        echo "$CURRENT" | jq -r '.patterns[] | select(.status == "flagged") | "  → \(.description) (seen \(.frequency)x)"' >&2
    fi

) 200>"${PATTERNS_FILE}.lock"

# Clean up lock file
rm -f "${PATTERNS_FILE}.lock"
