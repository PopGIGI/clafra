#!/usr/bin/env bash
# build-summon-index.sh — Derive file→tool mapping from success_criteria
#
# Parses file paths out of each tool's success_criteria commands and builds
# a reverse index: which tools are relevant when a given file is touched.
#
# Output: .clafra/summon-index.json

set -euo pipefail

CLAFRA_ROOT="${CLAFRA_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAFRA_DIR="${CLAFRA_ROOT}/.clafra"
INDEX_FILE="${CLAFRA_DIR}/summon-index.json"

# Temporary file for collecting mappings
TMP=$(mktemp)
trap "rm -f $TMP" EXIT

for dir in tools skills; do
    for tool_file in "${CLAFRA_ROOT}/${dir}"/*.json; do
        [[ -f "$tool_file" ]] || continue

        status=$(jq -r '.status' "$tool_file" 2>/dev/null)
        [[ "$status" == "active" || "$status" == "stale" ]] || continue

        tool_name=$(jq -r '.name' "$tool_file")

        # Extract all success_criteria
        while IFS= read -r criterion; do
            [[ -n "$criterion" ]] || continue

            # Pull out path-like strings (word/word.ext patterns)
            for path in $(echo "$criterion" | grep -oE '[a-zA-Z_][a-zA-Z0-9_/.-]*\.[a-zA-Z]{1,5}' || true); do
                # Only include paths that exist as files in the project
                if [[ -f "${CLAFRA_ROOT}/${path}" ]]; then
                    echo "${path}	${tool_name}" >> "$TMP"
                fi
            done
        done < <(jq -r '.success_criteria[]?' "$tool_file" 2>/dev/null)
    done
done

# Build JSON from collected pairs
if [[ ! -s "$TMP" ]]; then
    echo '{"generated_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","index":{}}' | jq . > "$INDEX_FILE"
    echo "Summon index built: 0 files mapped"
    exit 0
fi

# Sort, deduplicate, and convert to JSON
sort -u "$TMP" | awk -F'\t' '
{
    files[$1] = files[$1] ? files[$1] "," $2 : $2
}
END {
    for (f in files) {
        n = split(files[f], tools, ",")
        for (i = 1; i <= n; i++) {
            print f "\t" tools[i]
        }
    }
}' | sort -u | jq -Rn '
  [inputs | split("\t") | {file: .[0], tool: .[1]}]
  | group_by(.file)
  | map({key: .[0].file, value: [.[].tool]})
  | from_entries
  | {generated_at: now | todate, index: .}
' > "$INDEX_FILE"

count=$(jq '.index | keys | length' "$INDEX_FILE")
echo "Summon index built: ${count} files mapped → ${INDEX_FILE}"
