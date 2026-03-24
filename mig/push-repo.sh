#!/bin/bash
# check-repo.sh에 의해 생성된 result 파일을 참조하여 repo forall로 모든 git에 대해 push 수행
# 주의) check-repo.sh 실행 후 생성된 check-repo.result가 현재 디렉토리에 있어야 함
#
# push 전략 (option: force | merge):
#   NO_BRANCH   : 새 branch 생성 push                             → PUSH
#   HEAD_SAME      : skip (이미 동기화됨)                          → SKIP
#   HEAD_REMOTE    : skip (remote가 앞서있음)                      → SKIP
#   HEAD_LOCAL     : 일반 push                                    → PUSH
#   HEAD_DIFFER    : full fetch 후 DIVERGED/UNRELATED 판별
#     [force]  DIVERGED  → force push                            → FORCE
#     [force]  UNRELATED → force push                            → FORCE
#     [merge]  DIVERGED  → git merge FETCH_HEAD → push           → MERGE
#     [merge]  UNRELATED → git merge --allow-unrelated-histories → MERGE
#                          merge 실패 시 -s ours 로 공통조상 생성   → MERGE
#   push 실패 시                                                  → FAIL
#
# 결과 파일 (push-repo.result):
#   check-repo.result 각 라인 맨 앞에 PUSH|SKIP|FORCE|MERGE|FAIL 추가
#   형식: RESULT|status|head_status|repo_path|remote_url

 # Usage: push-repo.sh <compare-branch> <dest-branch> <option>
 # ex)    push-repo.sh branch_old branch_new force
 # ex)    push-repo.sh branch_old branch_new merge

set -uo pipefail

