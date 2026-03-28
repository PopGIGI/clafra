#!/usr/bin/env bash
# deprecate.sh — Move a tool/skill to deprecated/ with audit trail
#
# Usage: deprecate.sh <tool-or-skill-path> --reason "reason text" [--dry-run]
#
# Example: deprecate.sh tools/my-tool.json --reason "Superseded by new-tool"

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

FILE=""
REASON=""
DRY_RUN=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason)   REASON="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        *)          FILE="$1"; shift ;;
    esac
done

# Resolve path
if [[ -n "$FILE" && ! -f "$FILE" ]]; then
    # Try relative to CLAFRA_ROOT
    if [[ -f "${CLAFRA_ROOT}/${FILE}" ]]; then
        FILE="${CLAFRA_ROOT}/${FILE}"
    else
        echo -e "${RED}File not found:${NC} ${FILE}"
        exit 1
    fi
fi

[[ -n "$FILE" ]] || { echo "Usage: deprecate.sh <path> --reason \"text\" [--dry-run]"; exit 1; }
[[ -n "$REASON" ]] || { echo -e "${RED}--reason is required${NC}"; exit 1; }

BASENAME=$(basename "$FILE")
SOURCE_DIR=$(basename "$(dirname "$FILE")")
DEST="${CLAFRA_ROOT}/deprecated/${BASENAME}"

echo "clafra deprecate"
echo "================"
echo "  Source: ${SOURCE_DIR}/${BASENAME}"
echo "  Reason: ${REASON}"
echo ""

# Validate it's a tool or skill
if [[ "$SOURCE_DIR" != "tools" && "$SOURCE_DIR" != "skills" ]]; then
    echo -e "${RED}Can only deprecate files from tools/ or skills/${NC}"
    exit 1
fi

# Read current content
if ! jq empty "$FILE" 2>/dev/null; then
    echo -e "${RED}Invalid JSON:${NC} ${FILE}"
    exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NAME=$(jq -r '.name' "$FILE")

# Add deprecation fields
UPDATED=$(jq \
    --arg reason "$REASON" \
    --arg deprecated_at "$NOW" \
    '. + {status: "deprecated", deprecated_at: $deprecated_at, deprecation_reason: $reason}' \
    "$FILE")

echo "Updated JSON:"
echo "$UPDATED" | jq .
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}Dry run — no files moved.${NC}"
    exit 0
fi

# Handle name collision in deprecated/
if [[ -f "$DEST" ]]; then
    DEST="${CLAFRA_ROOT}/deprecated/${BASENAME%.json}-$(date +%s).json"
fi

# Backup source
cp "$FILE" "${FILE}.bak"

# Write updated file to deprecated/
echo "$UPDATED" > "$DEST"
echo -e "${GREEN}✓${NC} Written to deprecated/${BASENAME}"

# Remove from source
rm "$FILE"
rm -f "${FILE}.bak"
echo -e "${GREEN}✓${NC} Removed from ${SOURCE_DIR}/"

# Update project registry
REGISTRY="${CLAFRA_ROOT}/.clafra/registry.json"
if [[ -f "$REGISTRY" ]]; then
    (
        flock -w 5 200 || { echo "Failed to acquire lock on registry" >&2; exit 1; }
        UPDATED_REG=$(jq --arg name "$NAME" \
            '.tools = [.tools[]? | select(.name != $name)] | .skills = [.skills[]? | select(.name != $name)]' \
            "$REGISTRY")
        echo "$UPDATED_REG" > "$REGISTRY"
    ) 200>"${REGISTRY}.lock"
    rm -f "${REGISTRY}.lock"
    echo -e "${GREEN}✓${NC} Project registry updated"
fi

echo ""
echo -e "${GREEN}Deprecated '${NAME}'.${NC} Audit trail in deprecated/${BASENAME}"
