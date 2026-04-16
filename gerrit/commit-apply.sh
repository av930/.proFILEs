#!/bin/bash
# 용도:
#   Gerrit 원격 저장소에서 submittable 상태의 커밋들을 조회하고 현재 manifest 기반 로컬 저장소로 병합합니다.
#   의존성이 있는 커밋들은 [+] 패턴을 파싱하여 재귀적으로 탐색하고 그룹화하여 순차 병합하며,
#   하나라도 실패하면 전체 그룹을 롤백합니다. 최종 결과는 out_mergelist 파일에 기록됩니다.
#
# 사용법: source apply-commit.sh

#   get_commit [gerrit_query]
#   gerrit_query 기본값: status:open+-label:verified%2B1+label:Code-Review%2B2+branch:connect_w_event_jg_p2_a2_260224
#   apply_commit candidate_list_file.txt

# 환경 변수:
#   USER         : Gerrit 인증 사용자명
#   TOKEN_VGIT   : vgit.lge.com Gerrit API 토큰
#   TOKEN_LAMP   : lamp.lge.com Gerrit API 토큰
#
# 출력 파일:
#   candidate_list_file.txt : 조회된 후보 커밋 URL 목록
#   out_mergelist          : 병합 결과 (OKAY/FAIL/BACK)
#   manifest_formatted.json: manifest JSON 형식
#==========================================================================================================

# Result path
CANDIDATE_LIST_FILE="candidate_list_file.txt"
MERGE_RESULT_FILE="out_mergelist"
RET_NO_CHANGES=0

COLOR_GREEN="\033[92m\033[1m"
COLOR_RED="\033[91m\033[1m"
COLOR_YELLOW="\033[93m\033[1m"
COLOR_RESET="\033[0m"

line="---------------------------------------------------------------------------------------------------------------------------------"
bar() { printf "\n\n\e[1;36m%s%s \e[0m\n" "${1:+[$1] }" "${line:(${1:+3} + ${#1})}"; }


