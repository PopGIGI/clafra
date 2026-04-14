#!/usr/bin/env bash
# check-similarity-remote.sh — Tier 2 async similarity review via SSH/Claude
#
# Processes pending reviews in .clafra/pending-reviews/.
# Sends intent bundles to CLAFRA_SSH_HOST for semantic comparison.
# Non-blocking — results surface at next session start.
#
# Requires: CLAFRA_SSH_HOST environment variable

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAFRA_DIR="${CLAFRA_ROOT}/.clafra"
REVIEWS_DIR="${CLAFRA_DIR}/pending-reviews"
RESULTS_DIR="${CLAFRA_DIR}/review-results"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Check SSH host
if [[ -z "${CLAFRA_SSH_HOST:-}" ]]; then
    echo -e "${YELLOW}CLAFRA_SSH_HOST not set — skipping async reviews${NC}"
    exit 0
fi

# Check connectivity
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${CLAFRA_SSH_HOST}" "echo ok" &>/dev/null; then
    echo -e "${YELLOW}Cannot reach ${CLAFRA_SSH_HOST} — reviews remain pending${NC}"
    exit 0
fi

mkdir -p "$RESULTS_DIR"

# Collect all existing intents
EXISTING_INTENTS=$(
    for dir in tools skills; do
        for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
            [[ -f "$f" ]] || continue
            jq -r 'select(.status == "active" or .status == "stale") | "\(.name): \(.intent)"' "$f" 2>/dev/null || true
        done
    done
)

# Process each pending review
PROCESSED=0
for review in "${REVIEWS_DIR}"/*.json; do
    [[ -f "$review" ]] || continue

    REVIEW_NAME=$(jq -r '.name' "$review")
    REVIEW_INTENT=$(jq -r '.intent' "$review")
    REVIEW_FILE=$(jq -r '.file' "$review")

    echo "Reviewing: ${REVIEW_NAME}"

    # Build prompt for Claude
    PROMPT="You are checking for semantic overlap between tool intents.

PROPOSED NEW TOOL:
Name: ${REVIEW_NAME}
Intent: ${REVIEW_INTENT}

EXISTING TOOLS:
${EXISTING_INTENTS}

Respond with EXACTLY one of:
- no_overlap — the proposed tool is distinct from all existing tools
- overlap:<tool_name> — the proposed tool significantly overlaps with the named existing tool
- ambiguous — the overlap is unclear, human should decide

Response:"

    # Send to remote Claude via SSH
    RESULT=$(echo "$PROMPT" | ssh -o ConnectTimeout=10 "${CLAFRA_SSH_HOST}" "cat" 2>/dev/null || echo "error")

    # Parse result
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ "$RESULT" == *"no_overlap"* ]]; then
        STATUS="no_overlap"
        echo -e "  ${GREEN}✓${NC} No overlap detected"
    elif [[ "$RESULT" == *"overlap:"* ]]; then
        STATUS="overlap"
        MATCH=$(echo "$RESULT" | grep -oP 'overlap:\K\S+' || echo "unknown")
        echo -e "  ${RED}!${NC} Overlap with: ${MATCH}"
    elif [[ "$RESULT" == *"ambiguous"* ]]; then
        STATUS="ambiguous"
        echo -e "  ${YELLOW}?${NC} Ambiguous — human review needed"
    else
        STATUS="error"
        echo -e "  ${YELLOW}!${NC} Could not parse response"
    fi

    # Save result
    jq -n \
        --arg name "$REVIEW_NAME" \
        --arg intent "$REVIEW_INTENT" \
        --arg status "$STATUS" \
        --arg response "$RESULT" \
        --arg reviewed_at "$NOW" \
        '{name: $name, intent: $intent, status: $status, response: $response, reviewed_at: $reviewed_at}' \
        > "${RESULTS_DIR}/$(basename "$review")"

    # Remove from pending
    rm "$review"
    PROCESSED=$((PROCESSED + 1))
done

if [[ $PROCESSED -eq 0 ]]; then
    echo "No pending reviews to process"
else
    echo ""
    echo -e "${GREEN}Processed ${PROCESSED} review(s)${NC}"
    echo "Results in: ${RESULTS_DIR}/"
fi