# 색상 정의
readonly COLOR_GREEN="\033[92m\033[1m"
readonly COLOR_RED="\033[91m\033[1m"
readonly COLOR_YELL="\033[93m\033[1m"
readonly COLOR_BLUE="\033[94m\033[1m"
readonly COLOR_RESET="\033[0m"

 # 파라미터 확인
 [[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: $0 <compare-branch> <dest-branch> <force|merge>"; exit 1; }

BRANCH_COMPARE="refs/heads/$1"
BRANCH_DEST="refs/heads/$2"
PUSH_OPTION="$3"
[[ "$PUSH_OPTION" != "force" && "$PUSH_OPTION" != "merge" ]] && {
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Invalid option: '$PUSH_OPTION'. Use 'force' or 'merge'."
    exit 1
}

# 절대경로 필수: repo forall은 각 repo 디렉토리에서 실행되므로 상대경로는 각 repo 내부를 가리킴
FILE_CHECK=$(pwd)/check-repo.result
FILE_PUSH=$(pwd)/push-repo.result

# FILE_CHECK파일 존재 및 포맷 검사 (첫줄만 읽어 format검증: STATE|REPO_PATH|REMOTE_URL)
[[ ! -f "$FILE_CHECK" ]] && { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $FILE_CHECK not found. Run check-repo.sh first."; exit 1; }
first_line=$(head -1 "$FILE_CHECK")
IFS='|' read -r _state _path _url <<< "$first_line"
col_count=$(awk -F'|' '{print NF}' <<< "$first_line")
#FILE_CHECK파일 colume이 3개인지, 첫 colume의 항목에 다른 요소가 없는지, path나 url이 제대로 있는지
[[ "$col_count" -ne 3 ]] && { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Invalid format in $FILE_CHECK (expected 3 columns, got $col_count): $first_line"; exit 1; }
[[ "$_state" =~ ^(HEAD_SAME|HEAD_DIFFER|HEAD_LOCAL|HEAD_REMOTE|NO_BRANCH|NO_REMOTE)$ ]] \
    || { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Unknown status '$_state' in $FILE_CHECK. Is this a valid check-repo.result file?"; exit 1; }
[[ -z "$_path" || -z "$_url" ]] && { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Empty path or URL in $FILE_CHECK first line: $first_line"; exit 1; }
unset first_line _state _path _url col_count

# NO_REMOTE 항목 존재 시 abort
# manifest에 등록되지 않은 git이 있으면 push 대상 파악이 불완전하므로 중단
grep -q "^NO_REMOTE|" "$FILE_CHECK" && {
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} NO_REMOTE entry found in $FILE_CHECK."
    echo "  → Please fix gen-fin.xml and re-run check-repo.sh before pushing."
    exit 1
}

# push 결과 파일 초기화
> "$FILE_PUSH"

echo -e "${COLOR_BLUE}=== Push Start ===${COLOR_RESET}"
echo "  COMPARE_BRANCH : $BRANCH_COMPARE"
echo "  DEST_BRANCH    : $BRANCH_DEST"
echo "  PUSH_OPTION    : $PUSH_OPTION"
echo "  CHECK FILE     : $FILE_CHECK"
echo ""


export BRANCH_COMPARE BRANCH_DEST PUSH_OPTION FILE_CHECK FILE_PUSH
echo "---------------------------------------"
# repo forall로 모든 git에 대해 push 수행
# HEREDOC + bash -s 사용 이유:
#   repo forall -c 는 기본적으로 /bin/sh 로 실행되어 bash 전용 문법([[]], <<<)이 동작하지 않을 수 있음
#   cat << EOF | bash -s 패턴으로 내부 스크립트를 명시적으로 bash에서 실행
# push는 순차 실행(-cj1): 병렬 push 시 서버 부하 및 충돌 방지


repo forall -cj1 'cat << \EOF | bash -s
 echo $REPO_PROJECT
EOF
'

echo aaaaaaaaaaaaaaaaaaa
# shellcheck disable=SC2016
repo forall -cj1 'cat << \EOF | bash -s
    # FILE_CHECK파일에서 현재 REPO_PATH에 해당하는 항목 조회
    result_line=$(grep -F "|${REPO_PATH}|" "$FILE_CHECK" | head -1)
    [ -z "$result_line" ] && { printf "SKIP|NOENTRY|HEAD_N/A|$REPO_PATH|(not in $FILE_CHECK)" >> "$FILE_PUSH" ;  exit 0; }

    IFS="|" read -r status repo_path remote_url <<< "$result_line"

    # remote_name: git remote -v에서 URL 매칭으로 획득
    remote_name=$(git remote -v 2>/dev/null | awk -v url="$remote_url" '\''$2==url && $3=="(fetch)"{print $1; exit}'\'')
    [[ -z "$remote_name" ]] && { echo "FAIL|$status|$repo_path|$REPO_PATH|remote not registered" >> "$FILE_PUSH";  exit 0; }

    # 결과 기록 헬퍼: log <RESULT> <type>
    log() { echo "$1|$status|$2|$REPO_PATH|$remote_url" >> "$FILE_PUSH"; }

    # status별 push 처리 (HEAD_SAME, HEAD_REMOTE, HEAD_LOCAL, HEAD_DIFFER, NO_BRANCH, NO_REMOTE, ERR_REMOTE)
    case "$status" in
        HEAD_LOCAL) echo "git push $remote_name $BRANCH_COMPARE:$BRANCH_DEST 2>/dev/null"
            log PUSH "$repo_path" || log FAIL "$repo_path"  #일반 push
        ;; HEAD_DIFFER)
            # full fetch 후 DIVERGED/UNRELATED 판별 → option에 따라 처리
            git fetch "$remote_name" "$BRANCH_DEST" >/dev/null 2>&1
            fetched_head=$(git rev-parse FETCH_HEAD 2>/dev/null)
            local_head=$(git rev-parse HEAD 2>/dev/null)
            [[ -z "$fetched_head" || -z "$local_head" ]] && { log FAIL "FETCH_FAILED";  exit 0; }

            # DIVERGED vs UNRELATED 판별 (full fetch 후이므로 정확)
            git merge-base "$local_head" "$fetched_head" >/dev/null 2>&1 && dtype="DIVERGED" || dtype="UNRELATED"

            if [[ "$PUSH_OPTION" == "force" ]]; then
                # force: DIVERGED/UNRELATED 모두 force push
                echo "git push --force $remote_name $BRANCH_COMPARE:$BRANCH_DEST 2>/dev/null"
                log FORCE "$repo_path" || log FAIL "$repo_path"
            else
                # merge: remote를 local에 merge 후 push (임시 branch로 작업 격리)
                tmp_branch="push_tmp_$$"
                git checkout -b "$tmp_branch" >/dev/null 2>&1
                merge_ok=false
                # DIVERGED: 일반 merge 시도 → 실패 시 abort
                [[ "$dtype" == "DIVERGED" ]] && { git merge --no-edit FETCH_HEAD >/dev/null 2>&1 && merge_ok=true || git merge --abort >/dev/null 2>&1 || true; }
                # UNRELATED 또는 DIVERGED merge 실패: -s ours로 공통조상 임의 생성 (local 트리 유지)
                $merge_ok || { git merge --allow-unrelated-histories --no-edit -s ours FETCH_HEAD >/dev/null 2>&1 && merge_ok=true; }
                if $merge_ok
                then
                    echo "git push $remote_name $BRANCH_COMPARE:$BRANCH_DEST 2>/dev/null"
                    log MERGE "$repo_path" || log FAIL "${repo_path}(push_fail)"
                else
                    log FAIL "${repo_path}(merge_fail)"
                fi
                # 임시 branch 정리
                git checkout - >/dev/null 2>&1 && git branch -D "$tmp_branch" >/dev/null 2>&1 || true
            fi
        ;; *) log SKIP "[$status] $repo_path"   # 기타 처리
    esac
EOF
'

# ── 결과 출력 ────────────────────────────────────────────────────────────────
echo ""
echo "=== Push Results ==="
cnt_push=0; cnt_skip=0; cnt_force_diverged=0; cnt_force_unrelated=0
cnt_merge_diverged=0; cnt_merge_unrelated=0; cnt_fail=0

while IFS='|' read -r result status differ_type repo_path remote_url; do
    case "${result}:${differ_type}" in
          PUSH:*)          label="${COLOR_GREEN}[PUSH  :$(printf '%-10s' "${differ_type}")]  ${COLOR_RESET}"; cnt_push=$((cnt_push+1))
       ;; SKIP:*)          label="${COLOR_BLUE}[SKIP  :$(printf '%-10s' "${differ_type}")]  ${COLOR_RESET}"; cnt_skip=$((cnt_skip+1))
       ;; FORCE:DIVERGED)  label="${COLOR_YELL}[FORCE :DIVERGED  ]  ${COLOR_RESET}"; cnt_force_diverged=$((cnt_force_diverged+1))
       ;; FORCE:UNRELATED) label="${COLOR_RED}[FORCE :UNRELATED ]  ${COLOR_RESET}"; cnt_force_unrelated=$((cnt_force_unrelated+1))
       ;; MERGE:DIVERGED)  label="${COLOR_YELL}[MERGE :DIVERGED  ]  ${COLOR_RESET}"; cnt_merge_diverged=$((cnt_merge_diverged+1))
       ;; MERGE:UNRELATED) label="${COLOR_YELL}[MERGE :UNRELATED ]  ${COLOR_RESET}"; cnt_merge_unrelated=$((cnt_merge_unrelated+1))
       ;; FAIL:*)          label="${COLOR_RED}[FAIL  :$(printf '%-10s' "${differ_type}")]  ${COLOR_RESET}"; cnt_fail=$((cnt_fail+1))
       ;; *)               label="${COLOR_RED}[UNKNOWN          ]  ${COLOR_RESET}";;
    esac
    printf "${label}%-100s%-60s\n" "${remote_url}" "${repo_path}"