function get_commit_info() {
#----------------------------------------------------------------------------------------------------------
# Gerrit commit URL로부터 commit 정보를 JSON 형식으로 조회합니다.
# Gerrit API를 사용하여 변경 번호로 git 프로젝트명, 리비전, 다운로드 명령어 등 상세 정보를 추출합니다.
# 입력: Gerrit commit URL
# 출력: commit info JSON

    local commit_url="$1"
    [[ -z "$commit_url" ]] && { echo "Error: commit URL required" >&2; return 1; }

    commit_url="$(echo -e "${commit_url}" | tr -d '\r\n ')"

    local change_number="${commit_url##*/}"
    local base_url="${commit_url%%/c/*}"
    local gerrit_query_url="${base_url}/a/changes/?q=${change_number}"

    local auth_string="${USER}:${TOKEN_VGIT}"
    [[ "$commit_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"

    local commit_info
    commit_info="$(curl -fsSu "$auth_string" "${gerrit_query_url}&o=CURRENT_REVISION&o=DOWNLOAD_COMMANDS&o=CURRENT_COMMIT&n=1" | sed '1d')" \
        || return 1

    echo "$commit_info"
    return 0
}


function resolve_changeid_to_url() {
#----------------------------------------------------------------------------------------------------------
# 숫자 change ID를 lamp.lge.com Gerrit API로 조회하여 full URL 형식으로 변환합니다.
# 조회 성공 시 "http://lamp.lge.com/review/c/{project}/+/{change_id}" 형태의 URL을 출력합니다.
# 입력: change ID (숫자)
# 출력: Gerrit full URL (실패 시 빈 문자열)

    local change_id="$1"
    [[ "$change_id" =~ ^[0-9]+$ ]] || return 1

    local auth_string="${USER}:${TOKEN_LAMP}"
    local api_result project_name

    api_result="$(curl -fsSu "$auth_string" \
        "http://lamp.lge.com/review/a/changes/?q=${change_id}&n=1" 2>/dev/null | sed '1d')" || return 1

    project_name="$(echo "$api_result" | jq -r '.[0].project // empty' 2>/dev/null)"
    [[ -z "$project_name" ]] && return 1

    echo "http://lamp.lge.com/review/c/${project_name}/+/${change_id}"
}


function get_relate_changes() {
#----------------------------------------------------------------------------------------------------------
# 커밋 메시지에서 줄처음의 [+] 패턴을 파싱하여 관련 의존성 커밋을 재귀적으로 탐색합니다.
# [+] 뒤에 full URL이 오는 경우와 쉼표/공백으로 구분된 change ID 숫자가 오는 경우를 모두 처리하며,
# 숫자 ID는 lamp.lge.com Gerrit API로 조회하여 URL로 변환한 뒤 patch_buffer에 누적합니다.
# 입력: commit URL
# 출력: patch_buffer 배열에 의존성 커밋 추가 (전역 변수 기반 작동)

    local commit="$1" msg content url

    msg="$(get_commit_info "${commit}" | jq -r '.[0].revisions[].commit.message' 2>/dev/null)" || return 0

    while IFS= read -r line; do
        # [+]가 줄 처음에 있는 경우만 처리
        [[ "$line" =~ ^\[+\][[:space:]]*(.*) ]] || continue
        content="${BASH_REMATCH[1]}"

        if [[ "$content" =~ ^https?:// ]]; then
            # Full URL → 직접 추가
            url="$content"
        else
            # Change ID 숫자들 → lamp.lge.com 조회
            for token in ${content//,/ }; do
                token="${token//[[:space:]]/}"
                [[ "$token" =~ ^[0-9]+$ ]] || continue
                url="$(resolve_changeid_to_url "$token")"
                [[ -z "$url" ]] && { echo "[WARN] Failed to resolve change ID: $token" >&2; continue; }
                echo "[CHECK] Resolved ID $token -> $url" >&2
                
                # 중복 체크 및 재귀 호출
                [[ " ${patch_buffer[*]} " =~ " ${url} " ]] && continue
                patch_buffer+=("$url")
                get_relate_changes "$url"
            done
            continue
        fi

        # URL 중복 체크 및 재귀 호출
        [[ " ${patch_buffer[*]} " =~ " ${url} " ]] && continue
        echo "[CHECK] Found related change: $url" >&2
        patch_buffer+=("$url")
        get_relate_changes "$url"
    done <<< "$msg"
}


function git_pull() {
#----------------------------------------------------------------------------------------------------------
# Gerrit commit 정보를 기반으로 해당 프로젝트의 git 디렉토리를 찾아 안전한 풀 명령을 실행합니다.
# divergent branches 충돌을 피하기 위해 pull.rebase=false 옵션을 적용(ff로 try후 안되면 merge하는 방식), 실패시 에러 출력.
# 입력: Gerrit commit URL
# 출력: 성공 시 0, 실패 시 1 반환

    local commit_url="$1"
    [[ -z "$commit_url" ]] && { echo "Error: commit URL required" >&2; return 1; }

    commit_url="$(echo -e "${commit_url}" | tr -d '\r\n ')"

    local commit_info project_info project_name cmt_pull_cmd project_path

    commit_info="$(get_commit_info "${commit_url}")" \
        || { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Error: failed to fetch commit info" >&2; return 1; }

    project_info="$(echo "$commit_info" | jq -r '.[0] | "\(.project)|\(.revisions[].fetch.ssh.commands.Pull)"' 2>/dev/null)" \
        || { echo "Error: failed to parse commit JSON" >&2; return 1; }

    project_name="${project_info%%|*}"
    cmt_pull_cmd="${project_info#*|}"
    [[ "$project_name" == "null" ]] && project_name=""

    project_path="$(repo list -r "$project_name" 2>/dev/null | grep -m1 ": $project_name" | cut -f1 -d':' | sed 's/[[:space:]]*$//')" \
        || { echo "Error: project '$project_name' not found in manifest" >&2; return 1; }

    [[ -z "$project_path" || -z "$cmt_pull_cmd" ]] && { echo "Error: incomplete commit info" >&2; return 1; }

    # Force merge strategy for git pull to avoid "Need to specify how to reconcile divergent branches".
    local safe_pull_cmd
    safe_pull_cmd="${cmt_pull_cmd/git pull /git -c pull.rebase=false pull }"

    (
        cd "$project_path" || return 1
      eval "$safe_pull_cmd"
    ) || { echo "Error: failed to pull in $project_path" >&2; return 1; }

    echo "[OKAY] Successfully pulled commit to $project_path"
    return 0
}


function get_commit() {
  #------------------------------------------
  # 현재 manifest의 리뷰 원격 저장소(Gerrit)에서 submittable 상태의 모든 후보 커밋을 조회하여
  # 목록을 $CANDIDATE_LIST_FILE 파일에 기록합니다. (병합 제외)
  # 입력: gerrit_query - Gerrit API 쿼리 문자열
  # 출력: 성공 시 0, 변경 없음 시 RET_NO_CHANGES 반환

  local GERRIT_QUERY="${1:?"You must provide a Gerrit query string as the first argument"}"
  set +x
  
  manifest_formatted="manifest_formatted.json"
  repo manifest --json -o $manifest_formatted

  default_remote="$(cat $manifest_formatted | jq .default.remote)"
  remote_list="$(cat $manifest_formatted | jq .remote)"
  
  remote_count=$(echo "$remote_list" | jq -r '.[] | select(.review != null) | .review' | sort -u | wc -l)
  bar "remote list: $remote_count"
  rm -rf "${CANDIDATE_LIST_FILE}" "${MERGE_RESULT_FILE}"

  # manifest에 등록된 프로젝트 목록 추출 (.git 확장자 제거)
  project_names="$(cat $manifest_formatted | jq -r '.project | .[] | .name' | sed 's/\.git$//')"

  echo -e "${COLOR_GREEN} Total projects in manifest: $(echo "$project_names" | wc -l)"
  #echo "[DEBUG parsing] First 3 projects: $(echo "$project_names" | head -3 | tr '\n' ', ')"


  # remote URL 기준으로 중복을 제거하여 한 번에 전체 조회
  while read -r remote_url; do

      echo -ne "${COLOR_GREEN}[OKAY]${COLOR_RESET} Querying remote URL: $remote_url"

      # 전역변수로 받은 인증 정보
      local auth_string="${USER}:${TOKEN_VGIT}"
      [[ "$remote_url" == *"lamp.lge.com"* ]] && auth_string="${USER}:${TOKEN_LAMP}"

      # 전체 커밋 조회 (프로젝트 필터 없이) - sed '1d' 로 )]}' 제거
      all_commits="$(curl -fsSu "$auth_string" \
        "$remote_url/a/changes/?q=${GERRIT_QUERY}" \
        2>/dev/null | sed '1d')" || { echo -e " -> ${COLOR_YELLOW}[WARN]${COLOR_RESET} Failed"; continue; }

      commit_count=$(echo "$all_commits" | jq -r 'length // 0' 2>/dev/null)
      #echo "[DEBUG getcomit] get $commit_count commits from gerrit API"

      [[ "$commit_count" -eq 0 ]] && { echo ""; continue; }
    matched=0

    local sample_idx=0

    # Subshell 이슈 해결을 위해 done <<< 형태로 파이프라인 우회
    while IFS='|' read -r change_number project_name; do
      # \r 이나 공백 정리하여 숨겨진 문자 제거
      project_name="$(echo "$project_name" | tr -d '\r\n ')"

      # manifest에 해당 프로젝트가 있는지 확인
      # -x를 제거하고 ^ 와 $ 로 정확히 앞뒤가 떨어지는지 검사 (공백 우회용)
      if echo "$project_names" | grep -q "^${project_name}$"; then
        echo "$remote_url/c/${project_name}/+/$change_number" >>"$CANDIDATE_LIST_FILE"
        matched=$((matched + 1))
      else
        # 불일치할 때만 10개까지 샘플 출력 및 빨간색 에러 로그 출력
        if [[ $sample_idx -lt 10 ]]; then
              [[ $sample_idx -eq 0 ]] && echo ""
              local sample_manifest_match
              sample_manifest_match=$(echo "$project_names" | grep "$project_name" | head -1 || echo "NO_MATCH")
              echo -e "${COLOR_RED}[FAIL] Not matched in manifest: '${project_name}'${COLOR_RESET}"
              echo -e "${COLOR_RED}       (Closest Manifest was: '${sample_manifest_match}')${COLOR_RESET}"
              sample_idx=$((sample_idx + 1))
          fi
        fi
      done <<< "$(echo "$all_commits" | jq -r '.[] | "\(._number)|\(.project)"')"

      if [ $matched -gt 0 ]; then
          [[ $sample_idx -gt 0 ]] && echo -ne "${COLOR_GREEN}[OKAY]${COLOR_RESET} Querying remote URL: $remote_url"
          echo -e ": matched commits:${matched}"
      else
          [[ $sample_idx -eq 0 ]] && echo ""
      fi
  done < <(echo "$remote_list" | jq -r '.[] | select(.review != null) | .review' | sort -u)

    # 중복 제거
    [[ -f "$CANDIDATE_LIST_FILE" ]] && sort -u -o "$CANDIDATE_LIST_FILE" "$CANDIDATE_LIST_FILE"


    local total_commits=0
    if [[ -s "${CANDIDATE_LIST_FILE}" ]]; then
      total_commits=$(grep -cve '^[[:space:]]*$' "${CANDIDATE_LIST_FILE}")
    fi
    
    bar "List Changes: $total_commits"
    if [[ -s "${CANDIDATE_LIST_FILE}" && "$total_commits" -gt 0 ]]; then
      cat "${CANDIDATE_LIST_FILE}"
    else
      echo "We have no changes"
      rm -f "${CANDIDATE_LIST_FILE}"
      return "$RET_NO_CHANGES"
    fi
    return 0
}


function apply_commit() {
  #------------------------------------------
  # get_commit으로 추출된 후보 커밋 목록을 로컬 프로젝트로 병합합니다.
  # 의존성이 있는 경우 재귀 탐색으로 관련 커밋들을 그룹화합니다.
  # 그룹 내 모든 커밋을 순차 병합하며, 하나라도 실패하면 전체 그룹을 롤백하고 결과를 out_mergelist 파일에 기록합니다.
  # 입력: list_file - 후보 커밋 목록 파일 경로 (기본값: CANDIDATE_LIST_FILE)

  local list_file="${1:-$CANDIDATE_LIST_FILE}"
  
  if [[ ! -s "${list_file}" ]]; then
    echo "No candidate list file found: ${list_file}"
    return "$RET_NO_CHANGES"
  fi

  local total_commits=0
  total_commits=$(grep -cve '^[[:space:]]*$' "${list_file}")

  bar "Merge commit"

  local success_count=0
  local fail_count=0
  local commit_seq=0
  declare -A global_seen_commits

  while IFS= read -r change; do
    [[ -z "$change" ]] && continue
    # 이미 이전 그룹(관련 커밋 포함)에서 처리된 경우 건너뜀
    [[ -n "${global_seen_commits[$change]}" ]] && continue

    # 의존성 커밋 탐색 (patch_buffer는 함수 내부에서 전역처럼 동작)
    patch_buffer=("${change}")
    get_relate_changes "${change}"

    # 이번 그룹의 모든 관련 커밋을 방문했다고 체크 (추후 캔디데이트 목록에서 다시 실행안되게 방지)
    for c in "${patch_buffer[@]}"; do
        global_seen_commits["$c"]="1"
    done

    commit_seq=$((commit_seq + 1))
    local seq_str
    seq_str=$(printf "%04d" "$commit_seq")

    local group_has_error="False"
    local fail_reason=""
    local -a applied_paths=()
    local -a applied_heads=()
    local -a commit_statuses=()

    # 의존성 커밋 순차 처리
    for commit_to_apply in "${patch_buffer[@]}"; do
      #echo "[INFO] Applying: ${commit_to_apply}"

      # 현재 프로젝트의 HEAD 정보 백업 (롤백용)
      local c_info p_name p_path p_head
      c_info=$(get_commit_info "${commit_to_apply}")
      if [[ -n "$c_info" ]]; then
          p_name=$(echo "$c_info" | jq -r '.[0].project' 2>/dev/null)
          if [[ -n "$p_name" && "$p_name" != "null" ]]; then
              p_path=$(repo list -r "$p_name" 2>/dev/null | grep -m1 ": $p_name" | cut -f1 -d':' | sed 's/[[:space:]]*$//')
              if [[ -n "$p_path" && -d "$p_path" ]]; then
                  p_head=$(git -C "$p_path" rev-parse HEAD 2>/dev/null)
                  # 한 그룹 안에서 동일 레포지토리에 여러 개의 커밋이 들어갈 경우 최초 HEAD만 저장
                  local already_saved="False"
                  for ap in "${applied_paths[@]}"; do
                      [[ "$ap" == "$p_path" ]] && already_saved="True"
                  done
                  if [[ "$already_saved" == "False" ]]; then
                      applied_paths+=("$p_path")
                      applied_heads+=("$p_head")
                  fi
              fi
          fi
      fi

      # Pull & Merge 실행
      local error_output pull_result
      error_output=$(git_pull "${commit_to_apply}" 2>&1)
      pull_result=$?

      if [ $pull_result -ne 0 ]; then
        group_has_error="True"
        # 실제 git 에러 메세지(fatal, error, conflict)를 우선적으로 캡처
        fail_reason=$(echo "$error_output" | grep -iE 'fatal:|error:|conflict' | head -1)
        [[ -z "$fail_reason" ]] && fail_reason=$(echo "$error_output" | grep -oP 'Error: \K.*' | head -1)
        [[ -z "$fail_reason" ]] && fail_reason="unknown error"

        # 출력 가독성을 위해 불필요한 연속 공백 처리
        fail_reason=$(echo "$fail_reason" | tr -s ' \t' ' ' | tr -d '\r\n')

        commit_statuses+=("FAIL")
        printf "[%04d]%b[FAIL]%b %s - %s\n" "$commit_seq" "${COLOR_RED}" "${COLOR_RESET}" "${commit_to_apply}" "${fail_reason}"
        break  # 에러 발생 시 현재 그룹 중단
      else
        commit_statuses+=("OKAY")
        printf "[%04d]%b[OKAY]%b %s\n" "$commit_seq" "${COLOR_GREEN}" "${COLOR_RESET}" "${commit_to_apply}"
      fi
    done

    # 결과 및 롤백 처리
    if [[ "$group_has_error" == "True" ]]; then
      for (( i=0; i<${#applied_paths[@]}; i++ )); do
          local r_path="${applied_paths[$i]}"
          local r_head="${applied_heads[$i]}"
          #printf "       [WARN] %s failed, reset %d projects to %s in %s\n" "$seq_str" "${#applied_paths[@]}" "${r_head:0:8}" "$r_path"
          git -C "$r_path" merge --abort >/dev/null 2>&1 || true
          git -C "$r_path" reset --hard "$r_head" >/dev/null 2>&1 || true
      done
      #[[ ${#applied_paths[@]} -eq 0 ]] && printf "       [WARN] %s failed, no projects to reset\n" "$seq_str"

      # 모두 FAIL 또는 BACK으로 기록
      for (( i=0; i<${#patch_buffer[@]}; i++ )); do
        local c="${patch_buffer[$i]}"
        local s="${commit_statuses[$i]}"

        if [[ "$s" == "OKAY" ]]; then
            # 이 커밋은 정상이었으나 롤백됨
            echo "${seq_str}| BACK| ${c} | Rolled back due to related dependency failure" >> "${MERGE_RESULT_FILE}"
            fail_count=$((fail_count + 1))
        elif [[ "$s" == "FAIL" ]]; then
            # 이 커밋 때문에 그룹이 실패함
            echo "${seq_str}| FAIL| ${c} | ${fail_reason}" >> "${MERGE_RESULT_FILE}"
            fail_count=$((fail_count + 1))
        else
            # 시도조차 못함
            echo "${seq_str}| FAIL| ${c} | Skipped due to previous dependency failure" >> "${MERGE_RESULT_FILE}"
            fail_count=$((fail_count + 1))
        fi
      done
    else
      # 모두 성공 시 OKAY 기록
      for (( i=0; i<${#patch_buffer[@]}; i++ )); do
        local c="${patch_buffer[$i]}"
        echo "${seq_str}| OKAY| ${c}" >> "${MERGE_RESULT_FILE}"
        success_count=$((success_count + 1))
      done
    fi

  done < "${list_file}"

  # 최종 통계 반영
  echo "${total_commits} = ${success_count} + ${fail_count}" >> "${MERGE_RESULT_FILE}"
  sort -r "${MERGE_RESULT_FILE}" -o "${MERGE_RESULT_FILE}"

  set -x
  return 0
}
