#!/bin/bash
# 생성된 gen-fin.xml 을 참조하여 repo forall로 모든 git에 대해서
# 1. remote를 등록하고
# 2. remote가 실제로 존재하는지 확인하고
# 3. remote에 실제 branch가 존재하는지 확인
# 이를 통해서 remote나 branch가 제대로 등록되지 않은 잘못된 git project가 존재하는지 확인하게 된다.
# 이후, remote만 존재하는 상황이, chipset code를 mirroring하기 가장 좋은 상황이 된다.
# 주의) remote는 default.xml의 REPO_REMOTE를 사용하지 않고, gen-fin.xml에서 각 line에 추출한 remote를 사용한다.

# check-repo.sh - repo forall로 모든 git의 remote와 branch 존재 여부를 확인
# Usage: check-repo.sh <gen-fin.xml> <branch>
# ex)    check-repo.sh .repo/manifests/gen-fin.xml master


set -uo pipefail

# 색상 정의
readonly COLOR_GREEN="\033[92m\033[1m"
readonly COLOR_RED="\033[91m\033[1m"
readonly COLOR_YELL="\033[93m\033[1m"
readonly COLOR_BLUE="\033[94m\033[1m"
readonly COLOR_RESET="\033[0m"

# 파라미터 확인
[[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Usage: $0 <gen-fin.xml> <branch>"; exit 1; }

GEN_FIN_XML="$1"
BRANCH_NAME="refs/heads/$2"
[[ ! -f "$GEN_FIN_XML" ]] && { echo "Error: GEN_FIN_XML not found: $GEN_FIN_XML"; exit 1; }

# 임시 파일 (repo forall 결과 수집용)
tmp_lookup=$(mktemp)    # gen-fin.xml에서 생성: project_name|remote_name|full_vgit_url
FILE_RESULT=$(pwd)/check-repo.result   # repo forall 결과: state|repo_path|remote_url  (state: HEAD_SAME/HEAD_REMOTE/HEAD_LOCAL/HEAD_DIFFER/NO_BRANCH/NO_REMOTE)
# 절대경로 필수: repo forall은 각 repo 디렉토리에서 실행되므로 상대경로는 각 repo 내부를 가리킴
> "$FILE_RESULT"                       # 항상 신규파일로 생성

# gen-fin.xml에서 remote line에서 name -> fetch URL 매핑 추출
# repo forall은 default.xml를 참조하는데, 현재 remote는 devops_test로 되어 있어, REPO_REMOTE와 fetch url을 가져올수 없는 상태라 수동으로 가져옮
declare -A remote_fetch
while IFS='`' read -r rname fetch; do
    [[ -n "$rname" && -n "$fetch" ]] && remote_fetch["$rname"]="$fetch"
done < <(xmlstarlet sel -t -m "//remote" -v "@name" -o '`' -v "@fetch" -n "$GEN_FIN_XML" 2>/dev/null)

# gen-fin.xml에서 tmp_lookup파일 생성(형식: project_name|project_path|remote_name|full_remote_url)
while IFS='`' read -r pname ppath premote; do
    [[ -z "$pname" || -z "$ppath" || -z "$premote" ]] && continue
    fetch="${remote_fetch[$premote]:-}"
    [[ -n "$fetch" ]] && echo "${pname}|${ppath}|${premote}|${fetch}/${ppath}" >> "$tmp_lookup"
done < <(xmlstarlet sel -t -m "//project[@path]" -v "@name" -o '`' -v "@path" -o '`' -v "@remote" -n "$GEN_FIN_XML" 2>/dev/null)


# repo forall 대신 tmp_lookup을 while 루프로 순회 (repo forall은 manifest의 devops_test remote 검증으로 pool 강제 종료 발생)
# tmp_lookup 형식: project_name|project_path|remote_name|full_remote_url
WORKSPACE_ROOT=$(pwd)
while IFS='|' read -r REPO_PROJECT REPO_PATH remote_name remote_url; do
    GIT_DIR="${WORKSPACE_ROOT}/${REPO_PATH}"
    [[ ! -d "$GIT_DIR/.git" ]] && { echo "NO_REMOTE|${REPO_PATH}|no .git dir" >> "$FILE_RESULT"; continue; }

    # 모든 remote 제거 후 lookup에서 추출한 remote name/url로 등록
    while IFS= read -r rname; do
        git -C "$GIT_DIR" remote rm "$rname" 2>/dev/null || true
    done < <(git -C "$GIT_DIR" remote 2>/dev/null)
    git -C "$GIT_DIR" remote add "$remote_name" "$remote_url"

    # vgit 서버에 remote repository 자체 존재 여부 확인, 대상 branch 존재 여부 확인
    git -C "$GIT_DIR" ls-remote --exit-code "$remote_name" HEAD          >/dev/null 2>&1 && remote_status="exist" || remote_status="none"
    git -C "$GIT_DIR" ls-remote --exit-code "$remote_name" "$BRANCH_NAME" >/dev/null 2>&1 && branch_status="exist" || branch_status="none"

    # 로컬 HEAD와 vgit remote branch HEAD 비교 (branch가 존재할 때만 의미 있음)
    # 판별 전략 (네트워크 비용 최소화):
    #   ① local_head == remote_head                              → HEAD_SAME     (SHA 직접 비교, 네트워크 없음)
    #   ② git rev-list HEAD | grep remote_head                   → HEAD_LOCAL    (로컬 히스토리 탐색, 네트워크 없음)
    #   ③ git fetch --shallow-since=<local HEAD 커밋날짜>         → 최소 fetch 후 merge-base로 정확 판별
    #      HEAD_DIFFER가 기본값: 날짜불가/fetch실패/DIVERGED/UNRELATED 모두 통합
    #      - merge-base --is-ancestor local fetched              → HEAD_REMOTE   (remote가 앞서있음)
    # ※ git ls-remote 는 branch 지정 ("$BRANCH_NAME") 으로만 사용 → 전체 refs 스캔 금지
    if [[ "$branch_status" == "exist" ]]; then
        local_head=$(git -C "$GIT_DIR" rev-parse HEAD 2>/dev/null)
        remote_head=$(git -C "$GIT_DIR" ls-remote "$remote_name" "$BRANCH_NAME" 2>/dev/null | cut -f1)
        if   [[ -z "$local_head" || -z "$remote_head" ]];                                          then head_status="HEAD_DIFFER"  # SHA 획득 불가 → 판별 불가
        elif [[ "$local_head" == "$remote_head" ]];                                                then head_status="HEAD_SAME"    # 완전 동일
        elif git -C "$GIT_DIR" rev-list HEAD 2>/dev/null | grep -qm1 "^${remote_head}";           then head_status="HEAD_LOCAL"   # 로컬 히스토리에 remote HEAD 존재 → local이 앞서있음
        else
            # ①②로 판별 불가 → shallow fetch 후 merge-base로 정확 판별, HEAD_DIFFER가 기본값 (판별 불가 케이스 통합)
            head_status="HEAD_DIFFER"
            local_commit_date=$(git -C "$GIT_DIR" log -1 --format="%cI" HEAD 2>/dev/null)
            if [[ -n "$local_commit_date" ]]; then
                git -C "$GIT_DIR" fetch --shallow-since="$local_commit_date" "$remote_name" "$BRANCH_NAME" >/dev/null 2>&1
                fetched_head=$(git -C "$GIT_DIR" rev-parse FETCH_HEAD 2>/dev/null)
                git -C "$GIT_DIR" merge-base --is-ancestor "$local_head" "$fetched_head" 2>/dev/null && head_status="HEAD_REMOTE"  # local이 remote의 ancestor → remote가 앞서있음
            fi
        fi
    fi

    # 결과를 state|path|url 형식으로 기록
    if   [[ "$remote_status" == "exist" && "$branch_status" == "exist" ]]; then echo "${head_status}|${REPO_PATH}|${remote_url}" >> "$FILE_RESULT"
    elif [[ "$remote_status" == "exist" ]];                                   then echo "NO_BRANCH|${REPO_PATH}|${remote_url}" >> "$FILE_RESULT"
    else                                                                             echo "NO_REMOTE|${REPO_PATH}|remote not found on vgit" >> "$FILE_RESULT"
    fi
done < "$tmp_lookup"

echo "=== Results ==="
# FILE_RESULT를 state 기준으로 정렬하여 출력
# 출력 순서: HEAD_DIFFER → HEAD_LOCAL → HEAD_REMOTE → HEAD_SAME → NO_BRANCH → NO_REMOTE (알파벳 순)
cnt_no_branch=0      # remote는 있지만 branch 없음 (새 branch 생성 필요)
cnt_no_remote=0      # remote 자체 없음 (manifest 오류)
cnt_head_same=0      # remote HEAD == local HEAD (이미 동기화됨)
cnt_head_remote=0    # remote가 local을 포함하고 앞서있음
cnt_head_local=0     # local이 remote를 포함하고 앞서있음 (push 가능, rev-list 판별)
cnt_head_differ=0    # shallow fetch로 판별 불가 (DIVERGED/UNRELATED/N/A 포함, full fetch 필요)

# ── 출력 포맷 설명 ───────────────────────────────────────────────────────────
# printf 포맷: "[LABEL]%-100s%-60s\n"
#   [LABEL]    : 상태 라벨 (색상 포함, 26자 고정폭으로 정렬)
#   %-100s     : remote_url을 100자 너비로 왼쪽 정렬 (짧으면 공백 패딩, 초과 시 그냥 이어서 출력)
#   %-60s      : repo_path를 60자 너비로 왼쪽 정렬
#   총 출력 너비 = label(26) + url(100) + path(60) = 186자
# ────────────────────────────────────────────────────────────────────────────
while IFS='|' read -r state repo_path remote_url; do
    # 상태별 라벨 및 카운터 업데이트
    case "$state" in
          NO_BRANCH)   label="${COLOR_GREEN}[NO_BRANCH  ]  ${COLOR_RESET}"; cnt_no_branch=$((cnt_no_branch+1))
       ;; HEAD_SAME)   label="${COLOR_GREEN}[HEAD_SAME  ]  ${COLOR_RESET}"; cnt_head_same=$((cnt_head_same+1))
       ;; HEAD_REMOTE) label="${COLOR_YELL}[HEAD_REMOTE]  ${COLOR_RESET}"; cnt_head_remote=$((cnt_head_remote+1))
       ;; HEAD_LOCAL)  label="${COLOR_YELL}[HEAD_LOCAL ]  ${COLOR_RESET}"; cnt_head_local=$((cnt_head_local+1))
       ;; HEAD_DIFFER) label="${COLOR_RED}[HEAD_DIFFER]  ${COLOR_RESET}"; cnt_head_differ=$((cnt_head_differ+1))
       ;; NO_REMOTE)   label="${COLOR_RED}[NO_REMOTE  ]  ${COLOR_RESET}"; cnt_no_remote=$((cnt_no_remote+1));;
    esac
    # label 출력 후 remote_url 100자 왼쪽 정렬, repo_path 60자 왼쪽 정렬
    printf "${label}%-100s%-60s\n" "${remote_url}" "${repo_path}"
