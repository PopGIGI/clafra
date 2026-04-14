#!/usr/bin/env bash
# validate.sh — Central validation engine for clafra governance
#
# Usage: validate.sh [--session-start | --pre-commit | --full]
#   --session-start  Lightweight pass, actionable items only
#   --pre-commit     Blocks on schema violations in changed tool/skill files
#   --full           Complete audit for milestones

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAFRA_DIR="${CLAFRA_ROOT}/.clafra"
MODE="${1:---session-start}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

ISSUES=0
STALE_COUNT=0
DEPRECATION_FLAGS=0
VALIDATION_LOG="${CLAFRA_DIR}/validation.log"
CURRENT_COMMIT=$(git -C "$CLAFRA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

log_issue() { echo -e "  ${RED}✗${NC} $1"; ISSUES=$((ISSUES + 1)); }
log_warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
log_ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
log_info()  { echo -e "  ${CYAN}→${NC} $1"; }

# Append one-line entry to validation log
vlog() {
    local tool="$1" result="$2" detail="${3:-}"
    echo "$(now_iso) | ${MODE} | ${CURRENT_COMMIT} | ${tool} | ${result} | ${detail}" >> "$VALIDATION_LOG"
}

# --------------------------------------------------
# Helpers
# --------------------------------------------------
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.bak"
    fi
}

locked_write() {
    local file="$1"
    local content="$2"
    (
        flock -w 5 200 || { echo "Failed to acquire lock on ${file}" >&2; exit 1; }
        backup_file "$file"
        echo "$content" > "$file"
    ) 200>"${file}.lock"
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

days_since() {
    local timestamp="$1"
    if [[ -z "$timestamp" || "$timestamp" == "null" ]]; then
        echo "999"
        return
    fi
    local ts_epoch
    ts_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (now_epoch - ts_epoch) / 86400 ))
}

# --------------------------------------------------
# 1. Validate tool/skill JSON schema
# --------------------------------------------------
validate_schema() {
    local file="$1"
    local basename_f
    basename_f=$(basename "$file")
    local dir
    dir=$(basename "$(dirname "$file")")

    if ! jq empty "$file" 2>/dev/null; then
        log_issue "${dir}/${basename_f}: invalid JSON"
        return 1
    fi

    local missing=""
    for field in name intent stack_dependencies success_criteria status; do
        if ! jq -e ".${field}" "$file" &>/dev/null; then
            missing="${missing} ${field}"
        fi
    done

    if [[ -n "$missing" ]]; then
        log_issue "${dir}/${basename_f}: missing required fields:${missing}"
        return 1
    fi

    # Validate status value
    local status
    status=$(jq -r '.status' "$file")
    case "$status" in
        active|stale|deprecated) ;;
        *) log_issue "${dir}/${basename_f}: invalid status '${status}'"; return 1 ;;
    esac

    return 0
}

# --------------------------------------------------
# 2. Check staleness
# --------------------------------------------------
check_staleness() {
    local file="$1"
    local basename_f
    basename_f=$(basename "$file")
    local dir
    dir=$(basename "$(dirname "$file")")

    local status
    status=$(jq -r '.status' "$file")
    [[ "$status" == "active" || "$status" == "stale" ]] || return 0

    local last_validated
    last_validated=$(jq -r '.last_validated // empty' "$file")
    local staleness_days
    staleness_days=$(jq -r '.staleness_days // 30' "$file")

    local age
    age=$(days_since "$last_validated")

    if [[ "$age" -gt "$staleness_days" ]]; then
        STALE_COUNT=$((STALE_COUNT + 1))
        if [[ "$status" == "active" ]]; then
            log_warn "${dir}/${basename_f}: stale (${age} days since validation, threshold: ${staleness_days})"
            # Update status to stale
            if [[ "$MODE" == "--full" ]]; then
                local updated
                updated=$(jq --arg now "$(now_iso)" '.status = "stale"' "$file")
                locked_write "$file" "$updated"
                log_info "Status updated to stale"
            fi
        else
            log_warn "${dir}/${basename_f}: still stale (${age} days)"
        fi
    else
        if [[ "$MODE" == "--full" ]]; then
            log_ok "${dir}/${basename_f}: fresh (${age}/${staleness_days} days)"
        fi
    fi
}

