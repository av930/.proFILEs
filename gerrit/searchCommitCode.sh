#!/bin/bash
set -euo pipefail

# Gerrit 또는 local git history에서 특정 regexp를 만족하는 commit을 검색한다.
# Gerrit은 merged history를, local은 git log -G history를 기반으로 필터링한다.

readonly SSH_OPTS=(-n -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)
readonly DEFAULT_EXT_LIST='.bb,.bbappend,.bbclass,.inc,.conf'
readonly LOCAL_PRUNE_EXPR="\( -path '*/.repo/*' -o -path '*/build/*' -o -path '*/tmp/*' -o -path '*/tmp-*/*' -o -path '*/work/*' -o -path '*/work-*/*' -o -path '*/buildhistory/*' -o -path '*/_SYSROOT_FILES/*' -o -path '*/upload_images/*' \)"
readonly LOCAL_HOST_IPS="$(hostname -I 2>/dev/null || true)"

usage() {
    echo "Gerrit : $0 <user:key> <vgit.lge.com/na> <query> <period> <regexp> [ext_list]" >&2
    echo "Local  : $0 <ssh_server_ip> <rootdir> <subpath> <period> <regexp> [ext_list]" >&2
    echo "Example: $0 'vc.integrator:***' 'vgit.lge.com/na' 'status:merged' '365d' 'SRC_URI'" >&2
    echo "Example: $0 '10.159.30.66' '/path/to/root' '/path/to/subpath' '365d' 'SRC_URI([[:space:]]*:(append|prepend|remove))?[[:space:]]*(\?\?=|\?=|:=|\+=|=\+|\.=|=\.|=)' '.bb,.bbappend,.bbclass,.inc,.conf'" >&2
    echo "date period format: 365, 365d, 12m, 2025-01-01" >&2
}

require_commands() {
    command -v base64 >/dev/null 2>&1 || { echo "base64 not found" >&2; exit 1; }
    command -v curl   >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
    command -v jq     >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
    command -v ssh    >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }
}

curl_gerrit() { curl -fsSk "$@"; }

is_local_server_ip() {
#----------------------------------------------------------------------------------------------------------
# server_ip가 현재 호스트를 가리키는지 확인한다.
# 입력: server_ip
# 출력: return code
    local server_ip="$1"

    case "$server_ip" in
         ""|local|localhost|127.0.0.1) return 0
    esac

    grep -qw -- "$server_ip" <<< "$LOCAL_HOST_IPS"
}

run_git_io() {
#----------------------------------------------------------------------------------------------------------
# local/remote 공통으로 shell 명령을 실행한다.
# 입력: server_ip, command
# 출력: command stdout
    local server_ip="$1" cmd="$2"

    if is_local_server_ip "$server_ip"; then bash -lc "$cmd"
    else ssh "${SSH_OPTS[@]}" "$server_ip" "$cmd"
    fi
}

