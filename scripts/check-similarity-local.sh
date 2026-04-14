#!/usr/bin/env bash
# check-similarity-local.sh — Tier 1 local token similarity check
#
# Usage: check-similarity-local.sh "proposed intent text"
# Exit codes: 0=no overlap, 1=overlap found, 2=ambiguous, 3=error
#
# Computes cosine similarity using word token overlap between the proposed
# intent and all existing tool/skill intents.

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"

THRESHOLD_BLOCK=0.7    # >0.7 = definite overlap, block creation
THRESHOLD_AMBIGUOUS=0.4 # 0.4-0.7 = ambiguous, flag for human

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ $# -lt 1 ]]; then
    echo "Usage: check-similarity-local.sh \"proposed intent text\""
    exit 3
fi

PROPOSED="$1"

# --------------------------------------------------
# Tokenize: lowercase, split on non-alpha, sort unique
# --------------------------------------------------
tokenize() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | sort -u | grep -v '^$'
}

# --------------------------------------------------
# Cosine similarity via token overlap
# --------------------------------------------------
cosine_similarity() {
    local tokens_a="$1"
    local tokens_b="$2"

    # Use awk to compute |A ∩ B| / sqrt(|A| * |B|)
    echo "$tokens_a" | awk -v tb="$tokens_b" '
    BEGIN {
        split(tb, b_arr, "\n")
        for (i in b_arr) b_set[b_arr[i]] = 1
        a_count = 0
        b_count = length(b_arr)
        overlap = 0
    }
    {
        a_count++
        if ($0 in b_set) overlap++
    }
    END {
        if (a_count == 0 || b_count == 0) { print "0.0"; exit }
        denom = sqrt(a_count * b_count)
        if (denom == 0) { print "0.0"; exit }
        printf "%.4f\n", overlap / denom
    }'
}

# --------------------------------------------------
# Collect existing intents
# --------------------------------------------------
proposed_tokens=$(tokenize "$PROPOSED")

max_score=0
max_name=""
max_file=""

for dir in tools skills; do
    [[ -d "${CLAFRA_ROOT}/${dir}" ]] || continue
    for f in "${CLAFRA_ROOT}/${dir}"/*.json; do
        [[ -f "$f" ]] || continue

        status=$(jq -r '.status // "unknown"' "$f" 2>/dev/null)
        [[ "$status" == "active" || "$status" == "stale" ]] || continue

        intent=$(jq -r '.intent // ""' "$f" 2>/dev/null)
        [[ -n "$intent" ]] || continue

        name=$(jq -r '.name // "unknown"' "$f" 2>/dev/null)
        existing_tokens=$(tokenize "$intent")

        score=$(cosine_similarity "$proposed_tokens" "$existing_tokens")

        # Compare as integers (multiply by 1000)
        score_int=$(echo "$score" | awk '{printf "%d", $1 * 1000}')
        max_int=$(echo "$max_score" | awk '{printf "%d", $1 * 1000}')

        if [[ $score_int -gt $max_int ]]; then
            max_score="$score"
            max_name="$name"
            max_file="$f"
        fi
    done
done

# --------------------------------------------------
# Report result
# --------------------------------------------------
if [[ "$max_file" == "" ]]; then
    echo -e "${GREEN}No existing tools/skills to compare against.${NC}"
    echo '{"result": "no_overlap", "score": 0, "match": null}'
    exit 0
fi

max_int=$(echo "$max_score" | awk '{printf "%d", $1 * 1000}')
block_int=$(echo "$THRESHOLD_BLOCK" | awk '{printf "%d", $1 * 1000}')
ambig_int=$(echo "$THRESHOLD_AMBIGUOUS" | awk '{printf "%d", $1 * 1000}')

if [[ $max_int -gt $block_int ]]; then
    echo -e "${RED}Overlap detected${NC} (score: ${max_score}) with '${max_name}'"
    echo -e "  Consider extending ${max_file} instead of creating a new tool."
    echo "{\"result\": \"overlap\", \"score\": ${max_score}, \"match\": \"${max_name}\", \"file\": \"${max_file}\"}"
    exit 1
elif [[ $max_int -gt $ambig_int ]]; then
    echo -e "${YELLOW}Ambiguous overlap${NC} (score: ${max_score}) with '${max_name}'"
    echo -e "  Human decision required. Review ${max_file}"
    echo "{\"result\": \"ambiguous\", \"score\": ${max_score}, \"match\": \"${max_name}\", \"file\": \"${max_file}\"}"
    exit 2
else
    echo -e "${GREEN}No significant overlap${NC} (best match: ${max_name}, score: ${max_score})"
    echo "{\"result\": \"no_overlap\", \"score\": ${max_score}, \"match\": \"${max_name}\"}"
    exit 0
fi