done < <(sort -t'|' -k1,1 "$FILE_PUSH")

# ── 최종 요약 ────────────────────────────────────────────────────────────────
echo ""
echo -e "${COLOR_BLUE}=== Summary ===${COLOR_RESET}"
echo "  COMPARE_BRANCH : $BRANCH_COMPARE"
echo "  DEST_BRANCH    : $BRANCH_DEST"
echo "  PUSH_OPTION    : $PUSH_OPTION"
echo ""
echo -e "    ${COLOR_GREEN}PUSH  (normal / new branch)${COLOR_RESET} : $(printf "%4d" $cnt_push)"
if [[ "$PUSH_OPTION" == "force" ]]; then
    echo -e "    ${COLOR_YELL}FORCE (DIVERGED)${COLOR_RESET}            : $(printf "%4d" $cnt_force_diverged)  (had common ancestor, remote overwritten)"
    echo -e "    ${COLOR_RED}FORCE (UNRELATED)${COLOR_RESET}           : $(printf "%4d" $cnt_force_unrelated)  (no common ancestor, remote history lost)"
else
    echo -e "    ${COLOR_YELL}MERGE (DIVERGED)${COLOR_RESET}            : $(printf "%4d" $cnt_merge_diverged)  (merged with common ancestor)"
    echo -e "    ${COLOR_YELL}MERGE (UNRELATED)${COLOR_RESET}           : $(printf "%4d" $cnt_merge_unrelated)  (merged via -s ours, local tree kept)"
fi
echo -e "    ${COLOR_BLUE}SKIP${COLOR_RESET}                        : $(printf "%4d" $cnt_skip)  (HEAD_SAME / HEAD_REMOTE)"
echo -e "    ${COLOR_RED}FAIL${COLOR_RESET}                        : $(printf "%4d" $cnt_fail)  (push/merge failed, check manually)"
echo -e "\n"
echo "push log: $FILE_PUSH"
