#!/usr/bin/env bash
# clafra-doctor.sh — Prerequisite & health check for clafra governance system
# Exit codes: 0=ok, 1=missing dependency, 2=corrupt state

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
ERRORS=0
WARNINGS=0

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARNINGS=$((WARNINGS + 1)); }

echo "clafra doctor"
echo "============="
echo ""

# --------------------------------------------------
# 1. Check dependencies
# --------------------------------------------------
echo "Dependencies:"

# bash version >= 4
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    pass "bash ${BASH_VERSION}"
else
    fail "bash >= 4 required (found ${BASH_VERSION})"
fi

# jq
if command -v jq &>/dev/null; then
    pass "jq $(jq --version 2>&1 | sed 's/jq-//')"
else
    fail "jq not found — install with: sudo apt install jq"
fi

# flock
if command -v flock &>/dev/null; then
    pass "flock available"
else
    fail "flock not found — install with: sudo apt install util-linux"
fi

# git
if command -v git &>/dev/null; then
    pass "git $(git --version | awk '{print $3}')"
else
    fail "git not found"
fi

# awk
if command -v awk &>/dev/null; then
    pass "awk available"
else
    fail "awk not found"
fi

# sha256sum
if command -v sha256sum &>/dev/null; then
    pass "sha256sum available"
else
    fail "sha256sum not found"
fi

echo ""

# --------------------------------------------------
# 2. Check clafra installation (only if in a repo)
# --------------------------------------------------
if [[ -z "$CLAFRA_ROOT" ]]; then
    warn "Not inside a git repository — skipping installation checks"
    echo ""
else
    echo "Installation (${CLAFRA_ROOT}):"

    # Expected directories
    for dir in tools skills deprecated .clafra .clafra/pending-reviews; do
        if [[ -d "${CLAFRA_ROOT}/${dir}" ]]; then
            pass "${dir}/ exists"
        else
            warn "${dir}/ missing"
        fi
    done

    # Expected files
    for file in SKILL-GOVERNANCE.md CLAUDE.md patterns.json; do
        if [[ -f "${CLAFRA_ROOT}/${file}" ]]; then
            pass "${file} exists"
        else
            warn "${file} missing"
        fi
    done

    # Check patterns.json is valid JSON
    if [[ -f "${CLAFRA_ROOT}/patterns.json" ]]; then
        if jq empty "${CLAFRA_ROOT}/patterns.json" 2>/dev/null; then
            pass "patterns.json is valid JSON"

            # Check schema version
            version=$(jq -r '.version // empty' "${CLAFRA_ROOT}/patterns.json" 2>/dev/null)
            if [[ "$version" == "1" ]]; then
                pass "patterns.json schema version: ${version}"
            elif [[ -n "$version" ]]; then
                warn "patterns.json schema version ${version} — expected 1"
            else
                fail "patterns.json missing version field"
            fi
        else
            fail "patterns.json is not valid JSON"
        fi
    fi

    # Check tool/skill JSON files are valid
    for dir in tools skills; do
        if [[ -d "${CLAFRA_ROOT}/${dir}" ]]; then
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                basename_f=$(basename "$f")
                if jq empty "$f" 2>/dev/null; then
                    # Check required fields
                    missing=""
                    for field in name intent stack_dependencies success_criteria status; do
                        if ! jq -e ".${field}" "$f" &>/dev/null; then
                            missing="${missing} ${field}"
                        fi
                    done
                    if [[ -z "$missing" ]]; then
                        pass "${dir}/${basename_f} — valid schema"
                    else
                        fail "${dir}/${basename_f} — missing fields:${missing}"
                    fi
                else
                    fail "${dir}/${basename_f} — invalid JSON"
                fi
            done
        fi
    done

    # Check hooks
    echo ""
    echo "Hooks:"
    hooks_path=$(git -C "${CLAFRA_ROOT}" config core.hooksPath 2>/dev/null || echo "")
    if [[ -n "$hooks_path" ]]; then
        pass "core.hooksPath set to: ${hooks_path}"
    else
        warn "core.hooksPath not configured"
    fi

    for hook in pre-commit post-commit; do
        hook_file=""
        if [[ -n "$hooks_path" ]]; then
            hook_file="${CLAFRA_ROOT}/${hooks_path}/${hook}"
        fi
        if [[ -n "$hook_file" && -f "$hook_file" ]]; then
            if [[ -x "$hook_file" ]]; then
                pass "${hook} hook installed and executable"
            else
                fail "${hook} hook exists but not executable"
            fi
        else
            warn "${hook} hook not installed"
        fi
    done

    # Check .clafra scripts
    echo ""
    echo "Scripts:"
    for script in validate.sh create-tool.sh deprecate.sh check-similarity-local.sh \
                  check-similarity-remote.sh check-stack-change.sh parse-log.sh \
                  reduce-log.sh update-patterns.sh; do
        script_path="${CLAFRA_ROOT}/.clafra/${script}"
        if [[ -f "$script_path" ]]; then
            if [[ -x "$script_path" ]]; then
                pass ".clafra/${script}"
            else
                fail ".clafra/${script} exists but not executable"
            fi
        else
            warn ".clafra/${script} missing"
        fi
    done

    # Check project registry
    echo ""
    echo "Registry:"
    if [[ -f "${CLAFRA_ROOT}/.clafra/registry.json" ]]; then
        if jq empty "${CLAFRA_ROOT}/.clafra/registry.json" 2>/dev/null; then
            pass "registry.json is valid JSON"
        else
            fail "registry.json is invalid JSON"
        fi
    else
        warn "registry.json not found (created on first tool creation)"
    fi

    # Check user-level governance
    echo ""
    echo "User-level governance:"
    if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
        if grep -q "SKILL-GOVERNANCE" "${HOME}/.claude/CLAUDE.md" 2>/dev/null; then
            pass "~/.claude/CLAUDE.md has governance rules"
        else
            warn "~/.claude/CLAUDE.md exists but missing governance — run: clafra-init.sh --user-only"
        fi
    else
        warn "~/.claude/CLAUDE.md not found — run: clafra-init.sh --user-only"
    fi
fi

# --------------------------------------------------
# 3. Optional: SSH connectivity check
# --------------------------------------------------
echo ""
echo "Optional:"
if [[ -n "${CLAFRA_SSH_HOST:-}" ]]; then
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "${CLAFRA_SSH_HOST}" "echo ok" &>/dev/null; then
        pass "SSH to ${CLAFRA_SSH_HOST} — reachable"
    else
        warn "SSH to ${CLAFRA_SSH_HOST} — unreachable (async reviews will be skipped)"
    fi
else
    warn "CLAFRA_SSH_HOST not set — async similarity reviews disabled"
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "---"
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}${ERRORS} error(s)${NC}, ${WARNINGS} warning(s)"
    if jq empty /dev/null 2>/dev/null; then
        exit 1
    else
        exit 1
    fi
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${GREEN}0 errors${NC}, ${YELLOW}${WARNINGS} warning(s)${NC}"
    exit 0
else
    echo -e "${GREEN}All checks passed${NC}"
    exit 0
fi
