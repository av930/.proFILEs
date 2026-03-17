#!/bin/bash
# 생성된 gen-fin.xml 을 참조하여 repo forall로 모든 git에 대해서
# 1. remote를 등록하고
# 2. remote가 실제로 존재하는지 확인하고
# 3. remote에 실제 branch가 존재하는지 확인
# 이를 통해서 remote나 branch가 제대로 등록되지 않은 잘못된 git project가 존재하는지 확인하게 된다.
# 이후, remote만 존재하는 상황이, chipset code를 mirroring하기 가장 좋은 상황이 된다.

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
# 임시 파일 (repo forall 결과 수집용)
tmp_lookup=$(mktemp)    # gen-fin.xml에서 생성: project_name|remote_name|full_vgit_url
tmp_results=$(mktemp)   # repo forall 결과: sort_key|status|head_status|repo_path|remote_url

# gen-fin.xml에서 remote line에서 name -> fetch URL 매핑 추출
# repo forall은 default.xml를 참조하는데, 현재 remote는 devops_test로 되어 있어, REPO_REMOTE와 fetch url을 가져올수 없는 상태라 수동으로 가져옮
declare -A remote_fetch
while IFS='`' read -r rname fetch; do
    [[ -n "$rname" && -n "$fetch" ]] && remote_fetch["$rname"]="$fetch"
done < <(xmlstarlet sel -t -m "//remote" -v "@name" -o '`' -v "@fetch" -n "$GEN_FIN_XML" 2>/dev/null)

# gen-fin.xml에서 tmp_lookup파일 생성(형식: project_name|remote_name|full_remote_url)
while IFS='`' read -r pname ppath premote; do
    [[ -z "$pname" || -z "$ppath" || -z "$premote" ]] && continue
    fetch="${remote_fetch[$premote]:-}"
    [[ -n "$fetch" ]] && echo "${pname}|${premote}|${fetch}/${ppath}" >> "$tmp_lookup"
done < <(xmlstarlet sel -t -m "//project[@path]" -v "@name" -o '`' -v "@path" -o '`' -v "@remote" -n "$GEN_FIN_XML" 2>/dev/null)


