#!/bin/bash
set -euo pipefail

# Gerrit 또는 local git history에서 특정 regexp를 만족하는 commit을 검색한다.
# Gerrit은 merged history를 검색하고, git project까지 지정이 가능하다. branch 지정도 가능하다. 
# Local은 git log -G history를 기반으로 검색하고, git project는 path로 지정이 가능하다. branch는 현재소스기준으로 가능하다.

readonly SSH_OPTS=(-n -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)
readonly DEFAULT_EXT_LIST='.bb,.bbappend,.bbclass,.inc,.conf'
readonly LOCAL_PRUNE_EXPR="\( -path '*/.repo/*' -o -path '*/build/*' -o -path '*/tmp/*' -o -path '*/tmp-*/*' -o -path '*/work/*' -o -path '*/work-*/*' -o -path '*/buildhistory/*' -o -path '*/_SYSROOT_FILES/*' -o -path '*/upload_images/*' \)"
readonly LOCAL_HOST_IPS="$(hostname -I 2>/dev/null || true)"

SUMMARY_MODE=""
SUMMARY_TARGET_ADDRESS=""
SUMMARY_ACCOUNT=""
SUMMARY_ROOT_PATH=""
SUMMARY_TARGET_INPUT=""
SUMMARY_TARGET_KIND=""
SUMMARY_RESOLVED_TARGET=""
SUMMARY_QUERY_INPUT=""
SUMMARY_EFFECTIVE_QUERY=""
SUMMARY_PERIOD_INPUT=""
SUMMARY_EFFECTIVE_PERIOD=""
SUMMARY_PERIOD_LOGIC=""
SUMMARY_REGEXP=""
SUMMARY_EXT_LIST=""
SUMMARY_RESULT_COUNT="0"
SUMMARY_RESULT_STATUS=""

usage() {
    echo "Gerrit : $0 <user:key> <vgit.lge.com/na> <query> <period> <regexp> [ext_list]" >&2
    echo "Local  : $0 <ssh_server_ip> <rootdir> <subpath|git_project> <period> <regexp> [ext_list]" >&2
    echo "Gerrit: $0 'vc.integrator:***' 'vgit.lge.com/na' 'status:merged' '365d' 'SRC_URI'" >&2
    echo "Gerrit Project: $0 'vc.integrator:***' 'https://vgit.lge.com/na/admin/repos/tiger/variant/target/tsu' 'status:merged' '365d' 'SRC_URI' '.bb,.bbappend,.bbclass,.inc,.conf'" >&2
    echo "Gerrit Project/Branch: $0 'vc.integrator:***' 'https://vgit.lge.com/na/admin/repos/tiger/variant/target/tsu' 'status:merged branch:main' '365d' 'SRC_URI' '.bb,.bbappend,.bbclass,.inc,.conf'" >&2
    echo "Local dir: $0 '10.159.30.66' '/path/to/root' '/path/to/subpath' '365d' 'SRC_URI([[:space:]]*:(append|prepend|remove))?[[:space:]]*(\?\?=|\?=|:=|\+=|=\+|\.=|=\.|=)' '.bb,.bbappend,.bbclass,.inc,.conf'" >&2
    echo "Local git: $0 '10.159.30.66' '/path/to/root' 'git/name' '365d' 'SRC_URI' '.bb,.bbappend,.bbclass,.inc,.conf'" >&2
    echo "" >&2
    echo "period format:" >&2
    echo "  Local : plain number (e.g. 365)  -> git log -365  (latest N commits per repo)" >&2
    echo "          1                         -> git log -1    (latest commit only)" >&2
    echo "          365d, 12m, 2y, 2025-01-01 -> --since= date filter" >&2
    echo "  Gerrit: 365, 365d, 12m, 2y, 2025-01-01 -> after: date filter (365 = 365 days)" >&2
}

require_commands() {
    command -v base64 >/dev/null 2>&1 || { echo "base64 not found" >&2; exit 1; }
    command -v curl   >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
    command -v jq     >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
    command -v ssh    >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }
}

