#!/bin/bash
set -euo pipefail

# Gerrit에서 특정 기간 내 merged change 중 SRC_URI 할당 변경이 있는 commit URL 검색

usage() {
    echo "Usage: $0 <user:key> <vgit.lge.com/na> <query> <period> <regexp> [ext_list]" >&2
    echo "Example: $0 'vc.integrator:***' 'vgit.lge.com/na' 'status:merged' '365d' '^[+-].*SRC_URI'" >&2
    echo "Example: $0 'vc.integrator:UUm~~0g' 'vgit.lge.com/as' 'status:merged' '365d' \
    '^[+-].*SRC_URI([[:space:]]*:(append|prepend|remove)(:[^[:space:]]+)*)?[[:space:]]*(\?\?=|\?=|:=|\+=|=\+|\.=|=\.|=)' \
    '.bb,.bbappend,.bbclass,.inc,.conf'"
}

readonly DEFAULT_EXT_LIST='.bb,.bbappend,.bbclass,.inc,.conf'

require_commands() {
    command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
    command -v base64 >/dev/null 2>&1 || { echo "base64 not found" >&2; exit 1; }
}

curl_gerrit() {
    curl -fsSk "$@"
}

normalize_base_url() {
    local arg_url="$1"
    [[ "$arg_url" =~ ^https?:// ]] || arg_url="https://${arg_url}"
    echo "${arg_url%/}"
}

build_since_date() {
    local arg_period="$1" num unit

    if [[ "$arg_period" =~ ^[0-9]+$ ]]; then
        date -u -d "-${arg_period} days" +%F;  return 0
    elif [[ "$arg_period" =~ ^([0-9]+)([dDwWmMyY])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
        case "$unit" in
             d) date -u -d "-${num} days" +%F
        ;;   w) date -u -d "-$((num * 7)) days" +%F
        ;;   m) date -u -d "-${num} months" +%F
        ;;   y) date -u -d "-${num} years" +%F
        esac
        return 0
    elif [[ "$arg_period" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "$arg_period";  return 0
    fi

    echo "Invalid period: $arg_period" >&2
    return 1
}

strip_gerrit_json_prefix() {
    sed '1s/^)]}'"'"'//'
}

match_patch() {
    local patch_text="$1" re="$2"
    grep -Eq "$re" <<< "$patch_text"
}

fetch_patch_text() {
    local auth="$1" base_url="$2" change_num="$3" patch_b64=""
    patch_b64=$(curl_gerrit -u "$auth" "${base_url}/a/changes/${change_num}/revisions/current/patch?download" 2>/dev/null || true)
    [[ -z "$patch_b64" ]] && return 1
    printf '%s' "$patch_b64" | tr -d '\r\n' | base64 -d 2>/dev/null
}

fetch_changed_files() {
    local auth="$1" base_url="$2" change_num="$3"
    curl_gerrit -u "$auth" "${base_url}/a/changes/${change_num}/revisions/current/files/" 2>/dev/null | strip_gerrit_json_prefix
}

match_changed_files() {
    local files_json="$1" file_re="$2"
    jq -r 'keys[]' <<< "$files_json" | grep -Ev '^/COMMIT_MSG$' | grep -Eq "$file_re"
}

build_file_regexp() {
    local arg_ext_list="$1" ext normalized regex_parts="" old_ifs="$IFS"

    IFS=','
    for ext in $arg_ext_list; do
        ext=$(printf '%s' "$ext" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$ext" ]] && continue
        normalized="${ext#.}"
        [[ -z "$normalized" ]] && continue
        [[ -n "$regex_parts" ]] && regex_parts+="|"
        regex_parts+="${normalized//./\\.}"
    done
    IFS="$old_ifs"

    [[ -n "$regex_parts" ]] || { echo "Invalid extension list: $arg_ext_list" >&2; return 1; }
    echo "\\.(${regex_parts})$"
}

main() {
    local arg_auth="${1:-}" arg_base_url="${2:-}" arg_query="${3:-}" arg_period="${4:-}" arg_regexp="${5:-}" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"
    local base_url since_date since_epoch query api_url start=0 page_size=100 page_json page_count more_changes=false
    local change_json change_num project submitted submitted_epoch patch_text commit_url files_json file_regexp

    [[ $# -ge 5 && $# -le 6 ]] || { usage; exit 1; }
    [[ "$arg_auth" == *:* ]] || { echo "First parameter must be user:key" >&2; exit 1; }
    [[ -n "$arg_regexp" ]] || { echo "Fifth parameter regexp is required" >&2; exit 1; }

    require_commands
    base_url=$(normalize_base_url "$arg_base_url")
    since_date=$(build_since_date "$arg_period")
    since_epoch=$(date -u -d "$since_date 00:00:00" +%s)
    file_regexp=$(build_file_regexp "$arg_ext_list")
    query="$arg_query"
    [[ "$query" == *"status:merged"* ]] || query="${query} status:merged"
    [[ "$query" == *"after:"* ]] || query="${query} after:${since_date}"
    api_url="${base_url}/a/changes/"

    while :; do
        page_json=$(curl_gerrit -u "$arg_auth" --get "$api_url" \
            --data-urlencode "q=${query}" \
            --data "n=${page_size}" \
            --data "S=${start}" | strip_gerrit_json_prefix)

        page_count=$(jq 'length' <<< "$page_json")
        [[ "$page_count" -eq 0 ]] && break

        while IFS= read -r change_json; do
            change_num=$(jq -r '._number' <<< "$change_json")
            project=$(jq -r '.project' <<< "$change_json")
            submitted=$(jq -r '.submitted // empty' <<< "$change_json")

            if [[ -n "$submitted" ]]; then
                submitted_epoch=$(date -u -d "$submitted" +%s 2>/dev/null || echo 0)
                [[ "$submitted_epoch" -lt "$since_epoch" ]] && continue
            fi

            files_json=$(fetch_changed_files "$arg_auth" "$base_url" "$change_num" || true)
            [[ -z "$files_json" ]] && continue
            match_changed_files "$files_json" "$file_regexp" || continue

            patch_text=$(fetch_patch_text "$arg_auth" "$base_url" "$change_num" || true)
            [[ -z "$patch_text" ]] && continue
            match_patch "$patch_text" "$arg_regexp" || continue

            commit_url="${base_url}/c/${project}/+/${change_num}"
            echo "$commit_url"
        done < <(jq -c '.[]' <<< "$page_json")

        more_changes=$(jq -r '.[-1]._more_changes // false' <<< "$page_json")
        [[ "$more_changes" == "true" ]] || break
        start=$((start + page_count))
    done | awk '!seen[$0]++'
}

main "$@"