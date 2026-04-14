#!/usr/bin/env bash
# create-tool.sh — Guided tool/skill creation with all governance checks
#
# Usage: create-tool.sh [--type tool|skill] [--dry-run] [--skip-threshold]
#
# Interactive: prompts for name, intent, stack_dependencies, success_criteria.
# Enforces: pattern threshold (≥3), similarity check, mandatory fields.

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAFRA_DIR="${CLAFRA_ROOT}/.clafra"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TYPE="tool"
DRY_RUN=false
SKIP_THRESHOLD=false

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)      TYPE="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --skip-threshold) SKIP_THRESHOLD=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ "$TYPE" == "tool" || "$TYPE" == "skill" ]] || { echo "Type must be 'tool' or 'skill'"; exit 1; }
TARGET_DIR="${CLAFRA_ROOT}/${TYPE}s"

echo "clafra create-${TYPE}"
echo "====================="
echo ""

# --------------------------------------------------
# 1. Gather input
# --------------------------------------------------
read -rp "Name: " NAME
[[ -n "$NAME" ]] || { echo -e "${RED}Name is required${NC}"; exit 1; }

# Sanitize filename
FILENAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')
FILEPATH="${TARGET_DIR}/${FILENAME}.json"

if [[ -f "$FILEPATH" ]]; then
    echo -e "${RED}File already exists:${NC} ${FILEPATH}"
    exit 1
fi

read -rp "Intent (canonical description): " INTENT
[[ -n "$INTENT" ]] || { echo -e "${RED}Intent is required${NC}"; exit 1; }

echo "Stack dependencies (one per line, empty line to finish):"
STACK_DEPS=()
while IFS= read -rp "  dep> " dep; do
    [[ -n "$dep" ]] || break
    STACK_DEPS+=("$dep")
done

echo "Success criteria (shell commands that should exit 0, one per line, empty to finish):"
SUCCESS_CRITERIA=()
while IFS= read -rp "  criterion> " crit; do
    [[ -n "$crit" ]] || break
    SUCCESS_CRITERIA+=("$crit")
done

