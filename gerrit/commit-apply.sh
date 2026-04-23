#!/bin/bash
# Gerrit 원격 저장소에서 submittable 상태 커밋들을 조회하고 현재 manifest 기반 로컬 저장소로 병합
# 의존성 커밋은 [+] 패턴 파싱하여 재귀 탐색/그룹화하여 순차 병합, 실패 시 전체 그룹 롤백
#
# 사용법: source commit-apply.sh
#   get_commit [gerrit_query]
#   check_commit [gerrit_url]
#   apply_commit [commit_candidate.txt]
#
# 환경변수: USER, TOKEN_VGIT, TOKEN_LAMP
# 출력파일: commit_candidate.txt, out_mergelist, manifest_formatted.json

COMMIT_CANDIDATE="commit_candidate.txt"
COMMIT_RESULT="commit_report.txt"
COMMIT_CANCELED="commit_canceled.txt"
COMMIT_MERGED="commit_merged.txt"

RET_NO_CHANGES=0
COLOR_GREEN="\033[92m\033[1m"
COLOR_RED="\033[91m\033[1m"
COLOR_YELLOW="\033[93m\033[1m"
COLOR_RESET="\033[0m"


if [[ -z "$TOKEN_VGIT" || -z "$TOKEN_LAMP" ]]; then
    echo "Error: You must set TOKEN_VGIT, and TOKEN_LAMP environment variables"
    exit 1
fi

line="---------------------------------------------------------------------------------------------------------------------------------"
bar() { printf "\n\n\e[1;36m%s%s \e[0m\n" "${1:+[$1] }" "${line:(${1:+3} + ${#1})}"; }

