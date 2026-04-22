#!/bin/bash -e
# 용도:
#   1. Gerrit commit URL을 넣으면 해당그룹에 대한 url만 출력 (3번째이상 파라미터 없을때)
#   2. 추출된 url에 대해서 특정 field에 label 점수와 코멘트 전송 (3번째이상 파라미터 있을때)
#   
# 사용법: 
#   feedback_commit.sh <group> <candidate_list_file> [item] [grade] [text...]
#   <group>               : repo list group name (e.g. amss)
#   <candidate_list_file> : file containing Gerrit commit URLs (one per line)
#   [item]                : verified|verfied|review|ai-review
#   [grade]               : label score (e.g. +1, -1, 0)
#   [text...]             : message line shown below "Build Successful" (used only when item exists)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_SH="${SCRIPT_DIR}/commit.sh"

[[ $# -lt 2 ]] && {
    echo "Usage: $0 <group> <candidate_list_file> [item] [grade] [text...]"
    echo "  item: verified|verfied|review|ai-review"
    echo "  grade: +1|-1|0 ..."
    exit 1
}

GROUP="$1"
COMMIT_CANDIDATE="$2"
item_input="${3:-}"
grade_input="${4:-}"
FEEDBACK_TEXT="${*:5}"

COLOR_GREEN="\033[92m\033[1m"
COLOR_RED="\033[91m\033[1m"
COLOR_YELLOW="\033[93m\033[1m"
COLOR_RESET="\033[0m"

[[ ! -f "$COMMIT_CANDIDATE" ]] && { echo "Error: file not found: $COMMIT_CANDIDATE" >&2; exit 1; }
[[ ! -x "$COMMIT_SH" ]] && { echo "Error: commit.sh not executable: $COMMIT_SH" >&2; exit 1; }

if [[ -n "$item_input" ]]; then
    case "${item_input,,}" in
        verified|verfied) label_name="Verified" ;;
        review) label_name="Code-Review" ;;
        ai-review) label_name="AI-Review" ;;
        *) echo "Error: unsupported item '$item_input'" >&2; exit 1 ;;
    esac

    [[ ! "$grade_input" =~ ^[+-]?[0-9]+$ ]] && { echo "Error: invalid grade '$grade_input' (expected integer like +1, -1, 0)" >&2; exit 1; }
    label_grade="$grade_input"

    [[ -z "$FEEDBACK_TEXT" ]] && { echo "Error: feedback text required when item is set" >&2; exit 1; }
fi

## Gerrit URL에서 git 프로젝트명을 추출합니다.
function extract_gitname_from_url() { sed -n 's#^https\?://[^/]\+/[^/]\+/c/\(.*\)/+/[0-9][0-9]*$#\1#p' <<< "$1"; }

# URL을 gitname으로 인덱싱 (한 gitname에 여러 URL 가능)
declare -A url_map
while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    url="$(echo "$url" | tr -d '\r\n ')"
    gitname="$(extract_gitname_from_url "$url")"
    if [[ -n "$gitname" ]]; then
        # 구분자(newline)로 URL 추가
        url_map["$gitname"]+="${url}"$'\n'
    fi
done < "$COMMIT_CANDIDATE"

# ── 2. repo list로 git name 목록 추출하여 매칭 ────────────────────────────
mapfile -t git_names < <(repo list -g "$GROUP" -n 2>/dev/null)

[[ ${#git_names[@]} -eq 0 ]] && exit 0

matched_urls=()
for gitname in "${git_names[@]}"; do
    if [[ -n "${url_map[$gitname]}" ]]; then
        # newline으로 구분된 URL들을 배열에 추가
        while IFS= read -r url; do
            [[ -n "$url" ]] && matched_urls+=("$url")
        done <<< "${url_map[$gitname]}"
    fi
done

[[ ${#matched_urls[@]} -eq 0 ]] && { echo "no matched commit urls for this [$GROUP]"; exit 0; }
[[ -z "$label_name" ]] && { printf "%s\n" "${matched_urls[@]}" | awk '!seen[$0]++'; exit 0; }

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