done < <(sort -t'|' -k1,1 "$FILE_RESULT")

echo ""
# 최종 요약 출력
total_count=$(wc -l < "$FILE_RESULT" 2>/dev/null || echo 0)
echo -e "${COLOR_BLUE}=== Summary ===${COLOR_RESET}"
echo "  GEN_FIN_XML : $(readlink -f "$GEN_FIN_XML")"
echo "  BRANCH_NAME : $BRANCH_NAME"
echo ""
echo "  Total processed (repo forall): $total_count"
echo -e "    ${COLOR_RED}NO_REMOTE  ${COLOR_RESET}  : $(printf "%4d" $cnt_no_remote)  (err, must check gen-fin.xml)"
echo -e "    ${COLOR_GREEN}NO_BRANCH  ${COLOR_RESET}  : $(printf "%4d" $cnt_no_branch)  (remote exist but branch need >> need to push)"
echo -e "    ${COLOR_GREEN}HEAD_SAME  ${COLOR_RESET}  : $(printf "%4d" $cnt_head_same)  (local == remote >>> no need to push, already synced)"
echo -e "    ${COLOR_YELL}HEAD_REMOTE${COLOR_RESET}  : $(printf "%4d" $cnt_head_remote)  (remote includes local >>> no need to push, remote advanced)"
echo -e "    ${COLOR_YELL}HEAD_LOCAL ${COLOR_RESET}  : $(printf "%4d" $cnt_head_local)  (local includes remote >>> need to push, local advanced)"
echo -e "    ${COLOR_RED}HEAD_DIFFER${COLOR_RESET}  : $(printf "%4d" $cnt_head_differ)  (need full fetch: diverged / unrelated / sha-unavailable / fetch-failed)"
echo -e "\n"
echo "result log: $FILE_RESULT" "$tmp_lookup"
#rm -f "$FILE_RESULT" "$tmp_lookup"