get_commit_info() {
#----------------------------------------------------------------------------------------------------------
# Gerrit commit URL로부터 commit 정보를 JSON 형식으로 조회
# Gerrit API를 사용하여 변경 번호로 git 프로젝트명, 리비전, 다운로드 명령어 등 상세 정보 추출
# 입력: Gerrit commit URL
# 출력: commit info JSON
    local commit_url="$1"
    # 입력 URL 유효성을 먼저 검증
    [[ -z "$commit_url" ]] && { echo "Error: commit URL required" >&2; return 1; }
    commit_url="$(echo -e "${commit_url}" | tr -d '\r\n ')"

    # URL에서 change 번호와 base URL을 분리
    local change_number="${commit_url##*/}" base_url="${commit_url%%/c/*}"
    local auth_string="${USER}:${TOKEN_VGIT}"
    # 도메인에 따라 인증 토큰을 선택
    [[ "$commit_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"
    
    # Gerrit API 호출 후 JSON 가드라인 제거
    curl -fsSk -u "$auth_string" "${base_url}/a/changes/?q=${change_number}&o=CURRENT_REVISION&o=DOWNLOAD_COMMANDS&o=CURRENT_COMMIT&n=1" 2>/dev/null | sed '1d'
}


change_changeid_to_url() {
#----------------------------------------------------------------------------------------------------------
# 숫자 change ID를 lamp.lge.com Gerrit API로 조회하여 full URL 형식으로 변환
# 조회 성공 시 http://lamp.lge.com/review/c/{project}/+/{change_id} 형태의 URL 출력
# 입력: change ID (숫자)
# 출력: Gerrit full URL (실패 시 빈 문자열)

    local change_id="$1"
    # change ID는 숫자만 허용
    [[ "$change_id" =~ ^[0-9]+$ ]] || return 1
    
    # ID 조회 후 project명을 추출
    local api_result project_name
    api_result="$(curl -fsSk -u "${USER}:${TOKEN_LAMP}" "http://lamp.lge.com/review/a/changes/?q=${change_id}&n=1" 2>/dev/null | sed '1d')" || return 1
    project_name="$(echo "$api_result" | jq -r '.[0].project // empty' 2>/dev/null)"
    # project가 없으면 URL 생성 불가
    [[ -z "$project_name" ]] && return 1

    # Gerrit 웹 URL 형태로 반환
    echo "http://lamp.lge.com/review/c/${project_name}/+/${change_id}"
}


get_relate_changes() {
#----------------------------------------------------------------------------------------------------------
# 커밋 메시지에서 줄처음의 [+] 패턴을 파싱하여 관련 의존성 커밋을 재귀적으로 탐색
# [+] 뒤에 full URL이 오는 경우와 쉼표/공백으로 구분된 change ID 숫자가 오는 경우를 모두 처리
# 입력: commit URL
# 출력: patch_buffer 배열에 의존성 커밋 추가 (전역 변수 기반 작동)
    local commit="$1" msg content url token
    # 커밋 메시지에서 의존성 힌트 라인을 읽어옴
    msg="$(get_commit_info "${commit}" | jq -r '.[0].revisions[].commit.message' 2>/dev/null)" || return 0
    
    # 각 라인에서 [+] 접두 패턴만 처리
    while IFS= read -r line; do
        [[ "$line" =~ ^\[[+]\][[:space:]]*(.*) ]] || continue
        content="${BASH_REMATCH[1]}"
        
        # [+] 뒤가 URL이면 바로 사용
        if [[ "$content" =~ ^https?:// ]]; then url="$content"
        else
            # 숫자 ID 목록이면 URL로 변환 후 재귀 확장
            for token in ${content//,/ }; do
                token="${token//[[:space:]]/}"
                [[ "$token" =~ ^[0-9]+$ ]] || continue
                url="$(change_changeid_to_url "$token")"
                [[ -z "$url" ]] && { echo "[WARN] Failed to resolve change ID: $token" >&2; continue; }
                echo "[CHECK] Resolved ID $token -> $url" >&2
                # 중복 의존성은 건너뛰고 신규만 재귀 처리
                [[ " ${patch_buffer[*]} " =~ " ${url} " ]] && continue
                patch_buffer+=("$url")
                get_relate_changes "$url"
            done
            continue
        fi
        
        # URL 케이스도 중복 제외 후 재귀 처리
        [[ " ${patch_buffer[*]} " =~ " ${url} " ]] && continue
        local parent_change="${commit##*/}"
        echo "[ADD] related change from $parent_change: $url" >&2
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
    # 커밋 URL 필수 입력 확인
    [[ -z "$commit_url" ]] && { echo "Error: commit URL required" >&2; return 1; }
    commit_url="$(echo -e "${commit_url}" | tr -d '\r\n ')"
    
    # 커밋 메타정보를 조회하고 pull 명령을 추출
    local commit_info project_info project_name cmt_pull_cmd project_path safe_pull_cmd
    commit_info="$(get_commit_info "${commit_url}")" || { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Error: failed to fetch commit info" >&2; return 1; }
    project_info="$(echo "$commit_info" | jq -r '.[0] | "\(.project)|\(.revisions[].fetch.ssh.commands.Pull)"' 2>/dev/null)" || { echo "Error: failed to parse commit JSON" >&2; return 1; }

    #git name과 pull명령 추출
    project_name="${project_info%%|*}"
    cmt_pull_cmd="${project_info#*|}"
    [[ "$project_name" == "null" ]] && project_name=""
    project_path="$(repo list -p -r "$project_name" 2>/dev/null | head -1)"
    [[ -z "$project_path" ]] && { echo "Error: project '$project_name' not found in manifest" >&2; return 1; }
    [[ -z "$cmt_pull_cmd" ]] && { echo "Error: incomplete commit info" >&2; return 1; }
    
    # 해당 path로 진입하여 git pull 진행(rebase 충돌을 줄이기 위해 안전하게 pull.rebase=false 옵션 적용)
    safe_pull_cmd="${cmt_pull_cmd/git pull /git -c pull.rebase=false pull }"
    ( cd "$project_path" || return 1; eval "$safe_pull_cmd" ) || { echo "Error: failed to pull in $project_path" >&2; return 1; }
    echo "[OKAY] Successfully pulled commit to $project_path"
}


check_commit() {
#----------------------------------------------------------------------------------------------------------
# 단순히 입력한 Gerrit URL에 대해서 gerrit에 commit이 존재하는지 확인 (repo 미사용, 단순 error check및 실행여부 확인용)
# Query URL, Commit URL, 또는 숫자 ID 형태 모두 처리 가능
# 입력: Gerrit commit URL 또는 Query URL
# 출력: 존재하면 0 (true), 존재하지 않거나 에러 시 1 (false)

    [[ -z "$1" ]] && { echo "Error: You must provide a Gerrit commit URL or query URL" >&2; return 1; }
    local raw_input="$1" commit_url gerrit_query base_url auth_string raw_json commit_count
    # 입력 문자열의 공백/개행을 제거
    commit_url="$(echo -e "${raw_input}" | tr -d '\r\n ')"
    
    # URL 형태에 맞게 query와 base URL을 분리
    if   [[ "$commit_url" == *"/q/"* ]]; then gerrit_query="${commit_url#*/q/}"; gerrit_query="${gerrit_query//%25/%}"; base_url="${commit_url%%/q/*}"
    elif [[ "$commit_url" == *"/c/"* ]]; then gerrit_query="${commit_url##*/}"; base_url="${commit_url%%/c/*}"
    else gerrit_query="${commit_url##*/}"; base_url="$(echo "$commit_url" | grep -oP '^https?://[^/]+')"; [[ -z "$base_url" ]] && return 1
    fi
    
    # 도메인별 인증 계정을 선택
    auth_string="${USER}:${TOKEN_VGIT}"
    [[ "$commit_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"
    
    # 조회 결과 길이로 존재 여부를 판단
    raw_json="$(curl -fsSk -u "$auth_string" "${base_url}/a/changes/?q=${gerrit_query}" 2>/dev/null | sed '1d')" || return 1
    commit_count=$(echo "$raw_json" | jq -r 'length // 0' 2>/dev/null)
    [[ "$commit_count" -gt 0 ]];  return $?
}


process_remote_commits() {
#----------------------------------------------------------------------------------------------------------
# 특정 remote에 대해 Gerrit 쿼리로 커밋을 조회하고 manifest의 프로젝트 목록에 포함된 commit 들을 COMMIT_CANDIDATE에 추가, 
# 불일치 시 최대 10개까지 경고 출력하고 COMMIT_CANDIDATE에서는 제외함
# 입력: remote_url, GERRIT_QUERY, project_names
# 출력: 매칭된 커밋 수와 상태 메시지 (stdout), COMMIT_CANDIDATE 파일 업데이트
    local remote_url="$1" GERRIT_QUERY="$2" project_names="$3"
    local auth_string all_commits commit_count matched sample_idx change_number project_name sample_manifest_match
    
    # 현재 원격 조회 시작 메시지 출력
    echo -ne "${COLOR_GREEN}[OKAY]${COLOR_RESET} Querying remote URL: $remote_url"
    
    # 원격 도메인에 맞는 인증 토큰 선택
    auth_string="${USER}:${TOKEN_VGIT}"
    [[ "$remote_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"
    
    # Gerrit 쿼리 실행 후 결과 개수를 확인
    all_commits="$(curl -fsSk -u "$auth_string" "$remote_url/a/changes/?q=${GERRIT_QUERY}" 2>/dev/null | sed '1d')" || { echo -e " -> ${COLOR_YELLOW}[WARN]${COLOR_RESET} Failed"; return 1; }
    commit_count=$(echo "$all_commits" | jq -r 'length // 0' 2>/dev/null)
    [[ "$commit_count" -eq 0 ]] && { echo ""; return 0; }
    
    # 원격 커밋을 순회하면서 manifest 프로젝트와 매칭
    matched=0 sample_idx=0
    while IFS='|' read -r change_number project_name; do
        project_name="$(echo "$project_name" | tr -d '\r\n ')"
        # 완전 일치하는 프로젝트만 후보 목록에 추가
        if echo "$project_names" | grep -q "^${project_name}$"; then
            echo "$remote_url/c/${project_name}/+/$change_number" >>"$COMMIT_CANDIDATE"
            matched=$((matched + 1))
        else
            # 매칭 실패는 최대 10건까지만 샘플 경고 출력, 실패된 commit들은 COMMIT_CANDIDATE 파일에 포함되지 않음
            if [[ $sample_idx -lt 10 ]]; then
                [[ $sample_idx -eq 0 ]] && echo ""
                sample_manifest_match=$(echo "$project_names" | grep "$project_name" | head -1 || echo "NO_MATCH")
                echo -e "${COLOR_RED}[FAIL] Not matched in manifest: '${project_name}'${COLOR_RESET}"
                echo -e "${COLOR_RED}       (Closest Manifest was: '${sample_manifest_match}')${COLOR_RESET}"
                sample_idx=$((sample_idx + 1))
            fi
        fi
    done <<< "$(echo "$all_commits" | jq -r '.[] | "\(._number)|\(.project)"')"
    
    # 매칭 통계 요약을 출력
    if [[ $matched -gt 0 ]]; then
        [[ $sample_idx -gt 0 ]] && echo -ne "${COLOR_GREEN}[OKAY]${COLOR_RESET} Querying remote URL: $remote_url"
        echo -e ": matched commits:${matched}"
    fi
}


get_commit() {
#----------------------------------------------------------------------------------------------------------
# 현재 manifest의 리뷰 원격 저장소(Gerrit)에서 query구문으로 조회된 commit들만 추출하여 COMMIT_CANDIDATE 파일에 모두 기록
# 입력: gerrit_query - Gerrit API 쿼리 문자열 또는 웹 브라우저 검색 URL
# 출력: 성공 시 commit갯수 반환및 commit파일 출력, 없는경우 We have no changes출력및 0 return

    [[ -z "$1" ]] && { echo "Error: You must provide a Gerrit query string as the first argument" >&2; return 1; }
    local raw_input="$1" GERRIT_QUERY="$raw_input"
    
    # 웹 URL 입력이면 /q/ 이후를 query로 변환
    [[ "$raw_input" == *"/q/"* ]] && GERRIT_QUERY="${raw_input#*/q/}"
    GERRIT_QUERY="${GERRIT_QUERY//%25/%}"
    
    # 현재 dir로 git pull하기전, repo 초기화가 제대로 되어 있는 상태인지 먼저 확인
    [[ ! -d ".repo" ]] && { echo "Error: repo not initialized. Run 'repo init' first" >&2; return 1; }
    
    # 원격 목록과 프로젝트 목록을 manifest에서 추출
    local default_remote remote_list remote_count project_names total_commits manifest_formatted="manifest_formatted.json"
    repo manifest --json -o "$manifest_formatted" || { echo "Error: failed to generate manifest JSON" >&2; return 1; }

    default_remote="$(jq .default.remote "$manifest_formatted")"
    remote_list="$(jq .remote "$manifest_formatted")"
    remote_count=$(echo "$remote_list" | jq -r '.[] | select(.review != null) | .review' | sort -u | wc -l)
    
    # 실제 commit을 가져오기전에 기존파일삭제
    rm -rf "${COMMIT_CANDIDATE}" 


    # 추출한 remote와 갯수를 출력하고, manifest를 파싱하여 전체 git갯수 출력
    bar "remote list: $remote_count"    
    project_names="$(jq -r '.project | .[] | .name' "$manifest_formatted" | sed 's/\.git$//')"
    echo -e "${COLOR_GREEN} Total projects in manifest: $(echo "$project_names" | wc -l)"
    
    # remote별로 gerrit에서 실제처리할 commit들을 COMMIT_CANDIDATE에 저장
    while read -r remote_url; do
        process_remote_commits "$remote_url" "$GERRIT_QUERY" "$project_names"
    done < <(echo "$remote_list" | jq -r '.[] | select(.review != null) | .review' | sort -u)
    
    # 추출한 commit에서 중복제거후 갯수 카운트
    total_commits=0
    [[ -f "$COMMIT_CANDIDATE" ]] && sort -u -o "$COMMIT_CANDIDATE" "$COMMIT_CANDIDATE"
    [[ -s "${COMMIT_CANDIDATE}" ]] && total_commits=$(grep -cve '^[[:space:]]*$' "${COMMIT_CANDIDATE}" 2>/dev/null)
    
    # 최종 후보가 없으면 no chanage 출력, 있으면 그 갯수를 return
    bar "List Changes: $total_commits"
    if [[ -s "${COMMIT_CANDIDATE}" && "$total_commits" -gt 0 ]]; then
        cat "${COMMIT_CANDIDATE}"
        echo "Total commits: $total_commits"
        # Bash return 범위(0~255)를 넘어가면 최대값으로 제한
        [[ "$total_commits" -gt 255 ]] && return 255 || return "$total_commits"
    else
        echo "We have no changes"
        rm -f "${COMMIT_CANDIDATE}";  return 0
    fi
}


backup_project_head() {
#----------------------------------------------------------------------------------------------------------
# 커밋 적용 전 프로젝트의 현재 HEAD를 백업하여 롤백 시 사용
# 동일 프로젝트에 여러 커밋이 들어갈 경우 최초 HEAD만 저장
# 입력: commit_url
# 출력: applied_paths, applied_heads 배열 업데이트 (전역 변수)

    local commit_url="$1" c_info p_name p_path p_head
    # 커밋으로부터 대상 프로젝트를 조회
    c_info=$(get_commit_info "${commit_url}") || return 0
    p_name=$(echo "$c_info" | jq -r '.[0].project' 2>/dev/null)
    [[ -z "$p_name" || "$p_name" == "null" ]] && return 0
    
    # manifest 기준 로컬 경로와 현재 HEAD를 확보
    p_path=$(repo list -p -r "$p_name" 2>/dev/null | head -1)
    [[ -z "$p_path" || ! -d "$p_path" ]] && return 0
    
    p_head=$(git -C "$p_path" rev-parse HEAD 2>/dev/null) || return 0
    
    # 동일 프로젝트는 최초 1회만 백업 저장
    [[ ! " ${applied_paths[*]} " =~ " ${p_path} " ]] && { applied_paths+=("$p_path"); applied_heads+=("$p_head"); }
}


rollback_group() {
#----------------------------------------------------------------------------------------------------------
# 그룹 내 커밋 적용 실패 시 백업된 HEAD로 모든 프로젝트를 롤백
# merge 중단 후 hard reset으로 원상 복구
# 입력: 없음 (applied_paths, applied_heads 전역 변수 사용)
# 출력: 없음 (git 상태 변경)
    local i r_path r_head
    # 그룹 내 프로젝트를 백업 HEAD로 순차 복구
    for (( i=0; i<${#applied_paths[@]}; i++ )); do
        r_path="${applied_paths[$i]}"
        r_head="${applied_heads[$i]}"
        # 진행 중인 merge 중단 후 강제 원복
        git -C "$r_path" merge --abort >/dev/null 2>&1 || true
        git -C "$r_path" reset --hard "$r_head" >/dev/null 2>&1 || true
    done
}


record_results() {
#----------------------------------------------------------------------------------------------------------
# 커밋 그룹의 병합 결과를 파일에 기록
# 성공한 커밋은 COMMIT_MERGED에, 실패/롤백은 COMMIT_CANCELED에 기록
# OKAY/FAIL 상태와 함께 실패 사유를 함께 기록
# 입력: group_has_error, fail_reason
# 출력: COMMIT_MERGED, COMMIT_CANCELED, COMMIT_RESULT 파일 업데이트, success_count/fail_count 증가
    local group_has_error="$1" fail_reason="$2"
    local i c s
    
    # 그룹 실패 시 상태별 사유를 canceled 목록에 기록
    if [[ "$group_has_error" == "True" ]]; then
        for (( i=0; i<${#patch_buffer[@]}; i++ )); do
            c="${patch_buffer[$i]}"
            s="${commit_statuses[$i]}"
            # 적용 결과 상태를 case로 분기 기록
            case "$s" in
                OKAY) echo "BACK| ${c} | Rolled back due to related dependency failure" >> "${COMMIT_RESULT}"
            ;;  FAIL) echo "FAIL| ${c} | ${fail_reason}" >> "${COMMIT_RESULT}"
            ;;     *) echo "FAIL| ${c} | Skipped due to previous dependency failure" >> "${COMMIT_RESULT}"
            esac
            # 실패 그룹의 모든 커밋을 canceled로 집계
            echo "${c}" >> "${COMMIT_CANCELED}"
            fail_count=$((fail_count + 1))
        done
    else
        # 그룹 성공 시 merged 목록과 성공 카운트를 누적
        for (( i=0; i<${#patch_buffer[@]}; i++ )); do
            c="${patch_buffer[$i]}"
            echo "OKAY| ${c}" >> "${COMMIT_RESULT}"
            echo "${c}" >> "${COMMIT_MERGED}"
            success_count=$((success_count + 1))
        done
    fi
}


apply_commit() {
#----------------------------------------------------------------------------------------------------------
# get_commit으로 추출된 후보 커밋 목록을 repo로 구성된 source의 각 project로 병합
# 의존성이 있는 경우 재귀 탐색으로 관련 커밋들을 그룹화하여 순차 병합, 하나라도 실패하면 전체 그룹 롤백
# 입력: list_file - 후보 커밋 목록 파일 경로 (기본값: COMMIT_CANDIDATE)
# 출력: 병합 결과를 COMMIT_RESULT, COMMIT_MERGED, COMMIT_CANCELED에 기록, 성공 시 0 반환
    local list_file="${1:-$COMMIT_CANDIDATE}"
    # 후보 파일이 비어있으면 바로 종료
    [[ ! -s "${list_file}" ]] && { echo "No candidate list file found: ${list_file}"; return "$RET_NO_CHANGES"; }
    
    # 전체 커밋 수를 계산하고 결과 파일을 초기화
    local total_commits change group_has_error fail_reason error_output pull_result commit_to_apply
    total_commits=$(grep -cve '^[[:space:]]*$' "${list_file}")
    bar "Merge commit"
    
    # 결과 파일 초기화
    rm -f "${COMMIT_RESULT}" "${COMMIT_MERGED}" "${COMMIT_CANCELED}"
    
    # 전체 실행 상태 변수를 준비
    success_count=0 fail_count=0
    declare -A global_seen_commits
    
    # 후보 파일을 순회하며 의존성 그룹 단위로 처리, 중복 commit은 1회만 처리(global_seen_commits 활용)
    while IFS= read -r change; do
        [[ -z "$change" || -n "${global_seen_commits[$change]}" ]] && continue
        
        # patch_buffer= base 커밋 + 의존성커밋1 + 의존성커밋2 ... 형태 배열
        patch_buffer=("${change}")
        get_relate_changes "${change}"
        
        # 이번 그룹 커밋은 전역 중복 방지 집합에 표시
        for c in "${patch_buffer[@]}"; do  global_seen_commits["$c"]="1" ; done
        
        # 그룹 단위 결과 상태를 초기화
        group_has_error="False" fail_reason=""
        applied_paths=() applied_heads=() commit_statuses=()
        success_messages=()  # 성공 메시지 버퍼 추가
        
        # 그룹 내 커밋을 순차 pull하고 실패 시 즉시 중단
        for commit_to_apply in "${patch_buffer[@]}"; do
            backup_project_head "${commit_to_apply}"
            
            error_output=$(git_pull "${commit_to_apply}" 2>&1)
            pull_result=$?
            
            # 실패 사유를 정리하여 보고 가능한 문자열로 축약
            if [[ $pull_result -ne 0 ]]; then
                group_has_error="True"
                fail_reason=$(echo "$error_output" | grep -iE 'fatal:|error:|conflict' | head -1)
                [[ -z "$fail_reason" ]] && fail_reason=$(echo "$error_output" | grep -oP 'Error: \K.*' | head -1)
                [[ -z "$fail_reason" ]] && fail_reason="unknown error"
                fail_reason=$(echo "$fail_reason" | tr -s ' \t' ' ' | tr -d '\r\n')
                commit_statuses+=("FAIL")
                printf "%b[FAIL]%b %s - %s\n" "${COLOR_RED}" "${COLOR_RESET}" "${commit_to_apply}" "${fail_reason}"
                break
            else
                # 성공 커밋은 버퍼에 저장 (그룹 전체 성공 확인 후 출력)
                commit_statuses+=("OKAY")
                success_messages+=("$(printf "%b[OKAY]%b %s" "${COLOR_GREEN}" "${COLOR_RESET}" "${commit_to_apply}")")
            fi
        done
        
        # 그룹 성공 시 버퍼링된 메시지 출력
        if [[ "$group_has_error" == "False" ]]; then
            for msg in "${success_messages[@]}"; do echo "$msg"; done
        fi
        
        # 그룹 실패 시 롤백 후 결과 파일로 집계
        [[ "$group_has_error" == "True" ]] && rollback_group
        record_results "$group_has_error" "$fail_reason"
    done < "${list_file}"
    
    # 전체 합계를 결과 파일에 남기고 정렬
    echo "${total_commits} = ${success_count} + ${fail_count}" >> "${COMMIT_RESULT}"
    sort -r "${COMMIT_RESULT}" -o "${COMMIT_RESULT}"
}
