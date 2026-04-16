#!/bin/bash
# Gerrit 원격 저장소에서 submittable 상태 커밋들을 조회하고 현재 manifest 기반 로컬 저장소로 병합
# 의존성 커밋은 [+] 패턴 파싱하여 재귀 탐색/그룹화하여 순차 병합, 실패 시 전체 그룹 롤백
#
# 사용법: source commit-apply.sh
#   get_commit [gerrit_query]
#   check_commit [gerrit_url]
#   apply_commit [candidate_list_file.txt]
#
# 환경변수: USER, TOKEN_VGIT, TOKEN_LAMP
# 출력파일: candidate_list_file.txt, out_mergelist, manifest_formatted.json

CANDIDATE_LIST_FILE="candidate_list_file.txt"
MERGE_RESULT_FILE="out_mergelist"
RET_NO_CHANGES=0

COLOR_GREEN="\033[92m\033[1m"
COLOR_RED="\033[91m\033[1m"
COLOR_YELLOW="\033[93m\033[1m"
COLOR_RESET="\033[0m"

line="---------------------------------------------------------------------------------------------------------------------------------"

bar() {
#----------------------------------------------------------------------------------------------------------
# 구분선과 함께 섹션 제목을 출력하는 헬퍼 함수
# 화면에 강조된 구분선 표시
# 입력: 섹션 제목 문자열 (선택)
# 출력: 색상이 적용된 구분선과 제목

    printf "\n\n\e[1;36m%s%s \e[0m\n" "${1:+[$1] }" "${line:(${1:+3} + ${#1})}"
}

