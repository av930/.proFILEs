#!/bin/bash
## ========================================================================== 
##  checkSRC_URI.sh : Yocto 레시피 SRC_URI 접근성 검사 도구
##  - 지정한 repo project root 아래의 .bb/.bbappend/.bbclass/.inc/.conf 파일에서
##    SRC_URI에 할당된 URI를 추출하여 실제 접근 가능한지 검사하고 결과를 출력함
##  사용법: checkSRC_URI.sh <root_dir> [-t TIMEOUT] [-j JOBS] [-v] [-l]
## ========================================================================== 
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NCOL='\033[0m'

TIMEOUT=10
JOBS=32
VERBOSE=0
LIST_ONLY=0
ROOT_DIR=""

usage() {
        cat <<EOF
usage: $(basename "$0") <root_dir> [options]
    root_dir     : Target repo project root directory
    -t TIMEOUT   : URL access timeout (seconds, default: 10)
    -j JOBS      : Number of parallel threads (default: 32)
    -v           : Print SKIP (unverifiable) URIs
    -l           : Only print extracted URIs (no access check)
    -h           : Show this help
example:
    $(basename "$0") /path/to/yocto/project
    $(basename "$0") /path/to/yocto/project -t 5 -j 16 -v    
output:
    OKAY /path/to/file.bb  http://example.com/file.tar.gz
    FAIL /path/to/file.bb  http://example.com/file.tar.gz
    SKIP /path/to/file.bb  \${VAR}/file.tar.gz             (with -v)
EOF
        exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) TIMEOUT="$2"; shift 2 ;;
        -j) JOBS="$2";    shift 2 ;;
        -v) VERBOSE=1;    shift   ;;
        -l) LIST_ONLY=1;  shift   ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *)  ROOT_DIR="$1"; shift  ;;
    esac
done

[[ -z "$ROOT_DIR" ]]  && { echo "Error: root_dir argument is required"; usage; }
[[ -d "$ROOT_DIR" ]]  || { echo "Error: '$ROOT_DIR' is not a valid directory"; exit 1; }
command -v gawk >/dev/null 2>&1 || { echo "Error: gawk is required (sudo apt install gawk)"; exit 1; }
[[ $LIST_ONLY -eq 0 ]] && command -v curl >/dev/null 2>&1 \
    || true  ## curl is not needed in -l mode

## ─────────────────────────────────────────────────────────────────────────
##  BitBake URI 파라미터 제거 (;name=xxx;branch=xxx;protocol=https 등)
## ─────────────────────────────────────────────────────────────────────────
strip_bb_params() { printf '%s' "${1%%;*}"; }