if [[ ${#SUCCESS_CRITERIA[@]} -eq 0 ]]; then
    echo -e "${RED}At least one success criterion is required.${NC}"
    echo "A tool without success criteria defaults to stale immediately."
    exit 1
fi

read -rp "Staleness threshold in days [30]: " STALENESS_DAYS
STALENESS_DAYS="${STALENESS_DAYS:-30}"

read -rp "Validation trigger (on_change|on_dependency_change) [on_change]: " VALIDATION_TRIGGER
VALIDATION_TRIGGER="${VALIDATION_TRIGGER:-on_change}"

echo ""

# --------------------------------------------------
# 2. Check pattern threshold
# --------------------------------------------------
if [[ "$SKIP_THRESHOLD" == "false" ]]; then
    echo -e "${CYAN}Checking pattern threshold...${NC}"
    PATTERNS_FILE="${CLAFRA_ROOT}/patterns.json"
    if [[ -f "$PATTERNS_FILE" ]]; then
        # Look for patterns matching this intent
        match_count=$(jq --arg intent "$INTENT" '
            [.patterns[] | select(.description | ascii_downcase | contains($intent | ascii_downcase))] | length
        ' "$PATTERNS_FILE" 2>/dev/null || echo "0")

        if [[ "$match_count" -eq 0 ]]; then
            echo -e "${YELLOW}Warning:${NC} No matching pattern found in patterns.json"
            echo "  Rule: pattern must appear in at least 3 sessions before promotion."
            read -rp "  Continue anyway? (y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
        else
            # Check if any matching pattern has frequency >= 3
            threshold_met=$(jq --arg intent "$INTENT" '
                [.patterns[] | select(
                    (.description | ascii_downcase | contains($intent | ascii_downcase)) and
                    .frequency >= 3
                )] | length
            ' "$PATTERNS_FILE" 2>/dev/null || echo "0")

            if [[ "$threshold_met" -eq 0 ]]; then
                echo -e "${YELLOW}Warning:${NC} Pattern found but frequency < 3"
                read -rp "  Continue anyway? (y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
            else
                echo -e "${GREEN}✓${NC} Pattern threshold met"
            fi
        fi
    else
        echo -e "${YELLOW}Warning:${NC} patterns.json not found — skipping threshold check"
    fi
    echo ""
fi

# --------------------------------------------------
# 3. Similarity check (Tier 1 - local)
# --------------------------------------------------
echo -e "${CYAN}Running similarity check...${NC}"
similarity_result=0
"${CLAFRA_DIR}/check-similarity-local.sh" "$INTENT" || similarity_result=$?

case $similarity_result in
    0) echo -e "${GREEN}✓${NC} No overlap" ;;
    1) echo -e "${RED}Blocked:${NC} Significant overlap with existing ${TYPE}. Extend it instead."
       exit 1 ;;
    2) echo -e "${YELLOW}Ambiguous overlap detected.${NC}"
       read -rp "  Create anyway? (y/N): " confirm
       [[ "$confirm" =~ ^[Yy]$ ]] || exit 0 ;;
    *) echo -e "${YELLOW}Warning:${NC} Similarity check error — proceeding" ;;
esac
echo ""

# --------------------------------------------------
# 4. Build JSON
# --------------------------------------------------
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build arrays
DEPS_JSON=$(printf '%s\n' "${STACK_DEPS[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')
CRITERIA_JSON=$(printf '%s\n' "${SUCCESS_CRITERIA[@]}" | jq -R . | jq -s .)

TOOL_JSON=$(jq -n \
    --arg name "$NAME" \
    --arg intent "$INTENT" \
    --argjson stack_deps "$DEPS_JSON" \
    --argjson success_criteria "$CRITERIA_JSON" \
    --arg created_at "$NOW" \
    --arg last_validated "$NOW" \
    --arg trigger "$VALIDATION_TRIGGER" \
    --argjson staleness "$STALENESS_DAYS" \
    '{
        name: $name,
        intent: $intent,
        stack_dependencies: $stack_deps,
        success_criteria: $success_criteria,
        created_at: $created_at,
        last_validated: $last_validated,
        validation_trigger: $trigger,
        status: "active",
        staleness_days: $staleness
    }')

# --------------------------------------------------
# 5. Write or dry-run
# --------------------------------------------------
echo "Generated ${TYPE}:"
echo "$TOOL_JSON" | jq .
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}Dry run — no files written.${NC}"
    exit 0
fi

# Write tool file
echo "$TOOL_JSON" > "$FILEPATH"
echo -e "${GREEN}✓${NC} Created ${FILEPATH}"

# --------------------------------------------------
# 6. Update project registry
# --------------------------------------------------
REGISTRY="${CLAFRA_ROOT}/.clafra/registry.json"
if [[ ! -f "$REGISTRY" ]]; then
    echo '{"tools": [], "skills": []}' > "$REGISTRY"
fi

(
    flock -w 5 200 || { echo "Failed to acquire lock on registry" >&2; exit 1; }
    UPDATED_REG=$(jq --arg name "$NAME" --arg file "$FILEPATH" --arg type "${TYPE}s" \
        '.[$type] += [{"name": $name, "file": $file}] | .[$type] |= unique_by(.name)' \
        "$REGISTRY")
    echo "$UPDATED_REG" > "$REGISTRY"
) 200>"${REGISTRY}.lock"
rm -f "${REGISTRY}.lock"
echo -e "${GREEN}✓${NC} Project registry updated"

# --------------------------------------------------
# 7. Queue Tier 2 async review
# --------------------------------------------------
REVIEWS_DIR="${CLAFRA_DIR}/pending-reviews"
mkdir -p "$REVIEWS_DIR"
review_file="${REVIEWS_DIR}/${FILENAME}.json"
jq -n \
    --arg name "$NAME" \
    --arg intent "$INTENT" \
    --arg file "$FILEPATH" \
    --arg queued_at "$NOW" \
    '{name: $name, intent: $intent, file: $file, queued_at: $queued_at}' > "$review_file"
echo -e "${GREEN}✓${NC} Tier 2 async review queued"

echo ""
echo -e "${GREEN}Done.${NC} Run '.clafra/validate.sh --full' to verify."
