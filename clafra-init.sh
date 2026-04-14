#!/usr/bin/env bash
# clafra-init.sh — Bootstrap the skill-governance system
#
# Two-phase install:
#   Phase 1: User-level — installs master CLAUDE.md to ~/.claude/CLAUDE.md
#   Phase 2: Per-project — sets up tools/, skills/, hooks, scripts in a git repo
#
# Usage: clafra-init.sh [--user-only | --project-only <dir> | <dir>]
#   No args:          Both phases (user-level + current directory as project)
#   --user-only:      Only install user-level CLAUDE.md
#   --project-only:   Only install per-project files
#   <dir>:            Both phases, targeting <dir> for project

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CLAFRA_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USER_ONLY=false
PROJECT_ONLY=false
TARGET=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-only)    USER_ONLY=true; shift ;;
        --project-only) PROJECT_ONLY=true; TARGET="${2:-.}"; shift 2 ;;
        *)              TARGET="$1"; shift ;;
    esac
done

TARGET="${TARGET:-.}"
TARGET="$(cd "$TARGET" && pwd)"

echo "clafra init"
echo "==========="
echo "Source: ${CLAFRA_SRC}"
echo ""

# ==========================================================
# Phase 1: User-level — ~/.claude/CLAUDE.md
# ==========================================================
install_user_level() {
    echo -e "${CYAN}Phase 1: User-level governance${NC}"
    echo ""

    local claude_dir="${HOME}/.claude"
    local claude_md="${claude_dir}/CLAUDE.md"

    # Create ~/.claude if needed
    mkdir -p "$claude_dir"

    if [[ -f "$claude_md" ]]; then
        # Check if clafra section already exists
        if grep -q "SKILL-GOVERNANCE — Master Context" "$claude_md" 2>/dev/null; then
            echo -e "  ${YELLOW}!${NC} ~/.claude/CLAUDE.md already has clafra governance — updating"
            # Replace the clafra content (everything in the file since clafra is master)
            cp "$claude_md" "${claude_md}.bak"
            echo -e "  ${GREEN}✓${NC} Backup saved to ~/.claude/CLAUDE.md.bak"
        else
            # Existing non-clafra CLAUDE.md — prepend governance, preserve existing content
            cp "$claude_md" "${claude_md}.bak"
            echo -e "  ${YELLOW}!${NC} Existing ~/.claude/CLAUDE.md found — prepending governance"
            echo -e "  ${GREEN}✓${NC} Backup saved to ~/.claude/CLAUDE.md.bak"

            # Merge: clafra master + existing content under "Project Defaults" section
            {
                cat "${CLAFRA_SRC}/templates/CLAUDE.md"
                echo ""
                echo "---"
                echo ""
                echo "## Previous User Configuration"
                echo ""
                cat "${claude_md}.bak"
            } > "$claude_md"

            echo -e "  ${GREEN}✓${NC} ~/.claude/CLAUDE.md updated (governance prepended, previous content preserved)"
            echo ""
            return
        fi
    fi

    cp "${CLAFRA_SRC}/templates/CLAUDE.md" "$claude_md"
    echo -e "  ${GREEN}✓${NC} ~/.claude/CLAUDE.md installed"
    echo ""
}