format_display_ip() {
#----------------------------------------------------------------------------------------------------------
# Jenkins password masking을 피하기 위해 IPv4 각 octet을 3자리 폭으로 정렬한다.
# 입력: ipv4 or raw string
# 출력: spaced ipv4 or original string
    local input_value="$1" old_ifs="$IFS" octets=()

    [[ "$input_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$input_value"; return; }

    IFS='.' read -r -a octets <<< "$input_value"
    IFS="$old_ifs"
    [[ "${#octets[@]}" -eq 4 ]] || { echo "$input_value"; return; }

    printf '%3s.%3s.%3s.%3s\n' "${octets[0]}" "${octets[1]}" "${octets[2]}" "${octets[3]}"
}

format_summary_target_address() {
#----------------------------------------------------------------------------------------------------------
# summary의 AccountnIP 값을 mode에 맞게 정리한다.
# 입력: summary 전역 변수
# 출력: account 또는 spaced ipv4
    [[ "$SUMMARY_MODE" == "local" ]] && format_display_ip "$SUMMARY_TARGET_ADDRESS" || echo "$SUMMARY_TARGET_ADDRESS"
}

print_result_block() {
#----------------------------------------------------------------------------------------------------------
# 검색 결과 heading과 commit 목록 또는 no-match 메시지를 stdout으로 출력한다.
# 입력: result_file
# 출력: result heading + result lines
    local result_file="$1"

    echo "== result Commit list (${SUMMARY_MODE}) =="
    if [[ -s "$result_file" ]]; then cat "$result_file"
    else echo "No matched commits"
    fi
}

print_execution_summary() {
#----------------------------------------------------------------------------------------------------------
# 실제 동작 조건과 최종 결과를 stderr로 출력한다.
    local search_period display_target_address

    search_period=$(format_summary_period)
    display_target_address=$(format_summary_target_address)

    {
        echo 
        echo "== searchCommitCode summary =="
        echo "Mode=${SUMMARY_MODE}"

        if [[ "$SUMMARY_MODE" == "gerrit" ]]; then
            echo "AccountnIP(account)=${SUMMARY_ACCOUNT}"
            echo "URLnPATH(url)=${SUMMARY_TARGET_ADDRESS}"
            echo "AREAnSubPATH(area)=${SUMMARY_QUERY_INPUT}"
            echo "ResolvedTarget(query)=${SUMMARY_EFFECTIVE_QUERY}"
        else
            echo "AccountnIP(server_ip)=${display_target_address}"
            echo "URLnPATH(root_path)=${SUMMARY_ROOT_PATH}"
            echo "AREAnSubPATH(${SUMMARY_TARGET_KIND})=${SUMMARY_TARGET_INPUT}"
            echo "ResolvedTarget(path)=${SUMMARY_RESOLVED_TARGET}"
        fi

        echo "SEARCH_PERIOD=${search_period}"
        echo "RegExpQUERY=${SUMMARY_REGEXP}"
        echo "SEARCH_FILE=${SUMMARY_EXT_LIST}"
        echo "RESULT_COUNT=${SUMMARY_RESULT_COUNT}"
        echo "RESULT_STATUS=${SUMMARY_RESULT_STATUS}"
        echo "==============================="
    } >&2
}

format_summary_period() {
#----------------------------------------------------------------------------------------------------------
# summary용 검색 기간 문자열을 사람이 읽기 쉽게 정리한다.
# 입력: summary 전역 변수
# 출력: 3m(2026-02-26) 또는 24(latest 24 commits/repo)
    local period_detail=""

    case "$SUMMARY_PERIOD_LOGIC" in
         after:*|since:*) period_detail="${SUMMARY_PERIOD_LOGIC#*:}"
    ;;   git_log_depth:*)  period_detail="latest ${SUMMARY_PERIOD_LOGIC#*:} commits/repo"
    esac

    [[ -n "$period_detail" ]] && echo "${SUMMARY_EFFECTIVE_PERIOD}(${period_detail})" || echo "$SUMMARY_EFFECTIVE_PERIOD"
}