## ─────────────────────────────────────────────────────────────────────────
##  URI 접근성 확인
##  $1 = raw URI (BitBake 파라미터 포함 가능)
##  $2 = .bb 파일이 위치한 디렉토리 (file:// 상대경로 해석용)
##  $3 = PN (Package Name, 예: glibc) — BitBake FILESPATH의 ${PN} 서브디렉토리 탐색용
##  return: 0=OKAY, 1=FAIL, 2=SKIP(검증불가 scheme)
## ─────────────────────────────────────────────────────────────────────────
check_uri() {
    local raw="$1" bb_dir="${2:-}" pn="${3:-}"
    local uri; uri=$(strip_bb_params "$raw")

    case "$uri" in
        http://*|https://*)
            local code
            code=$(curl --silent --head --max-time "$TIMEOUT" \
                        --location --output /dev/null \
                        --write-out '%{http_code}' "$uri" 2>/dev/null) || true
            [[ "$code" =~ ^[23][0-9]{2}$ ]] && return 0 || return 1
            ;;
        ftp://*)
            curl --silent --max-time "$TIMEOUT" \
                 --output /dev/null "$uri" 2>/dev/null && return 0 || return 1
            ;;
        file://*)
            local fpath="${uri#file://}"
            if [[ "$fpath" == /* ]]; then
                ## 절대경로: 그대로 검사
                [[ -e "$fpath" ]] && return 0 || return 1
            else
                ## 상대경로: BitBake FILESPATH 관례 순서로 탐색
                ##   1. <recipedir>/                    (THISDIR)
                ##   2. <recipedir>/files/              (THISDIR/files)
                ##   3. <recipedir>/<PN>/               (THISDIR/${PN})
                if [[ -n "$bb_dir" ]] && { \
                    [[ -e "$bb_dir/$fpath" ]] || \
                    [[ -e "$bb_dir/files/$fpath" ]] || \
                    { [[ -n "$pn" ]] && [[ -e "$bb_dir/$pn/$fpath" ]]; }; }; then
                    return 0
                else
                    return 1
                fi
            fi
            ;;
        git://*|gitsm://*)
            ## git ls-remote 로 원격 저장소 존재 여부 확인
            GIT_TERMINAL_PROMPT=0 timeout "$TIMEOUT" \
                git ls-remote --quiet --exit-code \
                "${uri%%;*}" HEAD &>/dev/null && return 0 || return 1
            ;;
        *) return 2 ;;  ## svn://, cvs:// 등 지원하지 않는 scheme → SKIP
    esac
}

## ─────────────────────────────────────────────────────────────────────────
##  병렬 실행 워커 (xargs -P 로 호출됨)
##  $1 = 절대경로 FILE,  $2 = URI
##  출력: STATUS\tFILE\tURI  (OKAY / FAIL / SKIP)
## ─────────────────────────────────────────────────────────────────────────
check_one() {
    local FILE="$1" URI="$2"
    local BB_DIR; BB_DIR=$(dirname "$FILE")
    ## PN 추출: glibc_2.34.bb → glibc,  glibc_%.bbappend → glibc
    local PN; PN=$(basename "$FILE"); PN="${PN%%_*}"
    local RC=0; check_uri "$URI" "$BB_DIR" "$PN" || RC=$?
    case $RC in
        0) printf 'OKAY\t%s\t%s\n' "$FILE" "$URI" ;;
        1) printf 'FAIL\t%s\t%s\n' "$FILE" "$URI" ;;
        2) printf 'SKIP\t%s\t%s\n' "$FILE" "$URI" ;;
    esac
}
export TIMEOUT
export -f strip_bb_params check_uri check_one

## ─────────────────────────────────────────────────────────────────────────
##  gawk 스크립트: .bb 계열 파일에서 SRC_URI 할당 값을 추출 (multi-line 지원)
##
##  지원 구문:
##    SRC_URI  = / ?= / ??= / := / += / =+ / .= / =.     (기본 할당)
##    SRC_URI:append   = / SRC_URI:prepend  = / SRC_URI:remove  = (modern)
##    SRC_URI_append   = / SRC_URI_prepend  = / SRC_URI_remove  = (legacy)
##  제외 구문:
##    SRC_URI[md5sum] / SRC_URI[sha256sum]  등 체크섬 변수
##    # 로 시작하는 주석 라인
##
##  출력 형식: <파일명>\t<URI토큰>
## ─────────────────────────────────────────────────────────────────────────
read -r -d '' AWK_SCRIPT <<'AWKEOF' || true
BEGIN { OFS = "\t"; collecting = 0 }

## 주석 라인: 수집 상태 초기화 후 스킵
/^[[:space:]]*#/ { collecting = 0; next }

## SRC_URI 할당 라인 감지
## SRC_URI[md5sum] / SRC_URI[sha256sum] 등 체크섬 변수는 제외
/^[[:space:]]*SRC_URI/ && !/^[[:space:]]*SRC_URI\[/ && /=/ {
    collecting = 0

    ## 할당 연산자 위치 탐색 (우선순위 내림차순: ??= > ?= > += > =+ > .= > =. > := > =)
    if (!match($0, /[?][?]=|[?]=|[+]=|=[+]|[.]=|=[.]|:=|=/)) next

    value = substr($0, RSTART + RLENGTH)

    ## 라인 연속 여부는 raw value 기준으로 확인 (따옴표 제거 전)
    cont = (value ~ /\\[[:space:]]*$/)

    ## 따옴표·역슬래시·앞뒤 공백 제거
    gsub(/^[[:space:]"\\]+|[[:space:]"\\]+$/, "", value)

    if (value != "") {
        n = split(value, toks, /[[:space:]]+/)
        for (i = 1; i <= n; i++)
            if (toks[i] != "" && toks[i] !~ /^[\\"]$/)
                print FILENAME, toks[i]
    }
    collecting = cont
    next
}

## 연속 라인 처리 (\로 이어지는 후속 라인)
collecting {
    cont = ($0 ~ /\\[[:space:]]*$/)
    value = $0
    gsub(/^[[:space:]"\\]+|[[:space:]"\\]+$/, "", value)

    if (value != "") {
        n = split(value, toks, /[[:space:]]+/)
        for (i = 1; i <= n; i++)
            if (toks[i] != "" && toks[i] !~ /^[\\"]$/)
                print FILENAME, toks[i]
    }
    collecting = cont
}
AWKEOF

## ─────────────────────────────────────────────────────────────────────────
##  메인: 파일 검색 → SRC_URI 추출 → [접근성 검사] → 결과 출력
## ─────────────────────────────────────────────────────────────────────────
echo "Analyzing SRC_URI in target directory. Please wait..."
echo "======================================"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

## null-delimited FILE\0URI\0 pairs (실제 검사 대상)
PAIRS_FILE="$WORK_DIR/pairs"
## STATUS\tFILE\tURI lines (SKIP: 변수 포함 URI)
SKIP_FILE="$WORK_DIR/skips"
## STATUS\tFILE\tURI lines (parallel check 결과)
RESULTS_FILE="$WORK_DIR/results"
touch "$PAIRS_FILE" "$SKIP_FILE" "$RESULTS_FILE"

## ── Phase 1: URI 추출 및 분류 ──────────────────────────────────────────
while IFS=$'\t' read -r FILE URI; do
    [[ -z "$URI" ]] && continue

    ## URI scheme (xxx://) 형태가 아닌 토큰은 스킵 (BitBake 키워드 등)
    [[ "$URI" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]] || continue

    if [[ $LIST_ONLY -eq 1 ]]; then
        ## -l 모드: 추출된 URI를 그대로 출력 (검사 없음)
        printf '%s\t%s\n' "$FILE" "$URI"
        continue
    fi

    ## 변수 참조(${...}) 포함 → BitBake evaluation 없이는 검증 불가 → SKIP
    if [[ "$URI" == *'${'* ]]; then
        printf '%s\t%s\n' "$FILE" "$URI" >> "$SKIP_FILE"
    else
        printf '%s\0%s\0' "$FILE" "$URI" >> "$PAIRS_FILE"
    fi
done < <(
    find "$ROOT_DIR" -type f \( \
        -name "*.bb"       -o \
        -name "*.bbappend" -o \
        -name "*.bbclass"  -o \
        -name "*.inc"      -o \
        -name "*.conf"     \
    \) -print0 \
    | xargs -0 -r gawk "$AWK_SCRIPT" 2>/dev/null
)

## -l (list only) 모드는 여기서 종료
[[ $LIST_ONLY -eq 1 ]] && exit 0

## ── Phase 2: 접근성 검사 (병렬, JOBS threads) ────────────────────────────
[[ -s "$PAIRS_FILE" ]] && \
    xargs -0 -n 2 -P "$JOBS" bash -c 'check_one "$@"' -- \
        < "$PAIRS_FILE" >> "$RESULTS_FILE"

## ── Phase 3: 결과 정렬 → 파일 저장 (색상 없음) + 화면 출력 (색상) ────────

## 결과 저장 파일 (현재 디렉토리)
OUT_FILE="${PWD}/checkSRC_URI_$(date +%Y%m%d_%H%M%S).txt"
SORTED_ALL="$WORK_DIR/sorted_all"

## SKIP_FILE (FILE\tURI) 를 STATUS\tFILE\tURI 형식으로 변환 후
## RESULTS_FILE 과 병합 → 정렬 (SKIP=1 > FAIL=2 > OKAY=3, 이후 FILE, URI 순)
{
    awk -F'\t' '{print "1\tSKIP\t"$1"\t"$2}' "$SKIP_FILE"
    awk -F'\t' '
        $1=="SKIP" {print "1\t"$0}
        $1=="FAIL" {print "2\t"$0}
        $1=="OKAY" {print "3\t"$0}
    ' "$RESULTS_FILE"
} | sort -t$'\t' -k1,1n -k3,3 -k4,4 \
  | awk -F'\t' 'OFS="\t" {print $2, $3, $4}' \
  > "$SORTED_ALL"

## ── 파일 저장 (색상 없음, 탭 구분) ──────────────────────────────────────
{
    printf "# checkSRC_URI result\n"
    printf "# root : %s\n" "$ROOT_DIR"
    printf "# date : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "# %-6s\t%-s\t%s\n" "STATUS" "FILE" "URI"
    cat "$SORTED_ALL"
} > "$OUT_FILE"

## ── Phase 4: 통계 + FAIL/SKIP 공통 base URL 분석 ────────────────────────
CYAN='\033[0;36m'
NCOL='\033[0m'
echo -e "${CYAN}======================================${NCOL}"
printf "Output file: %s\n" "$OUT_FILE"
echo -e "${CYAN}======================================${NCOL}"

gawk -F'\t' -v CYAN="\033[0;36m" -v GREEN="\033[0;32m" -v RED="\033[0;31m" -v YELLOW="\033[1;33m" -v NCOL="\033[0m" '
/^#/ { next }

## 두 문자열의 공통 prefix를 계산
function common_prefix(lhs, rhs,    i, n, out) {
    n = (length(lhs) < length(rhs)) ? length(lhs) : length(rhs)
    out = ""
    for (i = 1; i <= n; i++) {
        if (substr(lhs, i, 1) != substr(rhs, i, 1)) break
        out = out substr(lhs, i, 1)
    }
    return out
}

## 공통 prefix를 경로 경계(/) 기준으로 정리
function trim_prefix_to_boundary(prefix,    trimmed) {
    trimmed = prefix
    sub(/[^\/]*$/, "", trimmed)
    return trimmed
}

## 그룹 비교용 URL에서 path 내부의 중복 슬래시를 정규화
function normalize_group_url(url,    prefix, rest) {
    if (match(url, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)) {
        prefix = substr(url, 1, RLENGTH)
        rest = substr(url, RLENGTH + 1)
        sub(/^https:\/\//, "http://", prefix)
        while (gsub(/\/\//, "/", rest)) {}
        return prefix rest
    }
    while (gsub(/\/\//, "/", url)) {}
    return url
}

## 그룹 키로 사용할 만한 prefix인지 확인
function is_groupable_prefix(prefix) {
    if (prefix ~ /^file:\/\//) return 1
    if (prefix ~ /^http:\/\/[^\/]+\/.+\/$/) return 1
    if (prefix ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/]+\/.+\/$/) return 1
    return 0
}

## 통계 집계
{
    st = $1; url = $3
    status_count[st]++
    total++
    ## scheme 추출 (xxx:// 형식)
    if (match(url, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)) {
        sch = substr(url, 1, RLENGTH)
        scheme_cnt[st][sch]++
        all_sch[sch] = 1
    }
}

## FAIL/SKIP: 원본 URL을 모아서 공통 prefix 기반으로 그룹화
($1 == "FAIL" || $1 == "SKIP") {
    url = $3
    sub(/;.*$/, "", url)    ## BitBake 파라미터 제거
    sub(/[?#].*$/, "", url)  ## query/fragment 제거
    norm_url = normalize_group_url(url)
    raw_total[norm_url]++
    raw_by_st[$1, norm_url]++
    raw_urls[norm_url] = 1
}

END {
    ## 전체 통계
    printf "\n%s== Statistics ===============================%s\n", CYAN, NCOL
    printf "  %-6s : %d\n", "Total", total
    printf "  %s%-6s%s : %d (%s)\n", GREEN, "OKAY", NCOL, status_count["OKAY"]+0, "URI was reachable and the access check succeeded"
    printf "  %s%-6s%s : %d (%s)\n", RED,   "FAIL", NCOL, status_count["FAIL"]+0, "URI was unreachable due to network issues, timeout, server response, or invalid path"
    printf "  %s%-6s%s : %d (%s)\n", YELLOW,"SKIP", NCOL, status_count["SKIP"]+0, "URI could not be validated statically because it uses variables or an unsupported scheme"

    ## Scheme별 분류표
    printf "\n%s== Scheme Summary ===========================%s\n", CYAN, NCOL
    printf "  %-16s  %s%6s%s  %s%6s%s  %s%6s%s\n", "scheme",
        GREEN, "OKAY", NCOL,
        RED,   "FAIL", NCOL,
        YELLOW,"SKIP", NCOL
    printf "  %-16s  %6s  %6s  %6s\n", "----------------", "------", "------", "------"
    n = asorti(all_sch, sorted_sch)
    for (i = 1; i <= n; i++) {
        s = sorted_sch[i]
        printf "  %-16s  %6d  %6d  %6d\n", s,
            scheme_cnt["OKAY"][s]+0,
            scheme_cnt["FAIL"][s]+0,
            scheme_cnt["SKIP"][s]+0
    }

    ## FAIL/SKIP 공통 base URL (2개 이상인 것만)
    printf "\n%s== Common base URL for FAIL/SKIP (count >= 2) ==%s\n", CYAN, NCOL
    found = 0
    raw_n = asorti(raw_urls, sorted_urls)
    group_id = 0
    group_key = ""
    for (i = 1; i <= raw_n; i++) {
        url = sorted_urls[i]
        if (group_id == 0) {
            group_id = 1
            prefix_by_gid[group_id] = url
            url_gid[url] = group_id
            continue
        }

        candidate = trim_prefix_to_boundary(common_prefix(prefix_by_gid[group_id], url))
        if (is_groupable_prefix(candidate)) {
            prefix_by_gid[group_id] = candidate
            url_gid[url] = group_id
        } else {
            group_id++
            prefix_by_gid[group_id] = url
            url_gid[url] = group_id
        }
    }

    for (url in raw_urls) {
        gid = url_gid[url]
        group_total[gid] += raw_total[url]
        group_fail[gid]  += raw_by_st["FAIL", url] + 0
        group_skip[gid]  += raw_by_st["SKIP", url] + 0
    }

    for (gid = 1; gid <= group_id; gid++) {
        base = prefix_by_gid[gid]
        if (group_total[gid] >= 2) {
            results[++found] = sprintf("%05d\t[FAIL=%d SKIP=%d total=%d]  %s",
                group_total[gid],
                group_fail[gid] + 0,
                group_skip[gid] + 0,
                group_total[gid],
                base)
        }
    }
    ## 내림차순 정렬 출력
    n = asort(results, sorted_res)
    for (i = n; i >= 1; i--) {
        sub(/^[0-9]+\t/, "", sorted_res[i])
        printf "  %s\n", sorted_res[i]
    }
    if (found == 0) printf "  (none)\n"
}
' "$OUT_FILE"