# ==========================================================
# Phase 2: Per-project setup
# ==========================================================
install_project() {
    echo -e "${CYAN}Phase 2: Per-project setup (${TARGET})${NC}"
    echo ""

    # Verify target is a git repo
    if ! git -C "$TARGET" rev-parse --git-dir &>/dev/null; then
        echo -e "${RED}Error:${NC} ${TARGET} is not a git repository."
        echo "Initialize with: git init ${TARGET}"
        exit 1
    fi

    # Create directory structure
    echo "Creating directories..."
    for dir in tools skills deprecated .clafra .clafra/pending-reviews .clafra/cron-results; do
        mkdir -p "${TARGET}/${dir}"
        echo -e "  ${GREEN}✓${NC} ${dir}/"
    done

    # Add .gitkeep to empty dirs
    for dir in tools skills deprecated .clafra/pending-reviews .clafra/cron-results; do
        if [[ -z "$(ls -A "${TARGET}/${dir}" 2>/dev/null)" ]]; then
            touch "${TARGET}/${dir}/.gitkeep"
        fi
    done
    echo ""

    # Copy SKILL-GOVERNANCE.md and patterns.json (not CLAUDE.md — that's user-level now)
    echo "Installing templates..."
    for template in SKILL-GOVERNANCE.md patterns.json; do
        dest="${TARGET}/${template}"
        if [[ -f "$dest" ]]; then
            echo -e "  ${YELLOW}!${NC} ${template} already exists — skipping"
        else
            cp "${CLAFRA_SRC}/templates/${template}" "$dest"
            echo -e "  ${GREEN}✓${NC} ${template}"
        fi
    done
    echo ""

    # Copy scripts to .clafra/
    echo "Installing scripts..."
    for script in "${CLAFRA_SRC}/scripts/"*.sh; do
        [[ -f "$script" ]] || continue
        basename_s=$(basename "$script")
        cp "$script" "${TARGET}/.clafra/${basename_s}"
        chmod +x "${TARGET}/.clafra/${basename_s}"
        echo -e "  ${GREEN}✓${NC} .clafra/${basename_s}"
    done
    echo ""

    # Install git hooks
    echo "Installing hooks..."
    hooks_dir="${TARGET}/.hooks"
    mkdir -p "$hooks_dir"

    for hook in "${CLAFRA_SRC}/hooks/"*; do
        [[ -f "$hook" ]] || continue
        basename_h=$(basename "$hook")
        cp "$hook" "${hooks_dir}/${basename_h}"
        chmod +x "${hooks_dir}/${basename_h}"
        echo -e "  ${GREEN}✓${NC} .hooks/${basename_h}"
    done

    git -C "$TARGET" config core.hooksPath .hooks
    echo -e "  ${GREEN}✓${NC} core.hooksPath set to .hooks"
    echo ""

    # Build summon index
    echo "Building summon index..."
    CLAFRA_ROOT="$TARGET" "${TARGET}/.clafra/build-summon-index.sh" || true
    echo ""

    # Install Claude Code hook for summoning
    echo "Installing Claude Code hook..."
    local claude_settings="${TARGET}/.claude/settings.json"
    mkdir -p "${TARGET}/.claude"
    if [[ -f "$claude_settings" ]]; then
        # Merge hook into existing settings if not already present
        if ! jq -e '.hooks.PreToolUse' "$claude_settings" &>/dev/null; then
            local merged
            merged=$(jq '.hooks.PreToolUse = [{"matcher": "Edit", "hooks": [{"type": "command", "command": ".clafra/summon.sh"}]}]' "$claude_settings")
            echo "$merged" | jq . > "$claude_settings"
            echo -e "  ${GREEN}✓${NC} Summon hook added to existing .claude/settings.json"
        else
            echo -e "  ${YELLOW}!${NC} PreToolUse hook already configured — skipping"
        fi
    else
        cat > "$claude_settings" <<'SETTINGS'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": ".clafra/summon.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
        echo -e "  ${GREEN}✓${NC} .claude/settings.json created with summon hook"
    fi
    echo ""

    # Run doctor
    echo "Running health check..."
    echo ""
    CLAFRA_ROOT="$TARGET" "${TARGET}/.clafra/clafra-doctor.sh" || true
    echo ""
}

# ==========================================================
# Execute
# ==========================================================
if [[ "$PROJECT_ONLY" == "true" ]]; then
    install_project
elif [[ "$USER_ONLY" == "true" ]]; then
    install_user_level
else
    install_user_level
    install_project
fi

echo -e "${GREEN}clafra initialized successfully${NC}"
echo ""
echo "Next steps:"
if [[ "$USER_ONLY" != "true" ]]; then
    echo "  1. Review SKILL-GOVERNANCE.md in your project"
    echo "  2. Commit the initial clafra files"
    echo "  3. Set CLAFRA_SSH_HOST if you want async similarity reviews"
else
    echo "  1. Run 'clafra-init.sh <project-dir>' to set up a project"
    echo "  2. Or run 'clafra-init.sh --project-only <dir>' for project-only setup"
fi