normalize_gerrit_period() {
#----------------------------------------------------------------------------------------------------------
# Gerrit 검색용 기간 문자열을 정규화한다.
# 입력: period
# 출력: normalized period
    local arg_period="$1"

    if [[ "$arg_period" =~ ^[0-9]+$ ]]; then echo "${arg_period}d"
    else echo "$arg_period"
    fi
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

should_use_gerrit_mode() {
#----------------------------------------------------------------------------------------------------------
# Jenkins job에서는 ACCOUNTnKEY가 항상 채워질 수 있으므로, 대상(arg2)이 local path면 local 모드로 보정한다.
# 입력: arg1, arg2
# 출력: return code (0: gerrit, 1: local)
    local arg1="$1" arg2="$2"

    [[ "$arg1" == *:* ]] || return 1

    case "$arg2" in
         /*) return 1
    esac

    return 0
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

parse_gerrit_target() {
#----------------------------------------------------------------------------------------------------------
# Gerrit 입력값에서 base URL과 optional project를 분리한다.
# 입력: vgit host/path 또는 .../admin/repos/<project>
# 출력: base_url|project
    local arg_target="$1" normalized base_url project=""

    normalized=$(normalize_base_url "$arg_target")

    if [[ "$normalized" =~ ^(https?://[^/]+(/[^/]+)*)/admin/repos/(.+)$ ]]; then
        base_url="${BASH_REMATCH[1]}"
        project="${BASH_REMATCH[3]}"
    else
        base_url="$normalized"
    fi

    printf '%s|%s\n' "$base_url" "$project"
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

fetch_gerrit_commit_summary() {
#----------------------------------------------------------------------------------------------------------
# Gerrit change의 current revision commit 요약을 가져온다.
# 입력: auth, base_url, change_num
# 출력: commit|author
    local arg_auth="$1" arg_base_url="$2" arg_change_num="$3"

    curl_gerrit -u "$arg_auth" "${arg_base_url}/a/changes/${arg_change_num}/revisions/current/commit" 2>/dev/null |
        strip_gerrit_json_prefix |
        jq -r '[.commit, (.author.email // "")] | join("|")'
}

patch_has_regexp_change() {
#----------------------------------------------------------------------------------------------------------
# Gerrit patch의 대상 파일 diff 변경 라인(+/-)에 regexp가 존재하는지 확인한다.
# 입력: patch_text, file_regexp, regexp
# 출력: return code
    local patch_text="$1" file_regexp="$2" arg_regexp="$3"
    local line path_old path_new match_file=0

    while IFS= read -r line; do
        if [[ "$line" == diff\ --git\ a/*\ b/* ]]; then
            path_old="${line#diff --git a/}"
            path_old="${path_old%% b/*}"
            path_new="${line##* b/}"
            [[ "$path_old" =~ $file_regexp || "$path_new" =~ $file_regexp ]] && match_file=1 || match_file=0
            continue
        fi

        if [[ "$match_file" -eq 1 && "$line" =~ ^[+-][^+-] ]]; then
            [[ "${line:1}" =~ $arg_regexp ]] && return 0
        fi
    done <<< "$patch_text"

    return 1
}

format_gerrit_result_line() {
#----------------------------------------------------------------------------------------------------------
# Gerrit 검색 결과를 1줄 요약으로 출력한다.
# 입력: commit_url, commit_summary
# 출력: url commit=... author=...
    local commit_url="$1" commit_summary="$2"
    local commit_id author_email

    IFS='|' read -r commit_id author_email <<< "$commit_summary"
    printf '%s commit=%s author=%s\n' "$commit_url" "${commit_id:0:8}" "$author_email"
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
# 출력: sha|author|date|subject
    local server_ip="$1" repo_path="$2" commit_sha="$3" repo_q cmd

    repo_q=$(printf "%q" "$repo_path")
    cmd="git -C ${repo_q} log -1 --format='%H|%ae|%ci|%s' ${commit_sha}"
    run_git_io "$server_ip" "$cmd"
}

format_local_result_line() {
#----------------------------------------------------------------------------------------------------------
# local 검색 결과를 1줄 요약으로 출력한다.
# 입력: rootdir, repo_path, summary_line
# 출력: git=... commit=... author=...
    local rootdir="$1" repo_path="$2" summary_line="$3"
    local git_name commit_id author_email commit_date subject

    git_name=$(build_git_name "$rootdir" "$repo_path")
    commit_id=$(printf '%s' "$summary_line" | cut -d'|' -f1)
    author_email=$(printf '%s' "$summary_line" | cut -d'|' -f2)
    commit_date=$(printf '%s' "$summary_line" | cut -d'|' -f3)
    subject=$(printf '%s' "$summary_line" | cut -d'|' -f4-)
    printf 'git=%s commit=%s author=%s date="%s" subject="%s"\n' "$git_name" "${commit_id:0:8}" "$author_email" "$commit_date" "$subject"
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

list_local_git_repo_paths() {
#----------------------------------------------------------------------------------------------------------
# rootdir 아래 실제 git repo path 목록을 반환한다.
# 입력: rootdir
# 출력: repo path list
    local rootdir="$1"

    find "$rootdir" \
        \( -path '*/.repo/*' -o -path '*/build/*' -o -path '*/tmp/*' -o -path '*/tmp-*/*' -o -path '*/work/*' -o -path '*/work-*/*' -o -path '*/buildhistory/*' -o -path '*/_SYSROOT_FILES/*' -o -path '*/upload_images/*' \) -prune -o \
        -name .git -print 2>/dev/null | sed 's|/\.git$||' | sort -u
}

resolve_local_scan_target() {
#----------------------------------------------------------------------------------------------------------
# local 검색 대상을 subpath 또는 git project name으로 해석한다.
# 입력: rootdir, subpath_or_project
# 출력: resolved path
    local rootdir="$1" subpath="$2" path_scan match_list match_count

    [[ -d "${rootdir%/}" ]] || { echo "Missing rootdir: ${rootdir}" >&2; return 1; }
    path_scan=$(join_local_scan_path "$rootdir" "$subpath")

    if [[ -d "$path_scan" ]]; then
        printf '%s\n' "$path_scan"
        return
    fi

    match_list=$(list_local_git_repo_paths "$rootdir" |
        sed 's|/\.git$||' |
        awk -v root="${rootdir%/}/" -v key="${subpath#/}" '
            {
                rel=$0
                sub("^" root, "", rel)
                base=rel
                sub(".*/", "", base)
                if (rel == key || base == key) print $0
            }
        ' |
        sort -u)

    match_count=$(printf '%s\n' "$match_list" | sed '/^$/d' | wc -l)
    if [[ "$match_count" -eq 1 ]]; then
        printf '%s\n' "$match_list"
    elif [[ "$match_count" -gt 1 ]]; then
        echo "Ambiguous git project name: ${subpath}" >&2
        printf '%s\n' "$match_list" >&2
        return 1
    else
        echo "Subpath or git project not found under rootdir: ${subpath}" >&2
        return 1
    fi
}