normalize_base_url() {
#----------------------------------------------------------------------------------------------------------
# Gerrit base URL을 https:// 기준으로 정규화한다.
# 입력: vgit host/path
# 출력: normalized base url
    local arg_url="$1"

    [[ "$arg_url" =~ ^https?:// ]] || arg_url="https://${arg_url}"
    echo "${arg_url%/}"
}

build_since_date() {
#----------------------------------------------------------------------------------------------------------
# 기간 문자열을 기준 시작일(UTC)로 변환한다.
# 입력: 365, 365d, 12m, 2025-01-01
# 출력: YYYY-MM-DD
    local arg_period="$1" num unit

    if   [[ "$arg_period" =~ ^[0-9]+$ ]];               then date -u -d "-${arg_period} days" +%F
    elif [[ "$arg_period" =~ ^([0-9]+)([dDwWmMyY])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
        case "$unit" in
             d) date -u -d "-${num} days" +%F
        ;;   w) date -u -d "-$((num * 7)) days" +%F
        ;;   m) date -u -d "-${num} months" +%F
        ;;   y) date -u -d "-${num} years" +%F
        esac
    elif [[ "$arg_period" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$arg_period"
    else echo "Invalid period: $arg_period" >&2;  return 1
    fi
}

build_file_regexp() {
#----------------------------------------------------------------------------------------------------------
# 확장자 목록을 grep용 regexp로 변환한다.
# 입력: .bb,.bbappend,.inc
# 출력: \.(bb|bbappend|inc)$
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

strip_gerrit_json_prefix() {
    sed '1s/^)]}'"'"'//'
}

fetch_patch_text() {
#----------------------------------------------------------------------------------------------------------
# Gerrit change의 current revision patch 전체를 가져온다.
# 입력: auth, base_url, change_num
# 출력: decoded patch text
    local arg_auth="$1" arg_base_url="$2" arg_change_num="$3" patch_b64=""

    patch_b64=$(curl_gerrit -u "$arg_auth" "${arg_base_url}/a/changes/${arg_change_num}/revisions/current/patch?download" 2>/dev/null || true)
    [[ -z "$patch_b64" ]] && return 1
    printf '%s' "$patch_b64" | tr -d '\r\n' | base64 -d 2>/dev/null
}

fetch_changed_files() {
#----------------------------------------------------------------------------------------------------------
# Gerrit change의 변경 파일 목록을 가져온다.
# 입력: auth, base_url, change_num
# 출력: files json
    local arg_auth="$1" arg_base_url="$2" arg_change_num="$3"

    curl_gerrit -u "$arg_auth" "${arg_base_url}/a/changes/${arg_change_num}/revisions/current/files/" 2>/dev/null | strip_gerrit_json_prefix
}

match_changed_files() {
#----------------------------------------------------------------------------------------------------------
# 변경 파일 목록 중 원하는 확장자가 있는지 확인한다.
# 입력: files_json, file_regexp
# 출력: return code
    local files_json="$1" file_regexp="$2"

    jq -r 'keys[]' <<< "$files_json" | grep -Ev '^/COMMIT_MSG$' | grep -Eq "$file_regexp"
}

build_git_name() {
#----------------------------------------------------------------------------------------------------------
# rootdir 기준 상대 git name을 계산한다.
# 입력: rootdir, repo_path
# 출력: . 또는 상대경로
    local rootdir="$1" repo_path="$2" root_norm="${rootdir%/}/" repo_norm="$repo_path"

    if   [[ "$repo_path" == "${rootdir%/}" ]]; then echo "."
    elif [[ "$repo_norm" == "$root_norm"* ]]; then echo "${repo_norm#${root_norm}}"
    else echo "$repo_path"
    fi
}

fetch_local_commit_summary() {
#----------------------------------------------------------------------------------------------------------
# local/remote git repo에서 commit 요약 1줄을 추출한다.
# 입력: server_ip, repo_path, commit_sha
# 출력: sha|committer|date|subject
    local server_ip="$1" repo_path="$2" commit_sha="$3" repo_q cmd

    repo_q=$(printf "%q" "$repo_path")
    cmd="git -C ${repo_q} log -1 --format='%H|%cn|%ci|%s' ${commit_sha}"
    run_git_io "$server_ip" "$cmd"
}

format_local_result_line() {
#----------------------------------------------------------------------------------------------------------
# local 검색 결과를 1줄 요약으로 출력한다.
# 입력: rootdir, repo_path, summary_line
# 출력: git=... commit=... committer=...
    local rootdir="$1" repo_path="$2" summary_line="$3"
    local git_name commit_id committer commit_date subject

    git_name=$(build_git_name "$rootdir" "$repo_path")
    commit_id=$(printf '%s' "$summary_line" | cut -d'|' -f1)
    committer=$(printf '%s' "$summary_line" | cut -d'|' -f2)
    commit_date=$(printf '%s' "$summary_line" | cut -d'|' -f3)
    subject=$(printf '%s' "$summary_line" | cut -d'|' -f4-)
    printf 'git=%s commit=%s committer=%s date="%s" subject="%s"\n' "$git_name" "${commit_id:0:8}" "$committer" "$commit_date" "$subject"
}

join_local_scan_path() {
#----------------------------------------------------------------------------------------------------------
# rootdir과 subpath를 합쳐 실제 검색 시작 경로를 계산한다.
# 입력: rootdir, subpath
# 출력: merged path
    local rootdir="$1" subpath="$2"

    subpath="${subpath#/}"
    [[ -z "$subpath" || "$subpath" == "." ]] && echo "$rootdir" || echo "${rootdir%/}/${subpath}"
}

find_local_git_projects() {
#----------------------------------------------------------------------------------------------------------
# .repo root 하위 특정 경로에서 모든 git project path를 찾는다.
# 입력: server_ip, rootdir, subpath
# 출력: repo path list
    local server_ip="$1" rootdir="$2" subpath="$3"
    local PATH_SCAN root_q scan_q cmd

    PATH_SCAN=$(join_local_scan_path "$rootdir" "$subpath")
    root_q=$(printf "%q" "$rootdir")
    scan_q=$(printf "%q" "$PATH_SCAN")
    cmd="[[ -d ${root_q}/.repo ]] || { echo 'Missing .repo under rootdir' >&2; exit 1; }; [[ -d ${scan_q} ]] || { echo 'Subpath not found under rootdir' >&2; exit 1; }; find ${scan_q} ${LOCAL_PRUNE_EXPR} -prune -o -name .git -print 2>/dev/null | sed 's|/\\.git$||' | sort -u"
    run_git_io "$server_ip" "$cmd"
}

search_gerrit_commits() {
#----------------------------------------------------------------------------------------------------------
# Gerrit merged history에서 변경 파일/patch regexp를 만족하는 change URL을 찾는다.
# 입력: auth, base_url, query, period, regexp, ext_list
# 출력: Gerrit change url
    local arg_auth="$1" arg_base_url="$2" arg_query="$3" arg_period="$4" arg_regexp="$5" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"
    local base_url since_date since_epoch query api_url start=0 page_size=100 page_json page_count more_changes=false
    local change_json change_num project submitted submitted_epoch patch_text commit_url files_json file_regexp

    base_url=$(normalize_base_url "$arg_base_url")
    since_date=$(build_since_date "$arg_period")
    since_epoch=$(date -u -d "$since_date 00:00:00" +%s)
    file_regexp=$(build_file_regexp "$arg_ext_list")
    query="$arg_query"
    [[ "$query" == *"status:merged"* ]] || query="${query} status:merged"
    [[ "$query" == *"after:"* ]] || query="${query} after:${since_date}"
    api_url="${base_url}/a/changes/"

    while :; do
        page_json=$(curl_gerrit -u "$arg_auth" --get "$api_url" --data-urlencode "q=${query}" --data "n=${page_size}" --data "S=${start}" | strip_gerrit_json_prefix)
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
            grep -Eq "$arg_regexp" <<< "$patch_text" || continue

            commit_url="${base_url}/c/${project}/+/${change_num}"
            echo "$commit_url"
        done < <(jq -c '.[]' <<< "$page_json")

        more_changes=$(jq -r '.[-1]._more_changes // false' <<< "$page_json")
        [[ "$more_changes" == "true" ]] || break
        start=$((start + page_count))
    done | awk '!seen[$0]++'
}

search_local_git_commits() {
#----------------------------------------------------------------------------------------------------------
# local/remote git history에서 git log -G 기반으로 regexp를 만족하는 commit을 찾는다.
# 입력: server_ip, rootdir, subpath, period, regexp, ext_list
# 출력: 1줄 commit summary
    local server_ip="$1" rootdir="$2" subpath="$3" arg_period="$4" arg_regexp="$5" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"
    local since_date file_regexp repo_path repo_q log_cmd commit_sha file_cmd summary_line regex_q

    since_date=$(build_since_date "$arg_period")
    file_regexp=$(build_file_regexp "$arg_ext_list")
    regex_q=$(printf "%q" "$arg_regexp")

    while IFS= read -r repo_path; do
        [[ -z "$repo_path" ]] && continue
        repo_q=$(printf "%q" "$repo_path")
        log_cmd="git -C ${repo_q} log -G ${regex_q} --since=$(printf %q \"${since_date}\") --format=%H --all"

        while IFS= read -r commit_sha; do
            [[ -z "$commit_sha" ]] && continue

            file_cmd="git -C ${repo_q} show --pretty='' --name-only ${commit_sha}"
            run_git_io "$server_ip" "$file_cmd" | grep -Eq "$file_regexp" || continue

            summary_line=$(fetch_local_commit_summary "$server_ip" "$repo_path" "$commit_sha" || true)
            [[ -z "$summary_line" ]] && continue
            format_local_result_line "$rootdir" "$repo_path" "$summary_line"
        done < <(run_git_io "$server_ip" "$log_cmd")
    done < <(find_local_git_projects "$server_ip" "$rootdir" "$subpath") | awk '!seen[$0]++'
}

main() {
#----------------------------------------------------------------------------------------------------------
# 첫 번째 파라미터 형태로 Gerrit/local 모드를 분기한다.
# 입력: CLI arguments
# 출력: 검색 결과 lines
    local arg1="${1:-}" arg2="${2:-}" arg3="${3:-}" arg_period="${4:-}" arg_regexp="${5:-}" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"

    [[ $# -ge 5 && $# -le 6 ]] || { usage; exit 1; }
    [[ -n "$arg_regexp" ]] || { echo "Fifth parameter regexp is required" >&2; exit 1; }

    require_commands
    if [[ "$arg1" == *:* ]]; then search_gerrit_commits "$arg1" "$arg2" "$arg3" "$arg_period" "$arg_regexp" "$arg_ext_list"
    else search_local_git_commits "$arg1" "$arg2" "$arg3" "$arg_period" "$arg_regexp" "$arg_ext_list"
    fi
}

main "$@"