# --------------------------------------------------
# 3. Check stack dependencies
# --------------------------------------------------
check_stack_deps() {
    local file="$1"
    local basename_f
    basename_f=$(basename "$file")
    local dir
    dir=$(basename "$(dirname "$file")")

    local deps
    deps=$(jq -r '.stack_dependencies[]? // empty' "$file" 2>/dev/null)
    [[ -n "$deps" ]] || return 0

    while IFS= read -r dep; do
        if [[ ! -f "${CLAFRA_ROOT}/${dep}" ]]; then
            log_warn "${dir}/${basename_f}: stack dependency '${dep}' not found"
        fi
    done <<< "$deps"
}

# --------------------------------------------------
# 4. Check success criteria
# --------------------------------------------------
check_success_criteria() {
    local file="$1"
    local basename_f
    basename_f=$(basename "$file")
    local dir
    dir=$(basename "$(dirname "$file")")

    local criteria_count
    criteria_count=$(jq '.success_criteria | length' "$file")
    if [[ "$criteria_count" -eq 0 ]]; then
        log_warn "${dir}/${basename_f}: no success criteria defined — cannot validate"
        return 0
    fi

    local failed=0
    local i=0
    while [[ $i -lt $criteria_count ]]; do
        local criterion
        criterion=$(jq -r ".success_criteria[$i]" "$file")

        # Each criterion is a shell command that should exit 0
        if ! (cd "$CLAFRA_ROOT" && eval "$criterion" &>/dev/null); then
            log_issue "${dir}/${basename_f}: criterion failed: ${criterion}"
            vlog "$basename_f" "FAIL" "$criterion"
            failed=$((failed + 1))
        fi
        i=$((i + 1))
    done

    if [[ $failed -eq 0 ]]; then
        log_ok "${dir}/${basename_f}: all ${criteria_count} criteria pass"
        vlog "$basename_f" "PASS" "${criteria_count} criteria"
        # Update last_validated on any successful check
        local updated
        updated=$(jq --arg now "$(now_iso)" '.last_validated = $now | .status = "active"' "$file")
        locked_write "$file" "$updated"
    else
        vlog "$basename_f" "FAIL" "${failed}/${criteria_count} criteria failed"
    fi
}

# --------------------------------------------------
# 5. Check registry consistency
# --------------------------------------------------
check_registry() {
    local registry="${CLAFRA_DIR}/registry.json"

    if [[ ! -f "$registry" ]]; then
        log_warn "Project registry (.clafra/registry.json) not found"
        return 0
    fi

    if ! jq empty "$registry" 2>/dev/null; then
        log_issue "registry.json is invalid JSON"
        return 1
    fi

    # Cross-check registry entries against actual files
    local orphaned=0
    for type in tools skills; do
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            local name file
            name=$(echo "$entry" | jq -r '.name')
            file=$(echo "$entry" | jq -r '.file')
            if [[ ! -f "$file" ]]; then
                log_warn "Registry entry '${name}' points to missing file: ${file}"
                orphaned=$((orphaned + 1))
            fi
        done < <(jq -c ".${type}[]?" "$registry" 2>/dev/null)
    done

    # Check for unregistered active tools
    local active_count=0
    for dir in tools skills; do
        for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
            [[ -f "$f" ]] || continue
            local status
            status=$(jq -r '.status' "$f" 2>/dev/null)
            [[ "$status" == "active" || "$status" == "stale" ]] || continue
            active_count=$((active_count + 1))
        done
    done

    if [[ "$MODE" == "--full" ]]; then
        log_ok "Registry check: ${active_count} active items, ${orphaned} orphaned entries"
    fi

    # Check user-level CLAUDE.md exists
    local user_claude="${HOME}/.claude/CLAUDE.md"
    if [[ -f "$user_claude" ]]; then
        if grep -q "SKILL-GOVERNANCE" "$user_claude" 2>/dev/null; then
            log_ok "User-level governance active (~/.claude/CLAUDE.md)"
        else
            log_warn "~/.claude/CLAUDE.md exists but missing governance rules — run: clafra-init.sh --user-only"
        fi
    else
        log_warn "No user-level CLAUDE.md — run: clafra-init.sh --user-only"
    fi
}