resolve_local_scan_target_info_local() {
#----------------------------------------------------------------------------------------------------------
# local 검색 대상을 subpath 또는 git project name으로 해석하고 종류를 함께 반환한다.
# 입력: rootdir, subpath_or_project
# 출력: target_kind|resolved_path
    local rootdir="$1" subpath="$2" path_scan match_list match_count

    [[ -d "${rootdir%/}" ]] || { echo "Missing rootdir: ${rootdir}" >&2; return 1; }
    path_scan=$(join_local_scan_path "$rootdir" "$subpath")

    if [[ -d "$path_scan" ]]; then
        printf 'subpath|%s\n' "$path_scan"
        return
    fi

    match_list=$(list_local_git_repo_paths "$rootdir" |
        awk -v root="${rootdir%/}/" -v key="${subpath#/}" '
            {
                rel=$0
                sub("^" root, "", rel)
                base=rel
                sub(".*/", "", base)
                if (rel == key || base == key) print $0
            }
        ' |
        sort -u)

    match_count=$(printf '%s\n' "$match_list" | sed '/^$/d' | wc -l)
    if [[ "$match_count" -eq 1 ]]; then
        printf 'git_project_name|%s\n' "$match_list"
    elif [[ "$match_count" -gt 1 ]]; then
        echo "Ambiguous git project name: ${subpath}" >&2
        printf '%s\n' "$match_list" >&2
        return 1
    else
        echo "Subpath or git project not found under rootdir: ${subpath}" >&2
        return 1
    fi
}

