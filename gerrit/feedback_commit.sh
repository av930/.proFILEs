#!/bin/bash
# Usage: feedback_commit.sh <group> <candidate_list_file> [item] [grade] [text...]
#
#   <group>               : repo list group name (e.g. amss)
#   <candidate_list_file> : file containing Gerrit commit URLs (one per line)
#   [item]                : verified|verfied|review|ai-review
#   [grade]               : label score (e.g. +1, -1, 0)
#   [text...]             : message line shown below "Build Successful" (used only when item exists)
#
# This script finds one URL per repo in group and then calls commit.sh:
#   commit.sh write <url> labels '{"labels":{"<Label>":<grade>},"message":"..."}'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_SH="${SCRIPT_DIR}/commit.sh"

usage() {
    echo "Usage: $0 <group> <candidate_list_file> [item] [grade] [text...]"
    echo "  item: verified|verfied|review|ai-review"
    echo "  grade: +1|-1|0 ..."
    echo "  if item is omitted, script only prints matched URLs and exits"
}

[[ $# -lt 2 ]] && { usage; exit 1; }

GROUP="$1"
CANDIDATE_LIST_FILE="$2"
item_input="${3:-}"
grade_input="${4:-}"
FEEDBACK_TEXT="${*:5}"

COLOR_GREEN="\033[92m\033[1m"
COLOR_RED="\033[91m\033[1m"
COLOR_YELLOW="\033[93m\033[1m"
COLOR_RESET="\033[0m"

[[ ! -f "$CANDIDATE_LIST_FILE" ]] && { echo "Error: file not found: $CANDIDATE_LIST_FILE" >&2; exit 1; }
[[ ! -x "$COMMIT_SH" ]]           && { echo "Error: commit.sh not executable: $COMMIT_SH" >&2; exit 1; }

write_mode="false"
if [[ -n "$item_input" ]]; then
    write_mode="true"

    case "${item_input,,}" in
        verified|verfied) label_name="Verified"
        ;;
        review) label_name="Code-Review"
        ;;
        ai-review) label_name="AI-Review"
        ;;
        *)
            echo "Error: unsupported item '$item_input'" >&2
            usage
            exit 1
        ;;
    esac

    if [[ "$grade_input" =~ ^[+-]?[0-9]+$ ]]; then
        label_grade="$grade_input"
    else
        echo "Error: invalid grade '$grade_input' (expected integer like +1, -1, 0)" >&2
        exit 1
    fi

    [[ -z "$FEEDBACK_TEXT" ]] && { echo "Error: feedback text required when item is set" >&2; exit 1; }
fi

# ── 1. repo list로 git name 목록 추출 ───────────────────────────────────────
mapfile -t git_names < <(repo list -g "$GROUP" -n 2>/dev/null)

[[ ${#git_names[@]} -eq 0 ]] && exit 0

# ── 2. 각 git name에 대해 candidate_list_file에서 URL 매칭 ──────────────────
#   match 조건: URL 안에 /c/<gitname>/+ 가 포함 (gitname 뒤에 바로 /+ 가 와야 함)
#   → grep -F 로 고정문자열 검색 시 /c/hkmc/build-poip/+ 는
#     /c/hkmc/build-poip/gen/+/... URL과 매칭되지 않음 (올바른 동작)

matched_urls=()

extract_gitname_from_url() {
    local url="$1"
    sed -n 's#^https\?://[^/]\+/[^/]\+/c/\(.*\)/+/[0-9][0-9]*$#\1#p' <<< "$url"
}

for gitname in "${git_names[@]}"; do
    matches=()
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        url="$(echo "$url" | tr -d '\r\n ')"
        url_gitname="$(extract_gitname_from_url "$url")"
        [[ -z "$url_gitname" ]] && continue
        [[ "$url_gitname" == "$gitname" ]] && matches+=("$url")
    done < "$CANDIDATE_LIST_FILE"

    count=${#matches[@]}

    if [[ $count -gt 0 ]]; then
        for m in "${matches[@]}"; do
            matched_urls+=("$m")
        done
    fi
done

if [[ ${#matched_urls[@]} -eq 0 ]]; then
    exit 0
fi

if [[ "$write_mode" != "true" ]]; then
    printf "%s\n" "${matched_urls[@]}" | awk '!seen[$0]++'
    exit 0
fi

# ── 3. 매칭된 URL에 label 점수 및 코멘트 전송 (commit.sh 경유) ───────────────
echo ""
echo "Applying ${label_name} ${label_grade} to ${#matched_urls[@]} commits..."
echo ""

success_count=0
fail_count=0

for commit_url in "${matched_urls[@]}"; do
    commit_url="$(echo "$commit_url" | tr -d '\r\n ')"

    payload="$(jq -cn \
        --arg label_name "$label_name" \
        --argjson label_grade "$label_grade" \
        --arg msg "$(printf 'Build Successful\n%s' "${FEEDBACK_TEXT}")" \
        '{labels:{($label_name):$label_grade},message:$msg}')"

    result=0
    response="$($COMMIT_SH write "$commit_url" labels "$payload" 2>&1)" || result=$?

    if [[ $result -eq 0 ]]; then
        echo -e "${COLOR_GREEN}[OKAY]${COLOR_RESET} ${label_name}${label_grade}: $commit_url"
        success_count=$((success_count + 1))
    else
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $commit_url"
        echo "       -> $response"
        fail_count=$((fail_count + 1))
    fi
done

echo ""
echo "Done: ${success_count} succeeded, ${fail_count} failed"