# repo forall로 모든 git에서 remote 등록 및 확인
# HEREDOC + bash -s 사용 이유:
#   repo forall -c 는 기본적으로 /bin/sh 로 실행되어 bash 전용 문법([[]], <<<)이 동작하지 않을 수 있음
#   cat << EOF | bash -s 패턴으로 내부 스크립트를 명시적으로 bash에서 실행
# repo forall에서 사용할수 있도록 export
export BRANCH_NAME tmp_lookup tmp_results
# shellcheck disable=SC2016
repo forall -cj16 'cat << EOF | bash -s
    # gen-fin.xml lookup 파일에서 REPO_PROJECT에 해당하는 remote_name과 remote URL 조회
    # lookup 미발견: gen-fin.xml에 path/remote 미정의 → ERROR로 기록 후 스킵
    lookup_line=\$(grep "^$REPO_PROJECT|" "$tmp_lookup" | head -1)
    if [[ -z "\$lookup_line" ]]; then
        echo "3|ERROR_REMOTE|HEAD_N/A|$REPO_PROJECT|not in gen-fin.xml ($REPO_PROJECT)" >> "$tmp_results"
        exit 0
    fi
    IFS="|" read -r _ remote_name remote_url <<< "\$lookup_line"

    # 기존 vgit remote 제거 후 재등록 (idempotent)
    git remote get-url "\$remote_name" >/dev/null 2>&1 && git remote rm "\$remote_name"
    git remote add "\$remote_name" "\$remote_url"

    # vgit 서버에 remote repository 자체 존재 여부 확인
    if git ls-remote --exit-code "\$remote_name" HEAD >/dev/null 2>&1; then remote_status="exist"; else remote_status="none"; fi

    # vgit 서버에 대상 branch 존재 여부 확인
    if git ls-remote --exit-code "\$remote_name" "$BRANCH_NAME" >/dev/null 2>&1; then
        branch_status="exist"
    else
        branch_status="none"
    fi

    # 로컬 HEAD와 vgit remote branch HEAD 비교 (branch가 존재할 때만 의미 있음)
    # 판별 전략 (네트워크 비용 최소화):
    #   ① local_head == remote_head                              → HEAD_SAME     (SHA 직접 비교, 네트워크 없음)
    #   ② git rev-list HEAD | grep remote_head                   → HEAD_LOCAL    (로컬 히스토리 탐색, 네트워크 없음)
    #   ③ git fetch --shallow-since=<local HEAD 커밋날짜>         → 최소 fetch 후 merge-base로 정확 판별
    #      local HEAD 날짜 이후 커밋만 가져오므로 전체 fetch 대비 데이터 최소화
    #      HEAD_LOCAL은 ②에서 이미 판별하므로 여기선 불필요
    #      shallow fetch이므로 DIVERGED/UNRELATED 구분 불가 → HEAD_DIFFER로 통합
    #      - merge-base --is-ancestor local fetched              → HEAD_REMOTE   (remote가 앞서있음)
    #      - 그 외 (공통조상 있음/없음 모두)                     → HEAD_DIFFER   (shallow fetch로 구분 불가)
    #      - fetched_head 없음 또는 날짜 획득 불가               → HEAD_N/A
    # ※ git ls-remote 는 branch 지정 ("$BRANCH_NAME") 으로만 사용 → 전체 refs 스캔 금지
    if [[ "\$branch_status" == "exist" ]]; then
        local_head=\$(git rev-parse HEAD 2>/dev/null)
        remote_head=\$(git ls-remote "\$remote_name" "$BRANCH_NAME" 2>/dev/null | cut -f1)
        if   [[ -z "\$local_head" || -z "\$remote_head" ]]; then
            head_status="HEAD_N/A"                                                                                             # SHA 획득 불가
        elif [[ "\$local_head" == "\$remote_head" ]]; then
            head_status="HEAD_SAME"                                                                                            # 완전 동일
        elif git rev-list HEAD 2>/dev/null | grep -qm1 "^\${remote_head}"; then
            head_status="HEAD_LOCAL"                                                                                           # 로컬 히스토리에 remote HEAD 존재 → local이 앞서있음
        else
            # ①②로 판별 불가 → local HEAD 커밋 날짜 이후만 shallow fetch 후 merge-base로 정확 판별
            local_commit_date=\$(git log -1 --format="%cI" HEAD 2>/dev/null)
            if [[ -z "\$local_commit_date" ]]; then
                head_status="HEAD_N/A"                                                                                         # 날짜 획득 불가
            else
                git fetch --shallow-since="\$local_commit_date" "\$remote_name" "$BRANCH_NAME" >/dev/null 2>&1
                fetched_head=\$(git rev-parse FETCH_HEAD 2>/dev/null)
                if   [[ -z "\$fetched_head" ]];                                                    then head_status="HEAD_N/A"      # fetch 결과 없음
                elif git merge-base --is-ancestor "\$local_head" "\$fetched_head" 2>/dev/null;     then head_status="HEAD_REMOTE"   # local이 remote의 ancestor → remote가 앞서있음
                else head_status="HEAD_DIFFER"                                                                                     # shallow fetch로 DIVERGED/UNRELATED 구분 불가 → 통합
                fi
            fi
        fi
    else
        head_status="HEAD_N/A"  # branch 없음 → push 대상, HEAD 비교 불필요
    fi

    # 결과를 sort_key|status|head_status|path|url 형식으로 기록
    # sort_key: 1=EXIST_REMOTE(이상적), 2=EXIST_BRANCH(충돌), 3=ERROR_REMOTE
    if [[ "\$remote_status" == "exist" && "\$branch_status" == "exist" ]]; then
        echo "2|EXIST_BRANCH|\$head_status|$REPO_PATH|\$remote_url" >> "$tmp_results"
    elif [[ "\$remote_status" == "exist" && "\$branch_status" == "none" ]]; then
        echo "1|EXIST_REMOTE|\$head_status|$REPO_PATH|\$remote_url" >> "$tmp_results"
    else
        echo "3|ERROR_REMOTE|HEAD_N/A|$REPO_PATH|remote not found on vgit" >> "$tmp_results"
    fi

EOF
' 2>/dev/null

echo "=== Results ==="
# tmp_results를 sort_key 기준으로 정렬하여 출력
# 출력 순서: 1=EXIST_REMOTE → 2=EXIST_BRANCH → 3=ERROR_REMOTE
cnt_remote_branch=0
cnt_remote_only=0
cnt_skip=0
cnt_head_same=0      # remote HEAD == local HEAD (이미 동기화됨)
cnt_head_remote=0    # remote가 local을 포함하고 앞서있음
cnt_head_local=0     # local이 remote를 포함하고 앞서있음 (push 가능, rev-list 판별)
cnt_head_differ=0    # shallow fetch로 DIVERGED/UNRELATED 구분 불가 (full fetch 필요)
cnt_head_na=0        # SHA 획득 불가 또는 날짜 획득 불가 (HEAD_N/A)