get_commit_info() {
#----------------------------------------------------------------------------------------------------------
# Gerrit commit URL로부터 commit 정보를 JSON 형식으로 조회
# Gerrit API를 사용하여 변경 번호로 git 프로젝트명, 리비전, 다운로드 명령어 등 상세 정보 추출
# 입력: Gerrit commit URL
# 출력: commit info JSON
    local commit_url="$1"
    [[ -z "$commit_url" ]] && { echo "Error: commit URL required" >&2; return 1; }
    commit_url="$(echo -e "${commit_url}" | tr -d '\r\n ')"
    
    local change_number="${commit_url##*/}" base_url="${commit_url%%/c/*}"
    local auth_string="${USER}:${TOKEN_VGIT}"
    [[ "$commit_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"
    
    curl -fsSk -u "$auth_string" "${base_url}/a/changes/?q=${change_number}&o=CURRENT_REVISION&o=DOWNLOAD_COMMANDS&o=CURRENT_COMMIT&n=1" 2>/dev/null | sed '1d'
}

resolve_changeid_to_url() {
#----------------------------------------------------------------------------------------------------------
# 숫자 change ID를 lamp.lge.com Gerrit API로 조회하여 full URL 형식으로 변환
# 조회 성공 시 http://lamp.lge.com/review/c/{project}/+/{change_id} 형태의 URL 출력
# 입력: change ID (숫자)
# 출력: Gerrit full URL (실패 시 빈 문자열)

    local change_id="$1"
    [[ "$change_id" =~ ^[0-9]+$ ]] || return 1
    
    local api_result project_name
    api_result="$(curl -fsSk -u "${USER}:${TOKEN_LAMP}" "http://lamp.lge.com/review/a/changes/?q=${change_id}&n=1" 2>/dev/null | sed '1d')" || return 1
    project_name="$(echo "$api_result" | jq -r '.[0].project // empty' 2>/dev/null)"
    [[ -z "$project_name" ]] && return 1
    
    echo "http://lamp.lge.com/review/c/${project_name}/+/${change_id}"
}

get_relate_changes() {
#----------------------------------------------------------------------------------------------------------
# 커밋 메시지에서 줄처음의 [+] 패턴을 파싱하여 관련 의존성 커밋을 재귀적으로 탐색
# [+] 뒤에 full URL이 오는 경우와 쉼표/공백으로 구분된 change ID 숫자가 오는 경우를 모두 처리
# 입력: commit URL
# 출력: patch_buffer 배열에 의존성 커밋 추가 (전역 변수 기반 작동)

    local commit="$1" msg content url token
    msg="$(get_commit_info "${commit}" | jq -r '.[0].revisions[].commit.message' 2>/dev/null)" || return 0
    
    while IFS= read -r line; do
        [[ "$line" =~ ^\[+\][[:space:]]*(.*) ]] || continue
        content="${BASH_REMATCH[1]}"
        
        if [[ "$content" =~ ^https?:// ]]; then
            url="$content"
        else
            for token in ${content//,/ }; do
                token="${token//[[:space:]]/}"
                [[ "$token" =~ ^[0-9]+$ ]] || continue
                url="$(resolve_changeid_to_url "$token")"
                [[ -z "$url" ]] && { echo "[WARN] Failed to resolve change ID: $token" >&2; continue; }
                echo "[CHECK] Resolved ID $token -> $url" >&2
                [[ " ${patch_buffer[*]} " =~ " ${url} " ]] && continue
                patch_buffer+=("$url")
                get_relate_changes "$url"
            done
            continue
        fi
        
        [[ " ${patch_buffer[*]} " =~ " ${url} " ]] && continue
        echo "[CHECK] Found related change: $url" >&2
        patch_buffer+=("$url")
        get_relate_changes "$url"
    done <<< "$msg"
}

git_pull() {
#----------------------------------------------------------------------------------------------------------
# Gerrit commit 정보를 기반으로 해당 프로젝트의 git 디렉토리를 찾아 안전한 풀 명령을 실행
# divergent branches 충돌을 피하기 위해 pull.rebase=false 옵션 적용 (ff로 try 후 안되면 merge)
# 입력: Gerrit commit URL
# 출력: 성공 시 0, 실패 시 1 반환 (에러 메시지 stderr 출력)

    local commit_url="$1"
    [[ -z "$commit_url" ]] && { echo "Error: commit URL required" >&2; return 1; }
    commit_url="$(echo -e "${commit_url}" | tr -d '\r\n ')"
    
    local commit_info project_info project_name cmt_pull_cmd project_path safe_pull_cmd
    commit_info="$(get_commit_info "${commit_url}")" || { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Error: failed to fetch commit info" >&2; return 1; }
    project_info="$(echo "$commit_info" | jq -r '.[0] | "\(.project)|\(.revisions[].fetch.ssh.commands.Pull)"' 2>/dev/null)" || { echo "Error: failed to parse commit JSON" >&2; return 1; }
    
    project_name="${project_info%%|*}"
    cmt_pull_cmd="${project_info#*|}"
    [[ "$project_name" == "null" ]] && project_name=""
    
    project_path="$(repo list -r "$project_name" 2>/dev/null | grep -m1 ": $project_name" | cut -f1 -d':' | sed 's/[[:space:]]*$//')" || { echo "Error: project '$project_name' not found in manifest" >&2; return 1; }
    [[ -z "$project_path" || -z "$cmt_pull_cmd" ]] && { echo "Error: incomplete commit info" >&2; return 1; }
    
    safe_pull_cmd="${cmt_pull_cmd/git pull /git -c pull.rebase=false pull }"
    ( cd "$project_path" || return 1; eval "$safe_pull_cmd" ) || { echo "Error: failed to pull in $project_path" >&2; return 1; }
    echo "[OKAY] Successfully pulled commit to $project_path"
}

check_commit() {
#----------------------------------------------------------------------------------------------------------
# Gerrit URL 기반으로 커밋이 원격 서버에 존재하는지 확인 (repo 미사용)
# Query URL, Commit URL, 또는 숫자 ID 형태 모두 처리 가능
# 입력: Gerrit commit URL 또는 Query URL
# 출력: 존재하면 0 (true), 존재하지 않거나 에러 시 1 (false)

    [[ -z "$1" ]] && { echo "Error: You must provide a Gerrit commit URL or query URL" >&2; return 1; }
    local raw_input="$1" commit_url gerrit_query base_url auth_string raw_json api_result commit_count
    commit_url="$(echo -e "${raw_input}" | tr -d '\r\n ')"
    
    if   [[ "$commit_url" == *"/q/"* ]]; then gerrit_query="${commit_url#*/q/}"; gerrit_query="${gerrit_query//%25/%}"; base_url="${commit_url%%/q/*}"
    elif [[ "$commit_url" == *"/c/"* ]]; then gerrit_query="${commit_url##*/}"; base_url="${commit_url%%/c/*}"
    else gerrit_query="${commit_url##*/}"; base_url="$(echo "$commit_url" | grep -oP '^https?://[^/]+')"; [[ -z "$base_url" ]] && return 1
    fi
    
    auth_string="${USER}:${TOKEN_VGIT}"
    [[ "$commit_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"
    
    raw_json="$(curl -fsSk -u "$auth_string" "${base_url}/a/changes/?q=${gerrit_query}" 2>/dev/null)" || return 1
    api_result="$(echo "$raw_json" | sed '1d')"
    commit_count=$(echo "$api_result" | jq -r 'length // 0' 2>/dev/null)
    [[ "$commit_count" -gt 0 ]];  return $?
}

process_remote_commits() {
#----------------------------------------------------------------------------------------------------------
# 특정 remote URL에서 Gerrit 쿼리로 커밋을 조회하고 manifest의 프로젝트 목록과 매칭
# 매칭된 커밋은 CANDIDATE_LIST_FILE에 추가, 불일치 시 최대 10개까지 경고 출력
# 입력: remote_url, GERRIT_QUERY, project_names
# 출력: 매칭된 커밋 수와 상태 메시지 (stdout), CANDIDATE_LIST_FILE 파일 업데이트

    local remote_url="$1" GERRIT_QUERY="$2" project_names="$3"
    local auth_string all_commits commit_count matched sample_idx change_number project_name sample_manifest_match
    
    echo -ne "${COLOR_GREEN}[OKAY]${COLOR_RESET} Querying remote URL: $remote_url"
    
    auth_string="${USER}:${TOKEN_VGIT}"
    [[ "$remote_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"
    
    all_commits="$(curl -fsSk -u "$auth_string" "$remote_url/a/changes/?q=${GERRIT_QUERY}" 2>/dev/null | sed '1d')" || { echo -e " -> ${COLOR_YELLOW}[WARN]${COLOR_RESET} Failed"; return 1; }
    commit_count=$(echo "$all_commits" | jq -r 'length // 0' 2>/dev/null)
    [[ "$commit_count" -eq 0 ]] && { echo ""; return 0; }
    
    matched=0 sample_idx=0
    while IFS='|' read -r change_number project_name; do
        project_name="$(echo "$project_name" | tr -d '\r\n ')"
        if echo "$project_names" | grep -q "^${project_name}$"; then
            echo "$remote_url/c/${project_name}/+/$change_number" >>"$CANDIDATE_LIST_FILE"
            matched=$((matched + 1))
        else
            if [[ $sample_idx -lt 10 ]]; then
                [[ $sample_idx -eq 0 ]] && echo ""
                sample_manifest_match=$(echo "$project_names" | grep "$project_name" | head -1 || echo "NO_MATCH")
                echo -e "${COLOR_RED}[FAIL] Not matched in manifest: '${project_name}'${COLOR_RESET}"
                echo -e "${COLOR_RED}       (Closest Manifest was: '${sample_manifest_match}')${COLOR_RESET}"
                sample_idx=$((sample_idx + 1))
            fi
        fi
    done <<< "$(echo "$all_commits" | jq -r '.[] | "\(._number)|\(.project)"')"
    
    if [[ $matched -gt 0 ]]; then
        [[ $sample_idx -gt 0 ]] && echo -ne "${COLOR_GREEN}[OKAY]${COLOR_RESET} Querying remote URL: $remote_url"
        echo -e ": matched commits:${matched}"
    else
        [[ $sample_idx -eq 0 ]] && echo ""
    fi
}

get_commit() {
#----------------------------------------------------------------------------------------------------------
# 현재 manifest의 리뷰 원격 저장소(Gerrit)에서 submittable 상태의 모든 후보 커밋을 조회
# 목록을 CANDIDATE_LIST_FILE 파일에 기록 (병합 제외)
# 입력: gerrit_query - Gerrit API 쿼리 문자열 또는 웹 브라우저 검색 URL
# 출력: 성공 시 0, 변경 없음 시 RET_NO_CHANGES 반환

    [[ -z "$1" ]] && { echo "Error: You must provide a Gerrit query string as the first argument" >&2; return 1; }
    local raw_input="$1" GERRIT_QUERY="$raw_input"
    
    [[ "$raw_input" == *"/q/"* ]] && GERRIT_QUERY="${raw_input#*/q/}"
    GERRIT_QUERY="${GERRIT_QUERY//%25/%}"
    
    set +x
    local manifest_formatted="manifest_formatted.json"
    repo manifest --json -o $manifest_formatted
    
    local default_remote remote_list remote_count project_names total_commits
    default_remote="$(cat $manifest_formatted | jq .default.remote)"
    remote_list="$(cat $manifest_formatted | jq .remote)"
    remote_count=$(echo "$remote_list" | jq -r '.[] | select(.review != null) | .review' | sort -u | wc -l)
    
    bar "remote list: $remote_count"
    rm -rf "${CANDIDATE_LIST_FILE}" "${MERGE_RESULT_FILE}"
    
    project_names="$(cat $manifest_formatted | jq -r '.project | .[] | .name' | sed 's/\.git$//')"
    echo -e "${COLOR_GREEN} Total projects in manifest: $(echo "$project_names" | wc -l)"
    
    while read -r remote_url; do
        process_remote_commits "$remote_url" "$GERRIT_QUERY" "$project_names"
    done < <(echo "$remote_list" | jq -r '.[] | select(.review != null) | .review' | sort -u)
    
    [[ -f "$CANDIDATE_LIST_FILE" ]] && sort -u -o "$CANDIDATE_LIST_FILE" "$CANDIDATE_LIST_FILE"
    
    total_commits=0
    [[ -s "${CANDIDATE_LIST_FILE}" ]] && total_commits=$(grep -cve '^[[:space:]]*$' "${CANDIDATE_LIST_FILE}")
    
    bar "List Changes: $total_commits"
    if [[ -s "${CANDIDATE_LIST_FILE}" && "$total_commits" -gt 0 ]]; then
        cat "${CANDIDATE_LIST_FILE}"
    else
        echo "We have no changes"
        rm -f "${CANDIDATE_LIST_FILE}";  return "$RET_NO_CHANGES"
    fi
}

backup_project_head() {
#----------------------------------------------------------------------------------------------------------
# 커밋 적용 전 프로젝트의 현재 HEAD를 백업하여 롤백 시 사용
# 동일 프로젝트에 여러 커밋이 들어갈 경우 최초 HEAD만 저장
# 입력: commit_url
# 출력: applied_paths, applied_heads 배열 업데이트 (전역 변수)

    local commit_url="$1" c_info p_name p_path p_head
    c_info=$(get_commit_info "${commit_url}") || return 0
    p_name=$(echo "$c_info" | jq -r '.[0].project' 2>/dev/null)
    [[ -z "$p_name" || "$p_name" == "null" ]] && return 0
    
    p_path=$(repo list -r "$p_name" 2>/dev/null | grep -m1 ": $p_name" | cut -f1 -d':' | sed 's/[[:space:]]*$//')
    [[ -z "$p_path" || ! -d "$p_path" ]] && return 0
    
    p_head=$(git -C "$p_path" rev-parse HEAD 2>/dev/null) || return 0
    
    local already_saved="False" ap
    for ap in "${applied_paths[@]}"; do
        [[ "$ap" == "$p_path" ]] && already_saved="True"
    done
    [[ "$already_saved" == "False" ]] && { applied_paths+=("$p_path"); applied_heads+=("$p_head"); }
}

rollback_group() {
#----------------------------------------------------------------------------------------------------------
# 그룹 내 커밋 적용 실패 시 백업된 HEAD로 모든 프로젝트를 롤백
# merge 중단 후 hard reset으로 원상 복구
# 입력: 없음 (applied_paths, applied_heads 전역 변수 사용)
# 출력: 없음 (git 상태 변경)

    local i r_path r_head
    for (( i=0; i<${#applied_paths[@]}; i++ )); do
        r_path="${applied_paths[$i]}"
        r_head="${applied_heads[$i]}"
        git -C "$r_path" merge --abort >/dev/null 2>&1 || true
        git -C "$r_path" reset --hard "$r_head" >/dev/null 2>&1 || true
    done
}

record_results() {
#----------------------------------------------------------------------------------------------------------
# 커밋 그룹의 병합 결과를 MERGE_RESULT_FILE에 기록
# OKAY/FAIL/BACK 상태와 함께 실패 사유를 함께 기록
# 입력: seq_str, group_has_error, fail_reason
# 출력: MERGE_RESULT_FILE 파일 업데이트, success_count/fail_count 증가

    local seq_str="$1" group_has_error="$2" fail_reason="$3"
    local i c s
    
    if [[ "$group_has_error" == "True" ]]; then
        for (( i=0; i<${#patch_buffer[@]}; i++ )); do
            c="${patch_buffer[$i]}"
            s="${commit_statuses[$i]}"
            if   [[ "$s" == "OKAY" ]]; then echo "${seq_str}| BACK| ${c} | Rolled back due to related dependency failure" >> "${MERGE_RESULT_FILE}"; fail_count=$((fail_count + 1))
            elif [[ "$s" == "FAIL" ]]; then echo "${seq_str}| FAIL| ${c} | ${fail_reason}" >> "${MERGE_RESULT_FILE}"; fail_count=$((fail_count + 1))
            else echo "${seq_str}| FAIL| ${c} | Skipped due to previous dependency failure" >> "${MERGE_RESULT_FILE}"; fail_count=$((fail_count + 1))
            fi
        done
    else
        for (( i=0; i<${#patch_buffer[@]}; i++ )); do
            c="${patch_buffer[$i]}"
            echo "${seq_str}| OKAY| ${c}" >> "${MERGE_RESULT_FILE}"
            success_count=$((success_count + 1))
        done
    fi
}

apply_commit() {
#----------------------------------------------------------------------------------------------------------
# get_commit으로 추출된 후보 커밋 목록을 로컬 프로젝트로 병합
# 의존성이 있는 경우 재귀 탐색으로 관련 커밋들을 그룹화하여 순차 병합, 하나라도 실패하면 전체 그룹 롤백
# 입력: list_file - 후보 커밋 목록 파일 경로 (기본값: CANDIDATE_LIST_FILE)
# 출력: 병합 결과를 MERGE_RESULT_FILE에 기록, 성공 시 0 반환

    local list_file="${1:-$CANDIDATE_LIST_FILE}"
    [[ ! -s "${list_file}" ]] && { echo "No candidate list file found: ${list_file}"; return "$RET_NO_CHANGES"; }
    
    local total_commits change commit_seq seq_str group_has_error fail_reason error_output pull_result commit_to_apply
    total_commits=$(grep -cve '^[[:space:]]*$' "${list_file}")
    bar "Merge commit"
    
    success_count=0 fail_count=0 commit_seq=0
    declare -A global_seen_commits
    
    while IFS= read -r change; do
        [[ -z "$change" || -n "${global_seen_commits[$change]}" ]] && continue
        
        patch_buffer=("${change}")
        get_relate_changes "${change}"
        
        for c in "${patch_buffer[@]}"; do
            global_seen_commits["$c"]="1"
        done
        
        commit_seq=$((commit_seq + 1))
        seq_str=$(printf "%04d" "$commit_seq")
        group_has_error="False" fail_reason=""
        applied_paths=() applied_heads=() commit_statuses=()
        
        for commit_to_apply in "${patch_buffer[@]}"; do
            backup_project_head "${commit_to_apply}"
            
            error_output=$(git_pull "${commit_to_apply}" 2>&1)
            pull_result=$?
            
            if [[ $pull_result -ne 0 ]]; then
                group_has_error="True"
                fail_reason=$(echo "$error_output" | grep -iE 'fatal:|error:|conflict' | head -1)
                [[ -z "$fail_reason" ]] && fail_reason=$(echo "$error_output" | grep -oP 'Error: \K.*' | head -1)
                [[ -z "$fail_reason" ]] && fail_reason="unknown error"
                fail_reason=$(echo "$fail_reason" | tr -s ' \t' ' ' | tr -d '\r\n')
                commit_statuses+=("FAIL")
                printf "[%04d]%b[FAIL]%b %s - %s\n" "$commit_seq" "${COLOR_RED}" "${COLOR_RESET}" "${commit_to_apply}" "${fail_reason}"
                break
            else
                commit_statuses+=("OKAY")
                printf "[%04d]%b[OKAY]%b %s\n" "$commit_seq" "${COLOR_GREEN}" "${COLOR_RESET}" "${commit_to_apply}"
            fi
        done
        
        [[ "$group_has_error" == "True" ]] && rollback_group
        record_results "$seq_str" "$group_has_error" "$fail_reason"
    done < "${list_file}"
    
    echo "${total_commits} = ${success_count} + ${fail_count}" >> "${MERGE_RESULT_FILE}"
    sort -r "${MERGE_RESULT_FILE}" -o "${MERGE_RESULT_FILE}"
    set -x
}