# --------------------------------------------------
# 6. Process pending async reviews
# --------------------------------------------------
check_pending_reviews() {
    local reviews_dir="${CLAFRA_DIR}/pending-reviews"
    [[ -d "$reviews_dir" ]] || return 0

    local count=0
    for review in "${reviews_dir}"/*.json; do
        [[ -f "$review" ]] || continue
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log_info "${count} pending similarity review(s) queued"
        if [[ -n "${CLAFRA_SSH_HOST:-}" ]] && [[ -x "${CLAFRA_DIR}/check-similarity-remote.sh" ]]; then
            log_info "Running async reviews via ${CLAFRA_SSH_HOST}..."
            "${CLAFRA_DIR}/check-similarity-remote.sh" || true
        else
            log_warn "Set CLAFRA_SSH_HOST to process async reviews"
        fi
    fi
}

# --------------------------------------------------
# Main
# --------------------------------------------------
echo "clafra validate (${MODE})"
echo "========================="
echo ""

case "$MODE" in
    --session-start)
        echo "Staleness & pending reviews:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                check_staleness "$f"
            done
        done

        echo ""
        echo "Success criteria:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                local_status=$(jq -r '.status' "$f" 2>/dev/null)
                [[ "$local_status" == "active" || "$local_status" == "stale" ]] || continue
                check_success_criteria "$f"
            done
        done

        check_pending_reviews
        ;;

    --pre-commit)
        echo "Schema validation:"
        # Get list of staged tool/skill files
        staged=$(git -C "$CLAFRA_ROOT" diff --cached --name-only -- 'tools/*.json' 'skills/*.json' 2>/dev/null || true)
        if [[ -n "$staged" ]]; then
            while IFS= read -r relpath; do
                filepath="${CLAFRA_ROOT}/${relpath}"
                [[ -f "$filepath" ]] || continue
                validate_schema "$filepath"
            done <<< "$staged"
        else
            log_ok "No tool/skill files in commit"
        fi

        # Check stack changes
        stack_changed=$(git -C "$CLAFRA_ROOT" diff --cached --name-only -- 'package.json' 'package-lock.json' 'requirements.txt' 'Cargo.toml' 'go.mod' 2>/dev/null || true)
        if [[ -n "$stack_changed" ]]; then
            echo ""
            echo "Stack changes detected:"
            if [[ -x "${CLAFRA_DIR}/check-stack-change.sh" ]]; then
                "${CLAFRA_DIR}/check-stack-change.sh" || true
            else
                log_warn "check-stack-change.sh not found"
            fi
        fi
        ;;

    --full)
        echo "Full audit:"
        echo ""
        echo "Schema:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                validate_schema "$f"
            done
        done

        echo ""
        echo "Staleness:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                check_staleness "$f"
            done
        done

        echo ""
        echo "Stack dependencies:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                check_stack_deps "$f"
            done
        done

        echo ""
        echo "Success criteria:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                check_success_criteria "$f"
            done
        done

        echo ""
        echo "Registry & governance:"
        check_registry

        echo ""
        echo "Pending reviews:"
        check_pending_reviews

        # Check auto-deprecation flags
        echo ""
        echo "Deprecation candidates:"
        for dir in tools skills; do
            for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
                [[ -f "$f" ]] || continue
                local_status=$(jq -r '.status' "$f" 2>/dev/null)
                if [[ "$local_status" == "stale" ]]; then
                    local_name=$(jq -r '.name' "$f" 2>/dev/null)
                    log_warn "${local_name} — stale, candidate for deprecation"
                    DEPRECATION_FLAGS=$((DEPRECATION_FLAGS + 1))
                fi
            done
        done
        if [[ $DEPRECATION_FLAGS -eq 0 ]]; then
            log_ok "No deprecation candidates"
        fi
        ;;

    *)
        echo "Usage: validate.sh [--session-start | --pre-commit | --full]"
        exit 1
        ;;
esac

echo ""
echo "---"
if [[ $ISSUES -gt 0 ]]; then
    echo -e "${RED}${ISSUES} issue(s) found${NC}"
    exit 1
else
    echo -e "${GREEN}Validation complete${NC} (${STALE_COUNT} stale)"
    exit 0
fi