# ── 출력 포맷 설명 ───────────────────────────────────────────────────────────
# printf 포맷: "[LABEL]%-100s%-60s\n"
#   [LABEL]    : 상태 라벨 (색상 포함, 26자 고정폭으로 정렬)
#   %-100s     : remote_url을 100자 너비로 왼쪽 정렬 (짧으면 공백 패딩, 초과 시 그냥 이어서 출력)
#   %-60s      : repo_path를 60자 너비로 왼쪽 정렬
#   총 출력 너비 = label(26) + url(100) + path(60) = 186자
# ────────────────────────────────────────────────────────────────────────────
while IFS='|' read -r _ status head_status repo_path remote_url; do
    # 상태별 라벨 및 카운터 업데이트
    case "${status}:${head_status}" in
          EXIST_REMOTE:*)           label="${COLOR_GREEN}[EXIST_remote:BRANCH_NEED]  ${COLOR_RESET}"; cnt_remote_only=$((cnt_remote_only+1))
       ;; EXIST_BRANCH:HEAD_SAME)   label="${COLOR_GREEN}[EXIST_branch:HEAD_SAME  ]  ${COLOR_RESET}"; cnt_remote_branch=$((cnt_remote_branch+1)); cnt_head_same=$((cnt_head_same+1))
       ;; EXIST_BRANCH:HEAD_REMOTE) label="${COLOR_YELL}[EXIST_branch:HEAD_REMOTE]  ${COLOR_RESET}"; cnt_remote_branch=$((cnt_remote_branch+1)); cnt_head_remote=$((cnt_head_remote+1))
       ;; EXIST_BRANCH:HEAD_LOCAL)  label="${COLOR_YELL}[EXIST_branch:HEAD_LOCAL ]  ${COLOR_RESET}"; cnt_remote_branch=$((cnt_remote_branch+1)); cnt_head_local=$((cnt_head_local+1))
       ;; EXIST_BRANCH:HEAD_DIFFER) label="${COLOR_RED}[EXIST_branch:HEAD_DIFFER]  ${COLOR_RESET}"; cnt_remote_branch=$((cnt_remote_branch+1)); cnt_head_differ=$((cnt_head_differ+1))
       ;; EXIST_BRANCH:HEAD_N/A)    label="${COLOR_BLUE}[EXIST_branch:HEAD_N/A   ]    ${COLOR_RESET}"; cnt_remote_branch=$((cnt_remote_branch+1)); cnt_head_na=$((cnt_head_na+1))
       ;; ERROR_REMOTE:*)           label="${COLOR_RED}[ERROR_remote:REPO_NEED  ]    ${COLOR_RESET}"; cnt_skip=$((cnt_skip+1));;
    esac
    # label 출력 후 remote_url 100자 왼쪽 정렬, repo_path 60자 왼쪽 정렬
    printf "${label}%-100s%-60s\n" "${remote_url}" "${repo_path}"
done < <(sort -t'|' -k1,1n "$tmp_results")

echo ""
# 최종 요약 출력
total_count=$(wc -l < "$tmp_results" 2>/dev/null || echo 0)
gen_fin_count=$(xmlstarlet sel -t -m "//project" -v "@name" -n "$GEN_FIN_XML" 2>/dev/null | wc -l)
# branch 충돌만 FAIL 판정 (REMOTE only는 push 가능하므로 에러 아님)
error_count=$cnt_remote_branch

echo -e "${COLOR_BLUE}=== Summary ===${COLOR_RESET}"
echo "  GEN_FIN_XML : $(readlink -f "$GEN_FIN_XML")"
echo "  BRANCH_NAME : $BRANCH_NAME"
echo ""
echo "  Total processed (repo forall): $total_count"
echo -e "    ${COLOR_GREEN}REMOTE only exist${COLOR_RESET}              : $(printf "%4d" $cnt_remote_only) (new branch must be created)"
echo -e "    ${COLOR_RED}ERROR_REMOTE (err in manifest)${COLOR_RESET} : $(printf "%4d" $cnt_skip) (err, must check gen-fin.xml)"
echo -e "    ${COLOR_YELL}REMOTE + BRANCH both exist${COLOR_RESET}     : $(printf "%4d" $cnt_remote_branch) (branch is ready)"
echo ""
echo "  HEAD status (remote vs local): $cnt_remote_branch"
echo -e "    ${COLOR_GREEN}HEAD_SAME${COLOR_RESET}      : $(printf "%4d" $cnt_head_same)  (local == remote >>> no need to push, already synced)"
echo -e "    ${COLOR_YELL}HEAD_REMOTE${COLOR_RESET}    : $(printf "%4d" $cnt_head_remote)  (remote includes local >>> no need to push, remote advanced)"
echo -e "    ${COLOR_YELL}HEAD_LOCAL${COLOR_RESET}     : $(printf "%4d" $cnt_head_local)  (local includes remote >>> need to push, local advanced)"
echo -e "    ${COLOR_RED}HEAD_DIFFER${COLOR_RESET}    : $(printf "%4d" $cnt_head_differ)  (diverged or unrelated, shallow fetch only >>> need full fetch to determine)"
echo -e "    ${COLOR_BLUE}HEAD_N/A${COLOR_RESET}       : $(printf "%4d" $cnt_head_na)  (cannot determine, SHA or date unavailable)"
echo -e "\n"
echo "result log: $tmp_results"
#rm -f "$tmp_results" "$tmp_lookup"