resolve_local_scan_target_info_remote() {
#----------------------------------------------------------------------------------------------------------
# remote server에서 local 검색 대상을 subpath 또는 git project name으로 해석한다.
# 입력: server_ip, rootdir, subpath_or_project
# 출력: target_kind|resolved_path
    local server_ip="$1" rootdir="$2" subpath="$3"

    ssh "${SSH_OPTS[@]}" "$server_ip" bash -s -- "$rootdir" "$subpath" <<'EOF'
set -euo pipefail

rootdir="$1"
subpath="$2"

list_git_repo_paths_remote() {
    local rootdir="$1"

    find "$rootdir" \
        \( -path '*/.repo/*' -o -path '*/build/*' -o -path '*/tmp/*' -o -path '*/tmp-*/*' -o -path '*/work/*' -o -path '*/work-*/*' -o -path '*/buildhistory/*' -o -path '*/_SYSROOT_FILES/*' -o -path '*/upload_images/*' \) -prune -o \
        -name .git -print 2>/dev/null | sed 's|/\.git$||' | sort -u
}

path_scan="$rootdir"
subpath="${subpath#/}"
[[ -n "$subpath" && "$subpath" != "." ]] && path_scan="${rootdir%/}/${subpath}"
[[ -d "${rootdir%/}/.repo" ]] || { echo "Missing .repo under rootdir" >&2; exit 1; }
[[ -d "${rootdir%/}" ]] || { echo "Missing rootdir: ${rootdir}" >&2; exit 1; }

if [[ -d "$path_scan" ]]; then
    printf 'subpath|%s\n' "$path_scan"
    exit 0
fi

match_list=$(list_git_repo_paths_remote "$rootdir" |
    awk -v root="${rootdir%/}/" -v key="${subpath}" '
        {
            rel=$0
            sub("^" root, "", rel)
            base=rel
            sub(".*/", "", base)
            if (rel == key || base == key) print $0
        }
    ' |
    sort -u)

match_count=$(printf '%s\n' "$match_list" | sed '/^$/d' | wc -l)
if [[ "$match_count" -eq 1 ]]; then
    printf 'git_project_name|%s\n' "$match_list"
elif [[ "$match_count" -gt 1 ]]; then
    echo "Ambiguous git project name: ${subpath}" >&2
    printf '%s\n' "$match_list" >&2
    exit 1
else
    echo "Subpath or git project not found under rootdir: ${subpath}" >&2
    exit 1
fi
EOF
}

resolve_local_scan_target_info() {
#----------------------------------------------------------------------------------------------------------
# local 검색 대상을 실행 위치에 맞게 해석한다.
# 입력: server_ip, rootdir, subpath_or_project
# 출력: target_kind|resolved_path
    local server_ip="$1" rootdir="$2" subpath="$3"

    if is_local_server_ip "$server_ip"; then resolve_local_scan_target_info_local "$rootdir" "$subpath"
    else resolve_local_scan_target_info_remote "$server_ip" "$rootdir" "$subpath"
    fi
}

find_local_git_projects() {
#----------------------------------------------------------------------------------------------------------
# .repo root 하위 특정 경로에서 모든 git project path를 찾는다.
# 입력: server_ip, rootdir, subpath
# 출력: repo path list
    local server_ip="$1" rootdir="$2" subpath="$3"
    local PATH_SCAN root_q scan_q cmd

    if is_local_server_ip "$server_ip"; then
        PATH_SCAN=$(resolve_local_scan_target "$rootdir" "$subpath") || return 1
        list_local_git_repo_paths "$PATH_SCAN"
        return
    fi

    PATH_SCAN=$(join_local_scan_path "$rootdir" "$subpath")
    root_q=$(printf "%q" "$rootdir")
    scan_q=$(printf "%q" "$PATH_SCAN")
    cmd="[[ -d ${root_q} ]] || { echo 'Missing rootdir: ${rootdir}' >&2; exit 1; }; [[ -d ${scan_q} ]] || { echo 'Subpath not found under rootdir' >&2; exit 1; }; find ${scan_q} ${LOCAL_PRUNE_EXPR} -prune -o -name .git -print 2>/dev/null | sed 's|/\\.git$||' | sort -u"
    run_git_io "$server_ip" "$cmd"
}

