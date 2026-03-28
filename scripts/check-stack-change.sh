#!/usr/bin/env bash
# check-stack-change.sh — Stack change protocol
#
# Called when stack dependency files change (package.json, etc.).
# Diffs declared stack_dependencies against the change.
# Flags affected tools as stale — surfaces at next session start.

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Known stack files
STACK_FILES=("package.json" "package-lock.json" "requirements.txt" "Cargo.toml" "go.mod" "Gemfile" "pyproject.toml")

# Determine which stack files changed
CHANGED_STACK=()
for sf in "${STACK_FILES[@]}"; do
    if git -C "$CLAFRA_ROOT" diff --cached --name-only -- "$sf" 2>/dev/null | grep -q .; then
        CHANGED_STACK+=("$sf")
    fi
done

if [[ ${#CHANGED_STACK[@]} -eq 0 ]]; then
    echo -e "${GREEN}No stack dependency files changed${NC}"
    exit 0
fi

echo "Stack files changed: ${CHANGED_STACK[*]}"
echo ""

# Find tools/skills that declare dependencies on changed files
AFFECTED=0
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for dir in tools skills; do
    for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
        [[ -f "$f" ]] || continue

        status=$(jq -r '.status' "$f" 2>/dev/null)
        [[ "$status" == "active" ]] || continue

        name=$(jq -r '.name' "$f" 2>/dev/null)
        deps=$(jq -r '.stack_dependencies[]?' "$f" 2>/dev/null)

        # Check if any declared dependency matches a changed stack file
        matched=false
        for dep in $deps; do
            for changed in "${CHANGED_STACK[@]}"; do
                if [[ "$dep" == "$changed" || "$dep" == *"/$changed" ]]; then
                    matched=true
                    break 2
                fi
            done
        done

        # Also flag tools with empty stack_dependencies (undeclared = full revalidation)
        dep_count=$(jq '.stack_dependencies | length' "$f" 2>/dev/null)
        if [[ "$dep_count" -eq 0 ]]; then
            matched=true
        fi

        if [[ "$matched" == "true" ]]; then
            echo -e "  ${YELLOW}!${NC} ${name} — flagged as stale (dependency changed)"

            # Update status (with backup)
            cp "$f" "${f}.bak"
            updated=$(jq '.status = "stale"' "$f")
            (
                flock -w 5 200 || exit 1
                echo "$updated" > "$f"
            ) 200>"${f}.lock"
            rm -f "${f}.lock"

            AFFECTED=$((AFFECTED + 1))
        fi
    done
done

echo ""
if [[ $AFFECTED -gt 0 ]]; then
    echo -e "${YELLOW}${AFFECTED} tool(s) flagged as stale${NC} — revalidate with: .clafra/validate.sh --full"
else
    echo -e "${GREEN}No tools affected by stack change${NC}"
fi