search_local_git_commits_remote() {
#----------------------------------------------------------------------------------------------------------
# remote server에서 local git search 전체를 1회 ssh 세션으로 처리한다.
# 입력: server_ip, rootdir, subpath, period, regexp, ext_list
# 출력: 1줄 commit summary
    local server_ip="$1" rootdir="$2" subpath="$3" arg_period="$4" arg_regexp="$5" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"

    ssh "${SSH_OPTS[@]}" "$server_ip" bash -s -- "$rootdir" "$subpath" "$arg_period" "$arg_regexp" "$arg_ext_list" <<'EOF'
set -euo pipefail

rootdir="$1"
subpath="$2"
arg_period="$3"
arg_regexp="$4"
arg_ext_list="$5"
build_since_date_remote() {
    local arg_period="$1" num unit

    if   [[ "$arg_period" =~ ^[0-9]+$ ]]; then date -u -d "-${arg_period} days" +%F
    elif [[ "$arg_period" =~ ^([0-9]+)([dDwWmMyY])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
        case "$unit" in
             d) date -u -d "-${num} days" +%F ;;
             w) date -u -d "-$((num * 7)) days" +%F ;;
             m) date -u -d "-${num} months" +%F ;;
             y) date -u -d "-${num} years" +%F ;;
        esac
    elif [[ "$arg_period" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$arg_period"
    else echo "Invalid period: $arg_period" >&2; return 1
    fi
}

build_file_regexp_remote() {
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

join_local_scan_path_remote() {
    local rootdir="$1" subpath="$2"

    subpath="${subpath#/}"
    [[ -z "$subpath" || "$subpath" == "." ]] && echo "$rootdir" || echo "${rootdir%/}/${subpath}"
}

build_git_name_remote() {
    local rootdir="$1" repo_path="$2" root_norm="${rootdir%/}/" repo_norm="$repo_path"

    if   [[ "$repo_path" == "${rootdir%/}" ]]; then echo "."
    elif [[ "$repo_norm" == "$root_norm"* ]]; then echo "${repo_norm#${root_norm}}"
    else echo "$repo_path"
    fi
}

list_git_repo_paths_remote() {
    local rootdir="$1"

    find "$rootdir" \
        \( -path '*/.repo/*' -o -path '*/build/*' -o -path '*/tmp/*' -o -path '*/tmp-*/*' -o -path '*/work/*' -o -path '*/work-*/*' -o -path '*/buildhistory/*' -o -path '*/_SYSROOT_FILES/*' -o -path '*/upload_images/*' \) -prune -o \
        -name .git -print 2>/dev/null | sed 's|/\.git$||' | sort -u
}

resolve_scan_target_remote() {
    local rootdir="$1" subpath="$2" path_scan match_list match_count

    [[ -d "${rootdir%/}" ]] || { echo "Missing rootdir: ${rootdir}" >&2; exit 1; }
    path_scan=$(join_local_scan_path_remote "$rootdir" "$subpath")

    if [[ -d "$path_scan" ]]; then
        printf '%s\n' "$path_scan"
        return
    fi

    match_list=$(list_git_repo_paths_remote "$rootdir" |
        sed 's|/\.git$||' |
        awk -v root="${rootdir%/}/" -v key="${subpath#/}" '
            {
                rel=$0
                sub("^" root, "", rel)
                base=rel
                sub(".*/", "", base)
                if (rel == key || base == key) print $0
            }
        ' |
        sort -u)

    match_count=$(printf '%s\n' "$match_list" | sed '/^$/d' | wc -l)
    if [[ "$match_count" -eq 1 ]]; then
        printf '%s\n' "$match_list"
    elif [[ "$match_count" -gt 1 ]]; then
        echo "Ambiguous git project name: ${subpath}" >&2
        printf '%s\n' "$match_list" >&2
        exit 1
    else
        echo "Subpath or git project not found under rootdir: ${subpath}" >&2
        exit 1
    fi
}

path_scan=$(resolve_scan_target_remote "$rootdir" "$subpath")

if [[ "$arg_period" =~ ^[0-9]+$ ]]; then
    period_opt=(-"${arg_period}")
else
    since_date=$(build_since_date_remote "$arg_period")
    period_opt=(--since="$since_date")
fi

file_regexp=$(build_file_regexp_remote "$arg_ext_list")

while IFS= read -r repo_path; do
    [[ -z "$repo_path" ]] && continue
    git_name=$(build_git_name_remote "$rootdir" "$repo_path")

    while IFS='|' read -r commit_id author_email commit_date subject; do
        [[ -n "$commit_id" ]] || continue
        git -C "$repo_path" show --pretty='' --name-only "$commit_id" | grep -Eq "$file_regexp" || continue
        printf 'git=%s commit=%s author=%s date="%s" subject="%s"\n' "$git_name" "${commit_id:0:8}" "$author_email" "$commit_date" "$subject"
    done < <(git -C "$repo_path" log -G "$arg_regexp" "${period_opt[@]}" --format='%H|%ae|%ci|%s' --all)
done < <(list_git_repo_paths_remote "$path_scan")
EOF
}

search_gerrit_commits() {
#----------------------------------------------------------------------------------------------------------
# Gerrit merged history에서 변경 파일/patch regexp를 만족하는 change URL을 찾는다.
# 입력: auth, base_url, query, period, regexp, ext_list
# 출력: Gerrit change url
    local arg_auth="$1" arg_base_url="$2" arg_query="$3" arg_period="$4" arg_regexp="$5" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"
    local target_info base_url project_filter since_date since_epoch query api_url start=0 page_size=100 page_json page_count more_changes=false normalized_period
    local change_json change_num project submitted submitted_epoch patch_text commit_url files_json file_regexp commit_summary

    target_info=$(parse_gerrit_target "$arg_base_url")
    base_url="${target_info%%|*}"
    project_filter="${target_info#*|}"
    normalized_period=$(normalize_gerrit_period "$arg_period")
    since_date=$(build_since_date "$normalized_period")
    since_epoch=$(date -u -d "$since_date 00:00:00" +%s)
    file_regexp=$(build_file_regexp "$arg_ext_list")
    query="$arg_query"
    [[ -z "$project_filter" || "$query" == *"project:${project_filter}"* ]] || query="${query} project:${project_filter}"
    [[ "$query" == *"status:merged"* ]] || query="${query} status:merged"
    [[ "$query" == *"after:"* ]] || query="${query} after:${since_date}"
    api_url="${base_url}/a/changes/"

    SUMMARY_MODE="gerrit"
    SUMMARY_TARGET_ADDRESS="$base_url"
    SUMMARY_ACCOUNT="${arg_auth%%:*}"
    SUMMARY_QUERY_INPUT="$arg_query"
    SUMMARY_EFFECTIVE_QUERY="$query"
    SUMMARY_PERIOD_INPUT="$arg_period"
    SUMMARY_EFFECTIVE_PERIOD="$normalized_period"
    SUMMARY_PERIOD_LOGIC="after:${since_date}"
    SUMMARY_REGEXP="$arg_regexp"
    SUMMARY_EXT_LIST="$arg_ext_list"

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
            patch_has_regexp_change "$patch_text" "$file_regexp" "$arg_regexp" || continue

            commit_url="${base_url}/c/${project}/+/${change_num}"
            commit_summary=$(fetch_gerrit_commit_summary "$arg_auth" "$base_url" "$change_num" || true)
            [[ -n "$commit_summary" ]] && format_gerrit_result_line "$commit_url" "$commit_summary"
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
#   period: 순수 숫자(예: 365) → git log -N (최근 N개 commit 제한)
#           날짜 형식(365d, 12m, 2025-01-01 등) → --since= 필터
# 출력: 1줄 commit summary
    local server_ip="$1" rootdir="$2" subpath="$3" arg_period="$4" arg_regexp="$5" arg_ext_list="${6:-$DEFAULT_EXT_LIST}"
    local file_regexp repo_path repo_q log_cmd commit_sha file_cmd summary_line regex_q target_info target_kind resolved_target
    local period_opt=""

    if [[ "$arg_period" =~ ^[0-9]+$ ]]; then
        # 순수 숫자: commit 개수 제한 (git log -N)
        period_opt="-${arg_period}"
        SUMMARY_PERIOD_LOGIC="git_log_depth:${arg_period}"
    else
        # 날짜/기간 형식: --since= 필터
        local since_date
        since_date=$(build_since_date "$arg_period")
        period_opt="--since=$(printf %q \"${since_date}\")"
        SUMMARY_PERIOD_LOGIC="since:${since_date}"
    fi

    SUMMARY_MODE="local"
    SUMMARY_TARGET_ADDRESS="$server_ip"
    SUMMARY_ROOT_PATH="$rootdir"
    SUMMARY_TARGET_INPUT="$subpath"
    SUMMARY_TARGET_KIND=""
    SUMMARY_RESOLVED_TARGET=""
    SUMMARY_PERIOD_INPUT="$arg_period"
    SUMMARY_EFFECTIVE_PERIOD="$arg_period"
    SUMMARY_QUERY_INPUT=""
    SUMMARY_EFFECTIVE_QUERY=""
    SUMMARY_REGEXP="$arg_regexp"
    SUMMARY_EXT_LIST="$arg_ext_list"

    target_info=$(resolve_local_scan_target_info "$server_ip" "$rootdir" "$subpath") || return 1
    target_kind="${target_info%%|*}"
    resolved_target="${target_info#*|}"
    SUMMARY_TARGET_KIND="$target_kind"
    SUMMARY_RESOLVED_TARGET="$resolved_target"

    file_regexp=$(build_file_regexp "$arg_ext_list")
    regex_q=$(printf "%q" "$arg_regexp")

    if ! is_local_server_ip "$server_ip"; then
        search_local_git_commits_remote "$server_ip" "$rootdir" "$subpath" "$arg_period" "$arg_regexp" "$arg_ext_list" | awk '!seen[$0]++'
        return
    fi

    while IFS= read -r repo_path; do
        [[ -z "$repo_path" ]] && continue
        repo_q=$(printf "%q" "$repo_path")
        log_cmd="git -C ${repo_q} log -G ${regex_q} ${period_opt} --format=%H --all"

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
    local result_file search_rc mode_server_ip

    [[ $# -ge 5 && $# -le 6 ]] || { usage; exit 1; }
    [[ -n "$arg_regexp" ]] || { echo "Fifth parameter regexp is required" >&2; exit 1; }

    require_commands
    result_file=$(mktemp)
    trap 'rm -f '"'"'${result_file}'"'"'' EXIT

    if should_use_gerrit_mode "$arg1" "$arg2"; then
        if search_gerrit_commits "$arg1" "$arg2" "$arg3" "$arg_period" "$arg_regexp" "$arg_ext_list" > "$result_file"; then search_rc=0
        else search_rc=$?
        fi
    else
        mode_server_ip="$arg1"
        [[ "$arg1" == *:* ]] && mode_server_ip="local"

        if search_local_git_commits "$mode_server_ip" "$arg2" "$arg3" "$arg_period" "$arg_regexp" "$arg_ext_list" > "$result_file"; then search_rc=0
        else search_rc=$?
        fi
    fi

    SUMMARY_RESULT_COUNT="$(wc -l < "$result_file")"
    if [[ "$search_rc" -eq 0 ]]; then
        if [[ "$SUMMARY_RESULT_COUNT" -gt 0 ]]; then SUMMARY_RESULT_STATUS="MATCHED"
        else SUMMARY_RESULT_STATUS="NO_MATCH"
        fi
    else
        SUMMARY_RESULT_STATUS="FAILED"
    fi

    print_result_block "$result_file"
    print_execution_summary
    [[ "$search_rc" -eq 0 ]]
}

main "$@"