#!/bin/bash
set -euo pipefail

# ==============================================================================
# Yocto Build Log 시간 분석 및 환경 검사 스크립트
# 사용법: ./analyze_buildtime.sh <logfile_path_or_url>
# 목적: Yocto 환경 설정 확인, 리소스 측정 및 로그 시간 파싱을 통해 병목구간 탐색
# ==============================================================================

readonly red='\e[0;31m'
readonly RED='\e[1;31m'
readonly green='\e[0;32m'
readonly GREEN='\e[1;32m'
readonly yellow='\e[0;33m'
readonly YELLOW='\e[1;33m'
readonly blue='\e[0;34m'
readonly BLUE='\e[1;34m'
readonly cyan='\e[0;36m'
readonly CYAN='\e[1;36m'
readonly magenta='\e[0;35m'
readonly NCOL='\e[0m'

readonly TAG_OK="${GREEN}[OKAY]${NCOL}"
readonly TAG_FAIL="${RED}[FAIL]${NCOL}"
readonly TAG_WARN="${YELLOW}[WARN]${NCOL}"
readonly SSH_OPTS=(-q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)
readonly DEFAULT_TZ="Asia/Seoul"

# Timestamp 처리를 위한 공용 regexp 변수
readonly TIMESTAMP_OPTIONAL="(^[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+)?"  # 타임스탬프 옵션 매칭

# 종료 시 임시 파일 정리를 위한 글로벌 변수
[[ -n "${PATH_TEMP_LOG:-}" && -f "$PATH_TEMP_LOG" ]] && rm -f "$PATH_TEMP_LOG"
readonly PATH_TEMP_LOG=$(mktemp)

# 스크립트 종료 핸들러
cleanup() {
    [[ -f "$PATH_TEMP_LOG" ]] && rm -f "$PATH_TEMP_LOG"
}
trap cleanup EXIT

# 원격/로컬 공통 처리
run_io() {
    local mode="$1" target_ip="$2" arg1="${3:-}" arg2="${4:-}"
    case "$mode" in
        ssh) ssh "${SSH_OPTS[@]}" "$target_ip" "$arg1" 2>/dev/null
    ;; exec) if [[ -n "$target_ip" ]]; then run_io ssh "$target_ip" "$arg1"; else eval "$arg1"; fi
    ;; grep) grep -aE "$arg1" "$arg2" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g'
    ;; test) if [[ -n "$target_ip" ]]; then run_io ssh "$target_ip" "test -$arg2 '$arg1'" >/dev/null; else { [[ "$arg2" == "f" ]] && [[ -f "$arg1" ]] || [[ -d "$arg1" ]]; }; fi
    ;; size) if [[ -n "$target_ip" ]]; then run_io ssh "$target_ip" "du -sh '$arg1' 2>/dev/null | awk '{print \$1}'"; else du -sh "$arg1" 2>/dev/null | awk '{print $1}'; fi
    ;; mtime) if [[ -n "$target_ip" ]]; then run_io ssh "$target_ip" "stat -c %Y '$arg1'"; else stat -c %Y "$arg1"; fi
    esac
}

can_ssh_remote() {
    local target_ip="$1"
    [[ -z "$target_ip" ]] && return 0
    run_io ssh "$target_ip" "true" >/dev/null 2>&1
}

print_log_detect_line() {
    local label="$1" line="$2"
    [[ -n "$line" ]] && printf "  - Detected %s line: %s\n" "$label" "$line"
}

print_remote_unavailable() {
    local scope="$1" target_ip="$2"
    echo -e "${RED}[FAIL] ${scope} unavailable: SSH connection to ${target_ip} failed${NCOL}"
}

extract_logged_var_value() {
    local var_name="$1" log_file="$2"
    grep -aE "^${TIMESTAMP_OPTIONAL}[[:space:]]*([+][[:space:]]+)?(export[[:space:]]+)?${var_name}[[:space:]]*[?:]?=" "$log_file" 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g'
}

extract_logged_assignment_value() {
    local var_name="$1" log_file="$2"
    grep -aE "^${TIMESTAMP_OPTIONAL}[[:space:]]*([+][[:space:]]+)?(export[[:space:]]+)?${var_name}=" "$log_file" 2>/dev/null | head -1 | sed 's/.*=//;s/^"//;s/"$//;s/'\''//g'
}

infer_build_dir_from_deploy_images() {
    local log_file="$1" deploy_path=""
    deploy_path=$(grep -aoE '/[^[:space:]]*/deploy/images/[^[:space:]]*' "$log_file" 2>/dev/null | head -1 | sed 's|/deploy/images/.*|/deploy/images|' || echo "")
    [[ -z "$deploy_path" ]] && return 1
    dirname "$(dirname "$(dirname "$deploy_path")")"
}

wrap_block_for_column() {
    local block="$1" width="$2" line
    while IFS= read -r line; do
        if [[ "$line" == "__SECTION_DIVIDER__" ]]; then
            printf "%s\n" "$line"
        elif [[ -z "$line" ]]; then
            printf "\n"
        else
            printf "%s\n" "$line" | fold -s -w "$width"
        fi
    done <<< "$block"
}

# 두 시각(HH:MM:SS) 간의 시간차를 계산하여 HH:MM:SS 형식으로 반환
# 파라미터: $1=start_time, $2=end_time
# 반환: HH:MM:SS 형식 문자열 (printf로 출력)
calc_duration() {
    local start="$1" end="$2"
    [[ -z "$start" || -z "$end" ]] && return
    local diff
    diff=$(calc_duration_seconds "$start" "$end")
    printf "%02d:%02d:%02d" $((diff/3600)) $((diff%3600/60)) $((diff%60))
}

# 두 시각(HH:MM:SS) 간의 시간차를 초 단위로 반환
calc_duration_seconds() {
    local start="$1" end="$2"
    [[ -z "$start" || -z "$end" ]] && { echo 0; return; }

    local s_sec e_sec
    s_sec=$(date -u -d "1970-01-01 $start" +"%s" 2>/dev/null || echo 0)
    e_sec=$(date -u -d "1970-01-01 $end" +"%s" 2>/dev/null || echo 0)
    (( e_sec < s_sec )) && e_sec=$((e_sec + 86400))
    echo $((e_sec - s_sec))
}

# 로그에서 패턴이 처음 등장한 시각(HH:MM:SS) 추출
extract_first_timed_match() {
    local pattern="$1" log_file="$2"
    grep -aEi -m1 "$pattern" "$log_file" 2>/dev/null | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || true
}

# 구간 소요 시간을 정해진 형식으로 출력
print_duration_segment() {
    local label="$1" start_time="$2" end_time="$3" total_sec="$4" duration="" diff=0 pct_str="[N/A]"
    if [[ -n "$start_time" && -n "$end_time" ]]; then
        duration=$(calc_duration "$start_time" "$end_time")
        diff=$(calc_duration_seconds "$start_time" "$end_time")
        [[ "$total_sec" -gt 0 ]] && pct_str=$(awk -v diff="$diff" -v total="$total_sec" 'BEGIN { printf "[%.1f%%]", (diff * 100) / total }')
        printf "  - %-35s: %8s  %8s (%s ~ %s)\n" "$label" "$duration" "$pct_str" "$start_time" "$end_time"
    else
        printf "  - %-35s: %8s  %8s (%s)\n" "$label" "N/A" "$pct_str" "boundary not found in log"
    fi
}

# 2열 출력용 블록 문자열 생성
make_section_block() {
    local title="$1" body="${2:-}" header subtitle
    title=${title//\\n/$'\n'}
    title=${title//\\t/$'\t'}
    body=${body//\\n/$'\n'}
    body=${body//\\t/$'\t'}

    if [[ "$title" == *$'\n'* ]]; then
        header=${title%%$'\n'*}
        subtitle=${title#*$'\n'}
        subtitle=$(printf "%s" "$subtitle" | sed 's/[[:space:]]*$//')
    else
        header="$title"
        subtitle=""
    fi

    header=$(printf "%s" "$header" | sed 's/[[:space:]]*$//')
    body=$(printf "%s" "$body" | sed 's/[[:space:]]*$//')

    printf "%s\n" "$header"
    if [[ -n "$subtitle" ]]; then
        # Handle multi-line subtitle with proper indentation
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf "    %s\n" "$line"
        done <<< "$subtitle"
    fi
    [[ -n "$body" ]] && printf "__SECTION_DIVIDER__\n%s\n" "$body"
}

# 여러줄 문자열을 2열로 정렬 출력
print_two_column_sections() {
    local left_block="$1" right_block="${2:-}" num_term_cols num_col_width divider
    local -a left_lines=() right_lines=()
    local idx max_lines left_line right_line
    num_term_cols=$(tput cols 2>/dev/null || echo 220)
    [[ "$num_term_cols" -lt 220 ]] && num_term_cols=220
    num_col_width=$(( (num_term_cols - 4) / 2 ))
    [[ "$num_col_width" -lt 108 ]] && num_col_width=108
    divider="  $(printf '%*s' $((num_col_width - 2)) '' | tr ' ' '-')"

    if [[ -n "$right_block" ]]; then
        left_block=$(wrap_block_for_column "$left_block" "$num_col_width")
        right_block=$(wrap_block_for_column "$right_block" "$num_col_width")
        mapfile -t left_lines <<< "$left_block"
        mapfile -t right_lines <<< "$right_block"
        max_lines=${#left_lines[@]}
        [[ ${#right_lines[@]} -gt $max_lines ]] && max_lines=${#right_lines[@]}

        for ((idx=0; idx<max_lines; idx++)); do
            left_line="${left_lines[idx]:-}"
            right_line="${right_lines[idx]:-}"
            [[ "$left_line" == "__SECTION_DIVIDER__" ]] && left_line="$divider"
            [[ "$right_line" == "__SECTION_DIVIDER__" ]] && right_line="$divider"
            printf "%-${num_col_width}s    %s\n" "$left_line" "$right_line"
        done
    else
        left_block=$(wrap_block_for_column "$left_block" "$num_col_width")
        while IFS= read -r left_line; do
            [[ "$left_line" == "__SECTION_DIVIDER__" ]] && left_line="$divider"
            printf "%s\n" "$left_line"
        done <<< "$left_block"
    fi
}

# Jenkins build API 에서 시작/종료 시각 계산
# 파라미터: $1=build_url_or_api_url, $2=timezone(optional)
show_jenkins_build_time() {
    local input_url="$1" tz_name="${2:-$DEFAULT_TZ}"
    local base_url api_url api_json timestamp_ms duration_ms result start_sec end_sec start_time end_time

    if [[ "$input_url" =~ ^https?://[^/]+/.*/[0-9]+ ]]; then
        base_url="${BASH_REMATCH[0]}"
    else
        echo -e "$TAG_FAIL Invalid Jenkins build URL: $input_url"
        return 1
    fi

    api_url="${base_url%/}/api/json?tree=number,timestamp,duration,result,url"
    api_json=$(curl -skL "$api_url")
    [[ -z "$api_json" ]] && { echo -e "$TAG_FAIL Failed to fetch Jenkins API: $api_url"; return 1; }

    if command -v jq >/dev/null 2>&1; then
        timestamp_ms=$(echo "$api_json" | jq -r '.timestamp // empty')
        duration_ms=$(echo "$api_json" | jq -r '.duration // empty')
        result=$(echo "$api_json" | jq -r '.result // "UNKNOWN"')
    else
        timestamp_ms=$(echo "$api_json" | grep -oP '"timestamp"\s*:\s*\K[0-9]+' | head -1)
        duration_ms=$(echo "$api_json" | grep -oP '"duration"\s*:\s*\K[0-9]+' | head -1)
        result=$(echo "$api_json" | grep -oP '"result"\s*:\s*"\K[^"]+' | head -1)
        [[ -z "$result" ]] && result="UNKNOWN"
    fi

    [[ ! "$timestamp_ms" =~ ^[0-9]+$ ]] && { echo -e "$TAG_FAIL timestamp not found in API response"; return 1; }
    [[ ! "$duration_ms" =~ ^[0-9]+$ ]] && { echo -e "$TAG_FAIL duration not found in API response"; return 1; }

    start_sec=$((timestamp_ms / 1000))
    end_sec=$(((timestamp_ms + duration_ms) / 1000))
    start_time=$(TZ="$tz_name" date -d "@$start_sec" '+%F %T')
    end_time=$(TZ="$tz_name" date -d "@$end_sec" '+%F %T')

    echo -e "${CYAN}=== Jenkins Build Time From API ===${NCOL}"
    echo "BUILD_URL=$base_url/"
    echo "API_URL=$api_url"
    echo "RESULT=$result"
    echo "TIMESTAMP_MS=$timestamp_ms"
    echo "DURATION_MS=$duration_ms"
    echo "START_TIME=$start_time"
    echo "END_TIME=$end_time"
}

# Jenkins build 시작/종료 시각 계산 (서버의 마지막 build한 시각은 다를수 있음, 이경우에는 상세분석은 안함.)
get_jenkins_build_window() {
    local input_url="$1" base_url api_url api_json timestamp_ms duration_ms

    [[ "$input_url" =~ ^https?://[^/]+/.*/[0-9]+ ]] || return 1
    base_url="${BASH_REMATCH[0]}"
    api_url="${base_url%/}/api/json?tree=timestamp,duration,result,number,url"
    api_json=$(curl -skL "$api_url")
    [[ -z "$api_json" ]] && return 1

    if command -v jq >/dev/null 2>&1; then
        read -r timestamp_ms duration_ms < <(echo "$api_json" | jq -r '[.timestamp, .duration] | @tsv')
    else
        timestamp_ms=$(echo "$api_json" | grep -oP '"timestamp"\s*:\s*\K[0-9]+' | head -1)
        duration_ms=$(echo "$api_json" | grep -oP '"duration"\s*:\s*\K[0-9]+' | head -1)
    fi

    [[ "$timestamp_ms" =~ ^[0-9]+$ && "$duration_ms" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\n' "$((timestamp_ms / 1000))" "$(((timestamp_ms + duration_ms) / 1000))"
}

# ------------------------------------------------------------------------------
# 1. 서버 사양 및 가용 리소스 분석
# ------------------------------------------------------------------------------
# 현재 서버의 CPU/RAM/Disk 사양을 조회하고 빌드 성능 점수 계산
# 파라미터: $1=target_ip (원격 서버 IP, 빈 값이면 로컬)
check_server_spec() {
    local target_ip="$1" location_str

    # 서버 위치 판별 (Remote/Local)
    if   [[ -n "$target_ip" ]]; then location_str="Remote Server: $target_ip"
    else                              location_str="Local Server: $(hostname)"
    fi

    echo -e "\n${CYAN}=== 1. Server Specification & Score ($location_str) ===${NCOL}"

    local cpu_cores cpu_mhz cpu_ghz ram_kb ram_gb avail_ram_kb avail_ram_gb disk_total disk_avail idle_pct idle_cores
    local has_ssd=0 score=0

    # CPU 정보 수집: 코어 수, 동작 속도(MHz → GHz 변환)
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    cpu_mhz=$(lscpu | grep -i "CPU MHz" | awk '{print $3}' | cut -d. -f1 || echo 1000)
    [[ -z "$cpu_mhz" ]] && cpu_mhz=1000
    cpu_ghz=$(( cpu_mhz / 1000 ))
    [[ "$cpu_ghz" -eq 0 ]] && cpu_ghz=1

    # CPU 유휴 자원 계산: idle 비율에서 실제 유휴 코어 수 산출
    idle_pct=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int($1)}' || echo 0)
    idle_cores=$(echo | awk -v cores="$cpu_cores" -v idle="$idle_pct" '{printf "%.1f", cores * idle / 100}')

    # RAM 정보 수집: 전체 용량 및 사용 가능한 용량 (KB → GB 변환)
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$(( ram_kb / 1024 / 1024 ))
    avail_ram_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}' || echo "0")
    avail_ram_gb=$(( avail_ram_kb / 1024 / 1024 ))

    # Disk 정보 수집: 루트 파티션의 전체 용량 및 사용 가능 용량
    disk_total=$(df -h / | tail -1 | awk '{print $2}' || echo "Unknown")
    disk_avail=$(df -h / | tail -1 | awk '{print $4}' || echo "Unknown")

    # SSD 스토리지 체크: rota 값이 0이면 SSD/NVMe (1이면 HDD)
    lsblk -d -o name,rota 2>/dev/null | grep -q "0$" && has_ssd=1

    # 빌드 성능 점수 계산: Core * GHz * 배율 * SSD배율
    # - RAM 패널티: 코어당 2GB 미만이면 배율 10 → 7로 감소
    # - SSD 보너스: SSD/NVMe 사용 시 전체 점수 2배
    local mult=10 ssd_mult=1
    [[ $((ram_gb / cpu_cores)) -lt 2 ]] && mult=7
    [[ "$has_ssd" -eq 1 ]] && ssd_mult=2
    score=$(( (cpu_cores * cpu_ghz * mult) * ssd_mult ))

    # 서버 사양 정보 출력 (정렬된 형식)
    printf "%-18s : %s\n" "CPU Clock" "~${cpu_ghz} GHz"
    printf "%-18s : %6s / %-s\n" "Idle CPU Cores" "${idle_cores}" "${cpu_cores}"
    printf "%-18s : %6s / %-s\n" "Available RAM" "${avail_ram_gb}GB" "${ram_gb}GB"
    printf "%-18s : %6s / %-s\n" "Available Storage" "${disk_avail}" "${disk_total}"

    # SSD 사용 여부 알림
    [[ "$has_ssd" -eq 1 ]] && echo -e "$TAG_OK Storage: SSD or NVMe detected." || echo -e "$TAG_WARN Storage: HDD detected. Consider using SSD."

    # 최종 빌드 점수 출력
    echo "Overall Build Score: $score"
}


# ------------------------------------------------------------------------------
# 2. 소요 시간 파싱
# ------------------------------------------------------------------------------
# 로그에서 빌드 시작/종료 시간 추출 및 각 Yocto Task별 수행 시간 분석
# 파라미터: $1=log_file (분석 대상 로그 파일 경로), $2=build_start_epoch(optional), $3=build_end_epoch(optional)
analyze_time() {
    local log_file="$1" build_start_epoch="${2:-0}" build_end_epoch="${3:-0}"
    echo -e "\n${CYAN}=== 2. Time Analysis ===${NCOL}"

    local start_time end_time total_duration s_sec=0 e_sec=0 total_diff=0 start_label end_label
    local build_cmd_pattern
    local repo_start_time="" build_cmd_time="" build_done_time="" upload_start_time=""

    # 로그 시작/종료 시간 추출 (타임스탬프 있는/없는 로그 모두 지원)
    # 로그 앞부분 50줄과 뒷부분 100줄에서 HH:MM:SS 패턴 검색
    start_time=$(head -n 50 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || echo "Unknown")
    end_time=$(tail -n 100 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | tail -1 || echo "Unknown")

    # 전체 빌드 소요 시간 계산 및 출력
    if [[ "$start_time" != "Unknown" && "$end_time" != "Unknown" ]]; then
        total_duration=$(calc_duration "$start_time" "$end_time")
        if [[ "$build_start_epoch" -gt 0 && "$build_end_epoch" -gt 0 ]] 2>/dev/null; then
            start_label=$(TZ="$DEFAULT_TZ" date -d "@$build_start_epoch" '+%F %T' 2>/dev/null || echo "$start_time")
            end_label=$(TZ="$DEFAULT_TZ" date -d "@$build_end_epoch" '+%F %T' 2>/dev/null || echo "$end_time")
        else
            start_label="$(date +%F) $start_time"
            end_label="$(date +%F) $end_time"
        fi
        echo -e "${GREEN}Overall Start Time ~ Overall End Time:${NCOL} ($start_label ~ $end_label) = $total_duration"

        s_sec=$(date -u -d "1970-01-01 $start_time" +"%s" 2>/dev/null || echo 0)
        e_sec=$(date -u -d "1970-01-01 $end_time" +"%s" 2>/dev/null || echo 0)
        (( e_sec < s_sec )) && e_sec=$((e_sec + 86400))  # 자정 넘김 보정
        total_diff=$((e_sec - s_sec))

        repo_start_time=$(extract_first_timed_match 'repo[[:space:]]+(init|sync)' "$log_file")
        build_cmd_pattern='^[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+([+][[:space:]]+)?((\./)?build\.sh|bitbake|make)([[:space:]]|$)'
        build_cmd_time=$(extract_first_timed_match "$build_cmd_pattern" "$log_file")
        build_done_time=$(extract_first_timed_match 'SUCCESS: yocto build|Tasks Summary: Attempted' "$log_file")
        upload_start_time=$(extract_first_timed_match 'ncftpput|artifactory' "$log_file")

        echo -e "${GREEN}\n- Section Duration (구간별 소요시간):${NCOL}"
        print_duration_segment "Script start -> before Source download:" "$start_time" "$repo_start_time" "$total_diff"
        print_duration_segment "Source download start ->  before Build:" "$repo_start_time" "$build_cmd_time" "$total_diff"
        print_duration_segment "Build start/end -> before Image upload:" "$build_cmd_time" "$upload_start_time" "$total_diff"
        print_duration_segment "Image upload start -> Script terminate:" "$upload_start_time" "$end_time" "$total_diff"
    else
        echo -e "${GREEN}Overall Start Time ~ Overall End Time:${NCOL} ($start_time ~ $end_time)"
        echo -e "${GREEN}- Section Duration (구간별 소요시간):${NCOL} unavailable because timestamp is not found in log"
    fi

    # Yocto Tasks 카운팅 및 첫 등장 시간 비율 계산
    # 각 Task가 로그에 몇 번 등장했는지, 전체 빌드 시간 중 몇 %에 첫 등장했는지 분석
    echo -e "${GREEN}\n- Task Extracted Count (1st hit time ratio):${NCOL}"
    for task in do_fetch do_unpack do_patch do_configure do_compile do_install do_package do_rootfs do_image; do
        local count pct_str="" t_hit t_sec pct task_started_pattern
        task_started_pattern="task $task: Started"
        count=$(grep -a -F -c "$task_started_pattern" "$log_file" || true)

        if [[ "$count" -gt 0 && "$total_diff" -gt 0 ]]; then
            # 해당 Task의 첫 등장 시간 추출
            t_hit=$(grep -a -F -m1 "$task_started_pattern" "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || true)
            if [[ -n "$t_hit" ]]; then
                # 첫 등장 시간이 전체 빌드 시간의 몇 %인지 계산
                t_sec=$(date -u -d "1970-01-01 $t_hit" +"%s" 2>/dev/null || echo 0)
                (( t_sec < s_sec )) && (( t_sec += 86400 ))  # 자정 넘김 보정
                pct=$(( (t_sec - s_sec) * 100 / total_diff ))
                [[ $pct -lt 0 ]] && pct=0 || { [[ $pct -gt 100 ]] && pct=100; }
                pct_str="(${pct}%)"
            fi
        fi

        printf "  - %-13s : %5s hits  %s\n" "$task" "$count" "$pct_str"
    done
}


# ------------------------------------------------------------------------------
# 3. Yocto 설정 및 캐시 분석
# ------------------------------------------------------------------------------
# 로그에서 Yocto 설정 추출 및 Premirror/Sstate-cache 상세 분석
# 파라미터: $1=log_file (분석 대상 로그 파일 경로), $2=target_ip (원격 서버 IP), $3=build_end_epoch(optional)
analyze_config_and_cache() {
    local log_file="$1" target_ip="$2" build_end_epoch="${3:-0}"
    echo -e "\n${CYAN}=== 3. Yocto Build Configuration & Cache Analysis ===${NCOL}"
    
    # 내부 함수: 로그에서 특정 변수의 값을 추출
    extract_val() { extract_logged_var_value "$1" "$log_file" || echo ""; }
    is_default_dl_dir() { [[ "$1" == '${TOPDIR}/downloads' ]]; }
    extract_conf_value() {
        local conf_path="$1" var_pattern="$2" remote_ip="$3"
        local grep_pattern="^[[:space:]]*(${var_pattern})[[:space:]]*[?:]?="
        if [[ -n "$remote_ip" ]]; then
            run_io ssh "$remote_ip" "grep -E '$grep_pattern' '$conf_path' | head -1" | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo ""
        else
            run_io grep "" "$grep_pattern" "$conf_path" || echo ""
        fi
    }
    extract_last_number() {
        local text="$1" label="$2" value=""
        value=$(printf "%s\n" "$text" | tail -1 | grep -oP "${label} \K[0-9]+" | head -1 | xargs || true)
        [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo "0"
    }
    
    # 내부 함수: file:// URL에서 순수 경로 추출
    extract_pure_path() {
        local val="$1" is_sstate="$2"
        if [[ "$is_sstate" == "1" && "$val" =~ file:// ]]; then
            # SSTATE_MIRRORS 형식: "file://.* file:///actual/path/PATH"
            # 두 번째 file:// 경로를 추출 (실제 경로)
            local path=$(echo "$val" | grep -oP 'file://[^\s]+\s+file://\K[^\s]+' | head -1)
            if [[ -z "$path" ]]; then
                path=$(echo "$val" | grep -oP 'file://\K[^\s]+' | head -1)
            fi
            # /PATH suffix 제거 및 경로 정리
            echo "$path" | sed 's|/PATH[[:space:]]*$||;s|/PATH"$||;s|^"||;s|"$||;s|//*|/|g;s|\(.*\)//\1|\1|'
        else
            echo "$val" | grep -oP 'file://\K[^ ]+' | head -1 || echo "$val" | sed 's|file://||' | awk '{print $1}'
        fi
    }
    
    set +e  # 이 함수 내에서는 명령 실패 허용
    
    # 모든 변수 추출
    local CHECK_TIMESTAMP="" check_epoch=0
    if [[ "$build_end_epoch" -gt 0 ]] 2>/dev/null; then
        check_epoch="$build_end_epoch"
        CHECK_TIMESTAMP=$(TZ="$DEFAULT_TZ" date -d "@$build_end_epoch" '+%F %T' 2>/dev/null || echo "")
    else
        CHECK_TIMESTAMP=$(tail -n 100 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | tail -1 || echo "")
        [[ -n "$CHECK_TIMESTAMP" ]] && check_epoch=$(date -d "$(date +%F) $CHECK_TIMESTAMP" +%s 2>/dev/null || echo 0)
    fi
    local threads=$(extract_val BB_NUMBER_THREADS)
    local make_jobs=$(extract_val PARALLEL_MAKE)
    local scons_jobs=$(extract_val SCONS_OVERRIDE_NUM_JOBS)
    local dl_dir_origin=""
    local dl_dir=$(extract_logged_assignment_value DL_DIR "$log_file")
    [[ -n "$dl_dir" ]] && dl_dir_origin="log"
    [[ -z "$dl_dir" ]] && dl_dir=$(extract_val DL_DIR)
    [[ -n "$dl_dir" && -z "$dl_dir_origin" ]] && dl_dir_origin="log"
    local premirrors=$(extract_val SOURCE_MIRROR_URL)
    [[ -z "$premirrors" ]] && premirrors=$(extract_val PREMIRRORS)
    local mirrors=$(extract_val MIRRORS)
    local sstate_mirrors=$(extract_val SSTATE_MIRRORS)
    local total_fetch=$(grep -a "recipe.*do_fetch.*Started" "$log_file" 2>/dev/null | wc -l | xargs)
    local premirror_fetch=$(grep -aiE "Trying PREMIRROR|from PREMIRRORS|will check PREMIRRORS" "$log_file" 2>/dev/null | wc -l | xargs)
    local internet_fetch=$(grep -aE "Fetching.*http[s]?://" "$log_file" 2>/dev/null | wc -l | xargs)
    local cached_fetch=$((total_fetch - internet_fetch))
    local dl_dir_detect_line="" premirrors_detect_line="" sstate_detect_line=""
    local remote_ssh_ok=1 remote_notice_printed=0
    [[ "$cached_fetch" -lt 0 ]] && cached_fetch=0
    [[ -n "$target_ip" ]] && ! can_ssh_remote "$target_ip" && remote_ssh_ok=0
    dl_dir_detect_line=$(grep -aE "^${TIMESTAMP_OPTIONAL}[[:space:]]*([+][[:space:]]+)?(export[[:space:]]+)?DL_DIR[[:space:]]*[?:]?=" "$log_file" 2>/dev/null | head -1 || echo "")
    premirrors_detect_line=$(grep -aiE "Trying PREMIRROR|from PREMIRRORS|will check PREMIRRORS" "$log_file" 2>/dev/null | head -1 || echo "")
    sstate_detect_line=$(grep -a "Sstate summary:" "$log_file" 2>/dev/null | tail -1 || echo "")
    
    # 간접 증거 감지
    [[ -z "$premirrors" && "$premirror_fetch" -gt 0 ]] && premirrors="CONFIGURED (detected from log-message)"
    [[ -z "$sstate_mirrors" && -n "$sstate_detect_line" ]] && sstate_mirrors="CONFIGURED (detected from log-message)"
    
    # 추가 검색: 빌드 디렉토리의 local.conf에서 직접 찾기 (항상 실행)
    local PATH_REMOTESRC=$(grep -a -B1 "SUCCESS: yocto build" "$log_file" | head -1 | grep -oP '[0-9]{2}:[0-9]{2}:[0-9]{2}\s+\K/.*' 2>/dev/null || echo "")
    if [[ -n "$PATH_REMOTESRC" ]]; then
        local local_conf="$PATH_REMOTESRC/conf/local.conf"
        local dl_dir_from_conf="" premirrors_from_conf="" sstate_mirrors_from_conf="" conf_mtime=0
        if   [[ -n "$target_ip" && "$remote_ssh_ok" -eq 1 ]] && run_io test "$target_ip" "$local_conf" f; then conf_mtime=$(run_io mtime "$target_ip" "$local_conf" 2>/dev/null || echo 0)
        elif [[ -f "$local_conf" ]]; then conf_mtime=$(run_io mtime "" "$local_conf" 2>/dev/null || echo 0)
        fi
        [[ "$conf_mtime" -gt 0 && "$check_epoch" -gt 0 && "$conf_mtime" -gt "$check_epoch" ]] && skip_details=1
        
        # 원격/로컬 서버에서 파일 존재 확인 및 내용 읽기
        if   [[ "$skip_details" -eq 1 ]]; then :
        elif [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
            [[ "$remote_notice_printed" -eq 0 ]] && print_remote_unavailable "Source configuration lookup" "$target_ip"
            remote_notice_printed=1
        elif [[ -f "$local_conf" ]]; then
            :
        fi

        if [[ -z "$dl_dir_from_conf" && ( -f "$local_conf" || -n "$target_ip" ) ]]; then
            dl_dir_from_conf=$(extract_conf_value "$local_conf" "DL_DIR" "$target_ip")
            premirrors_from_conf=$(extract_conf_value "$local_conf" "SOURCE_MIRROR_URL|PREMIRRORS" "$target_ip")
            sstate_mirrors_from_conf=$(extract_conf_value "$local_conf" "SSTATE_MIRRORS" "$target_ip")
        fi
        

        # 결과값이 있으면 업데이트 (detected from source 태그 추가)
        if [[ -n "$dl_dir_from_conf" ]]; then
            dl_dir="$dl_dir_from_conf"
            dl_dir_origin="source"
        fi
        if [[ -n "$premirrors_from_conf" ]]; then
            premirrors="$premirrors_from_conf (detected from source)"
        fi
        if [[ -n "$sstate_mirrors_from_conf" ]]; then
            sstate_mirrors="$sstate_mirrors_from_conf (detected from source)"
        fi
    fi
    
    # skip_details=1인 경우 local.conf에서 읽은 정보를 사용하지 않음 (로그 메시지 기반 정보만 유지)
    if [[ "$skip_details" -eq 1 ]]; then
        # local.conf에서 읽은 정보는 무시
        premirrors_from_conf=""
        sstate_mirrors_from_conf=""
        
        # 로그에서 직접 추출된 경로 정보가 있으면 (detected from log-message) 태그 추가
        if [[ -n "$premirrors" && "$premirrors" != "CONFIGURED (detected from log-message)" ]]; then
            premirrors="$premirrors (detected from log-message)"
        fi
        if [[ -n "$sstate_mirrors" && "$sstate_mirrors" != "CONFIGURED (detected from log-message)" ]]; then
            sstate_mirrors="$sstate_mirrors (detected from log-message)"
        fi
    fi
    
    # ========== 요약 정보 출력 ==========
    [[ -n "$threads" ]] && echo -e "$TAG_OK BB_NUMBER_THREADS = $threads" || echo -e "$TAG_WARN BB_NUMBER_THREADS not found"
    [[ -n "$make_jobs" ]] && echo -e "$TAG_OK PARALLEL_MAKE = $make_jobs" || echo -e "$TAG_WARN PARALLEL_MAKE not found"
    [[ -n "$scons_jobs" ]] && echo -e "$TAG_OK SCONS_OVERRIDE_NUM_JOBS = $scons_jobs" || echo -e "$TAG_WARN SCONS_OVERRIDE_NUM_JOBS not found"
    if [[ -n "$dl_dir" ]]; then
        if [[ "$dl_dir" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "$TAG_OK DL_DIR = Configured (detected from log-message)"
            print_log_detect_line "DL_DIR" "$dl_dir_detect_line"
        else
            local dl_dir_origin_suffix=""
            [[ "$dl_dir_origin" == "source" ]] && dl_dir_origin_suffix=" (detected from source)"
            [[ "$dl_dir_origin" == "log" ]] && dl_dir_origin_suffix=" (detected from log)"
            echo -e "$TAG_OK DL_DIR = $dl_dir${dl_dir_origin_suffix}"
            [[ "$dl_dir_origin" == "log" ]] && print_log_detect_line "DL_DIR" "$dl_dir_detect_line"
        fi
    else
        echo -e "$TAG_WARN DL_DIR not found"
    fi
    
    # PREMIRRORS 요약
    if [[ -n "$premirrors" ]]; then
        if [[ "$premirrors" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "$TAG_OK PREMIRRORS = Configured (detected from log-message)"
            print_log_detect_line "PREMIRRORS" "$premirrors_detect_line"
        elif [[ "$premirrors" =~ "detected from log-message" ]]; then
            # 로그에서 추출된 경로 정보 (경로 그대로 표시)
            echo -e "$TAG_OK PREMIRRORS = $premirrors"
            print_log_detect_line "PREMIRRORS" "$premirrors_detect_line"
        elif [[ "$premirrors" =~ "detected from source" ]]; then
            # source에서 읽은 정보는 skip_details가 0일 때만 유효
            if [[ "$skip_details" -eq 1 ]]; then
                # local.conf가 최신이므로 로그 메시지 기반 정보로 표시
                echo -e "$TAG_OK PREMIRRORS = Configured (detected from log-message)"
            else
                local pure_path=$(extract_pure_path "${premirrors% (detected from source)}" "0")
                if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                    print_remote_unavailable "PREMIRRORS path verification" "$target_ip"
                elif run_io test "$target_ip" "$pure_path" d; then
                    echo -e "$TAG_OK PREMIRRORS = $premirrors"
                else
                    echo -e "${RED}[FAIL] PREMIRRORS path not exists: $pure_path${NCOL}"
                fi
            fi
        else
            local pure_path=$(extract_pure_path "$premirrors" "0")
            if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                print_remote_unavailable "PREMIRRORS path verification" "$target_ip"
            elif run_io test "$target_ip" "$pure_path" d; then
                echo -e "$TAG_OK PREMIRRORS = $premirrors"
            else
                echo -e "${RED}[FAIL] PREMIRRORS path not exists: $pure_path${NCOL}"
            fi
        fi
    else
        echo -e "$TAG_WARN PREMIRRORS not found"
    fi
    
    # MIRRORS 요약
    if [[ -n "$mirrors" ]]; then
        local pure_path=$(extract_pure_path "$mirrors" "0")
        if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
            print_remote_unavailable "MIRRORS path verification" "$target_ip"
        elif run_io test "$target_ip" "$pure_path" d; then
            echo -e "$TAG_OK MIRRORS = $mirrors"
        else
            echo -e "${RED}[FAIL] MIRRORS path not exists: $pure_path${NCOL}"
        fi
    else
        echo -e "$TAG_WARN MIRRORS not found"
    fi
    
    # SSTATE_MIRRORS 요약
    if [[ -n "$sstate_mirrors" ]]; then
        if [[ "$sstate_mirrors" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "$TAG_OK SSTATE_MIRRORS = Configured (detected from log-message)"
            print_log_detect_line "SSTATE_MIRRORS" "$sstate_detect_line"
        elif [[ "$sstate_mirrors" =~ "detected from log-message" ]]; then
            # 로그에서 추출된 경로 정보 (경로 그대로 표시)
            echo -e "$TAG_OK SSTATE_MIRRORS = $sstate_mirrors"
            print_log_detect_line "SSTATE_MIRRORS" "$sstate_detect_line"
        elif [[ "$sstate_mirrors" =~ "detected from source" ]]; then
            # source에서 읽은 정보는 skip_details가 0일 때만 유효
            if [[ "$skip_details" -eq 1 ]]; then
                # local.conf가 최신이므로 로그 메시지 기반 정보로 표시
                echo -e "$TAG_OK SSTATE_MIRRORS = Configured (detected from log-message)"
            else
                local pure_path=$(extract_pure_path "${sstate_mirrors% (detected from source)}" "1")
                if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                    print_remote_unavailable "SSTATE_MIRRORS path verification" "$target_ip"
                elif run_io test "$target_ip" "$pure_path" d; then
                    echo -e "$TAG_OK SSTATE_MIRRORS = $sstate_mirrors"
                else
                    echo -e "${RED}[FAIL] SSTATE_MIRRORS path not exists: $pure_path${NCOL}"
                fi
            fi
        else
            local pure_path=$(extract_pure_path "$sstate_mirrors" "1")
            if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                print_remote_unavailable "SSTATE_MIRRORS path verification" "$target_ip"
            elif run_io test "$target_ip" "$pure_path" d; then
                echo -e "$TAG_OK SSTATE_MIRRORS = $sstate_mirrors"
            else
                echo -e "${RED}[FAIL] SSTATE_MIRRORS path not exists: $pure_path${NCOL}"
            fi
        fi
    else
        echo -e "$TAG_WARN SSTATE_MIRRORS not found (sstate-cache sharing not configured)"
    fi
    
    ## source path의 정보를 출력할지 여부
    [[ "$skip_details" -eq 1 ]] && 
    echo -e "${RED}[WARN]${NCOL} local.conf is modified after build ($CHECK_TIMESTAMP); 
             That means this build log is old, therefore current source-based info skipped."
    
    # ========== SSTATE-CACHE 세부 정보 ==========
    echo -e "\n${BLUE}--- 3.1. Sstate-cache Details ---${NCOL}"
    echo -e "${GREEN}[Cache Statistics]${NCOL}"
    local sstate_summary=$(grep -a "Sstate summary:" "$log_file" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$sstate_summary" ]]; then
        local wanted=$(extract_last_number "$sstate_summary" "Wanted")
        local found=$(extract_last_number "$sstate_summary" "Found")
        local missed=$(extract_last_number "$sstate_summary" "Missed")
        [[ "$wanted" -gt 0 ]] && local hit_rate=$(( found * 100 / wanted )) || local hit_rate=0
        if [[ "$hit_rate" -eq 0 ]]; then
            echo -e "${RED}  - Hit rate: ${hit_rate}% (${found}/${wanted}), Missed: ${missed}${NCOL}"
        else
            printf "  - Hit rate: %s%% (%s/%s), Missed: %s\n" "$hit_rate" "$found" "$wanted" "$missed"
        fi
    else
        echo "  - Sstate summary not found in log"
    fi
    
    echo -e "${GREEN}[SState-cache Storage]${NCOL}"
    if [[ "$skip_details" -eq 1 || "$sstate_mirrors" == "CONFIGURED (detected from log-message)" || "$sstate_mirrors" =~ "detected from log-message" ]]; then
        echo -e "  - $TAG_WARN Skipped build is old"
    else
        local sstate_path_raw="$sstate_mirrors"
        [[ "$sstate_path_raw" =~ "detected from source" ]] && sstate_path_raw="${sstate_path_raw% (detected from source)}"
        local sstate_path=$(extract_pure_path "$sstate_path_raw" "1")
        if [[ -n "$sstate_path" ]]; then
            if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                print_remote_unavailable "SSTATE-cache storage lookup" "$target_ip"
            elif run_io test "$target_ip" "$sstate_path" d; then
                local sstate_size=$(run_io size "$target_ip" "$sstate_path" || echo "Unknown")
                echo -e "  - Path: $sstate_path"
                echo -e "  - Size: $sstate_size"
            else
                echo -e "  - Path: $sstate_path (not accessible)"
            fi
        fi
    fi
    
    echo -e "${GREEN}[Sstate-cache Miss Analysis]${NCOL}"
    local sstate_line=$(grep -a "Sstate summary:" "$log_file" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$sstate_line" ]]; then
        local missed=$(extract_last_number "$sstate_line" "Missed")
        if [[ "$missed" -gt 0 ]]; then
            echo "  - Reason: $missed tasks not found in sstate-cache (new/modified recipes or different build configuration)"
            echo "  - Impact: These tasks will be rebuilt from source instead of using cached artifacts"
        fi
    fi
    
    # fetch_lines를 먼저 추출 (3번 항목에서 필요)
    local fetch_lines=$(grep -a "recipe.*do_fetch.*Started" "$log_file" 2>/dev/null || echo "")
    
    # Cache miss된 task들 (실제로 rebuild된 것들)
    local missed_tasks=$(grep -aE "recipe.*: task do_(populate_sysroot|package|packagedata|package_write_[a-z]+|deploy|populate_lic|rootfs|image|makeboot|create_spdx|create_runtime_spdx|package_qa|flush_pseudodb|deploy_fixup|image_qa|makesystem_ubi|image_debugfs_tar|image_complete|populate_lic_deploy): Started" "$log_file" 2>/dev/null | grep -v setscene || echo "")
    local rebuilt_modules=$(echo "$missed_tasks" | grep -oP 'recipe \K[^:]+' | sort -u || echo "")
    local fetched_modules=$(echo "$fetch_lines" | grep -oP 'recipe \K[^:]+' | sort -u || echo "")
    
    # 1. [Hit] Tasks restored from cache (first 20 examples, image related task always need to be rebuilt)
    ## sstate-cache에서 hit된 task들, image 관련 task는 캐싱 불가능하여 여기 나오지 않음.
    local setscene_all_tasks=$(grep -a "Running setscene task" "$log_file" 2>/dev/null || echo "")
    local setscene_tasks=$(echo "$setscene_all_tasks" | head -20)
    local setscene_count=$(echo "$setscene_all_tasks" | sed '/^$/d' | wc -l | xargs)
    local section_hit_body="" section_no_fetch_body="" section_with_fetch_body="" section_cached_fetch_body="" section_internet_body=""
    local section_hit section_no_fetch section_with_fetch section_cached_fetch section_internet
    if [[ -n "$setscene_tasks" ]]; then
        while IFS= read -r line; do
            local timestamp=$(echo "$line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
            local recipe=$(echo "$line" | grep -oP 'recipes-[^/]+/[^/]+/\K[^:]+' || echo "$line" | grep -oP '/\K[^/:]+\.bb')
            local task=$(echo "$line" | grep -oP ':do_\K[^)]+' || echo "")
            if [[ -n "$recipe" ]]; then
                [[ -n "$timestamp" ]] && section_hit_body+="    [$timestamp] $recipe (task: do_$task)"$'\n' || section_hit_body+="    • $recipe (task: do_$task)"$'\n'
            fi
        done <<< "$setscene_tasks"
    else
        section_hit_body="    (None - no tasks restored from cache examples found)"
    fi
    section_hit=$(make_section_block "  - [Hit:${setscene_count:-0}] Modules from sstatecache(first 20 examples, some tasks always rebuilt):\
    \nsetscene_all_tasks으로 cache에서 복원된 시각을 표시" "${section_hit_body%$'\n'}")
    
    # 2. [Missed] Modules rebuilt without fetch 
    ## fetch 없이 rebuild된 모듈들 (fetch 단계는 없었지만 실제로는 rebuild된 task들, 즉 sstate-cache에 없거나 hash값이 맞지 않아 rebuild되어야 하는 모듈
    local no_fetch_count=0
    while IFS= read -r full_recipe; do
        [[ -z "$full_recipe" ]] && continue
        echo "$fetched_modules" | grep -qF "$full_recipe" || no_fetch_count=$((no_fetch_count + 1))
    done <<< "$rebuilt_modules"
    if [[ -n "$missed_tasks" ]]; then
        # rebuild되었지만 fetch되지 않은 모듈 찾기
        while IFS= read -r full_recipe; do
            [[ -z "$full_recipe" ]] && continue
            # 이 모듈이 fetch 리스트에 없는지 확인
            if ! echo "$fetched_modules" | grep -qF "$full_recipe"; then
                # 첫 번째 발견 시간 찾기
                local first_line=$(echo "$missed_tasks" | grep -F "recipe $full_recipe:" | head -1 || echo "")
                local timestamp=$(echo "$first_line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
                if [[ -n "$full_recipe" ]]; then
                    [[ -n "$timestamp" ]] && section_no_fetch_body+="    [$timestamp] $full_recipe"$'\n' || section_no_fetch_body+="    • $full_recipe"$'\n'
                fi
            fi
        done <<< "$rebuilt_modules"
        
        if [[ $no_fetch_count -eq 0 ]]; then
            section_no_fetch_body="    (None - all rebuilt modules had fetch tasks)"
        fi
    else
        section_no_fetch_body="    (None - no rebuilt modules found)"
    fi
    section_no_fetch=$(make_section_block "  - [Missed:${no_fetch_count:-0}] Modules rebuilt without fetch, All source already exists:\
    \n\t\t실제 fetch 없이 rebuild된 시각을 표시" "${section_no_fetch_body%$'\n'}")
    
    # 3. [Missed] Modules that were rebuilt from DL_DIR, PREMIRROR
    ## rebuild로 인해 src fetch가 필요해, 먼저 DL_DIR, PREMIRROR에 존재하는지 확인한다.
    local with_fetch_count=0
    while IFS= read -r full_recipe; do
        [[ -z "$full_recipe" ]] && continue
        echo "$fetched_modules" | grep -qF "$full_recipe" && with_fetch_count=$((with_fetch_count + 1))
    done <<< "$rebuilt_modules"
    if [[ -n "$missed_tasks" ]]; then
        # rebuild되고 fetch도 있는 모듈만 찾기
        while IFS= read -r full_recipe; do
            [[ -z "$full_recipe" ]] && continue
            # 이 모듈이 fetch 리스트에 있는지 확인
            if echo "$fetched_modules" | grep -qF "$full_recipe"; then
                # 첫 번째 발견 시간 찾기
                local first_line=$(echo "$missed_tasks" | grep -F "recipe $full_recipe:" | head -1 || echo "")
                local timestamp=$(echo "$first_line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
                if [[ -n "$full_recipe" ]]; then
                    [[ -n "$timestamp" ]] && section_with_fetch_body+="    [$timestamp] $full_recipe"$'\n' || section_with_fetch_body+="    • $full_recipe"$'\n'
                fi
            fi
        done <<< "$rebuilt_modules"
        
        if [[ $with_fetch_count -eq 0 ]]; then
            section_with_fetch_body="    (None - all tasks restored from cache)"
        fi
    else
        section_with_fetch_body="    (None - all tasks restored from cache)"
    fi
    section_with_fetch=$(make_section_block "  - [Missed:${with_fetch_count:-0}] Modules rebuilt with fetch, fetched from DL_DIR or PREMIRROR, Internet:\
    \n실제 build를 시작한 시각을 표시" "${section_with_fetch_body%$'\n'}")
    
    # 먼저 인터넷에서 다운로드된 recipe 목록 추출 (Fetching http 전후 20줄 내에 있는 recipe)
    local internet_recipes=$(grep -a -B 20 "Fetching.*http" "$log_file" 2>/dev/null | grep "recipe.*do_fetch.*Started" | grep -oP 'recipe \K[^:]+' | sort -u || echo "")
    local cached_fetch_count=0
    while IFS= read -r full_recipe; do
        [[ -z "$full_recipe" ]] && continue
        echo "$internet_recipes" | grep -qF "$full_recipe" || cached_fetch_count=$((cached_fetch_count + 1))
    done <<< "$fetched_modules"
    
    # 4. [Hit] Module list fetched from DL_DIR or PREMIRRORS (cached, no internet download)
    ## DL_DIR 또는 PREMIRRORS에서 캐시 hit된 모듈들 (인터넷 다운로드 없음)
    if [[ -n "$fetch_lines" ]]; then
        # fetch_lines에서 internet_recipes를 제외한 모듈만 출력
        while IFS= read -r full_recipe; do
            [[ -z "$full_recipe" ]] && continue
            # 이 모듈이 인터넷 다운로드 목록에 없는지 확인
            if ! echo "$internet_recipes" | grep -qF "$full_recipe"; then
                # 첫 번째 발견 시간 찾기
                local first_line=$(echo "$fetch_lines" | grep -F "recipe $full_recipe:" | head -1 || echo "")
                local timestamp=$(echo "$first_line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
                if [[ -n "$full_recipe" ]]; then
                    if [[ -n "$timestamp" ]]; then
                        section_cached_fetch_body+="    [$timestamp] $full_recipe"$'\n'
                    else
                        section_cached_fetch_body+="    • $full_recipe"$'\n'
                    fi
                fi
            fi
        done <<< "$(echo "$fetch_lines" | grep -oP 'recipe \K[^:]+' | sort -u)"
        
        [[ -z "$section_cached_fetch_body" ]] && section_cached_fetch_body="    (None - all fetched modules required internet download)"
    else
        section_cached_fetch_body="    (None - no fetch tasks executed)"
    fi
    section_cached_fetch=$(make_section_block "  - [Hit:${cached_fetch_count:-0}] Modules fetched from DL_DIR or PREMIRRORS (cached):\
    \n\n\t\t실제 DL_DIR or PREMIRRORS에서 do_fetch한 시각을 표시" "${section_cached_fetch_body%$'\n'}")
    
    # 5. [Missed] All files downloaded from Internet (recipes + BitBake system files)
    ## 인터넷에서 다운로드된 모든 파일 (recipe 소스 do_fetch + BitBake의 buildtools과 uninative)
    ## bitbake에서 uninative는 host의 gcc버전에 상관없이 동일한 sstate-cache를 생성하는 library, buildtools는 gcc,make,python등등 build기본 toolchain
    local fetching_lines=$(grep -a "Fetching.*http" "$log_file" 2>/dev/null || echo "")
    local internet_file_count=$(echo "$fetching_lines" | grep -oP 'http[s]?://[^\s;]+' | sed 's|.*/||;s|?.*||;s|;.*||' | sed '/^$/d' | sort -u | wc -l | xargs)
    if [[ -n "$fetching_lines" ]]; then
        local internet_files=$(echo "$fetching_lines" | grep -oP 'http[s]?://[^\s;]+' | sed 's|.*/||;s|?.*||;s|;.*||' | sed '/^$/d' | sort -u)
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            # 첫 번째 발견 시간 찾기
            local first_line=$(echo "$fetching_lines" | grep -F "$file" | head -1)
            local timestamp=$(echo "$first_line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
            local url=$(echo "$first_line" | grep -oP 'http[s]?://[^\s;]+' | head -1)
            local domain=$(echo "$url" | cut -d'/' -f3)
            if [[ -n "$file" && -n "$domain" ]]; then
                [[ -n "$timestamp" ]] && section_internet_body+="    [$timestamp] $file (from $domain)"$'\n' || section_internet_body+="    • $file (from $domain)"$'\n'
            fi
        done <<< "$internet_files"
    else
        section_internet_body="    (None - all sources were cached in DL_DIR or PREMIRRORS)"
    fi
    section_internet=$(make_section_block "  - [Missed:${internet_file_count:-0}] Files downloaded from Internet (recipes do_fetch + system bitbake):" "${section_internet_body%$'\n'}")

    print_two_column_sections "$section_hit" "$section_no_fetch"
    echo
    print_two_column_sections "$section_with_fetch" "$section_cached_fetch"
    echo
    print_two_column_sections "$section_internet"

    # ========== PREMIRRORS 세부 정보 ==========
    echo -e "\n${BLUE}--- 3.2. Premirror Details ---${NCOL}"

    echo -e "${GREEN}[Fetch Statistics]${NCOL}"
    printf "  - Total: %s, From DL_DIR/PREMIRRORS/local source: %s, From internet: %s\n" "${total_fetch:-0}" "$cached_fetch" "${internet_fetch:-0}"
    

    echo -e "${GREEN}[DL_DIR Path]${NCOL}"
    if is_default_dl_dir "$dl_dir"; then
        echo -e '  - '"$TAG_WARN"' DL_DIR not configured (default: ${TOPDIR}/downloads)'
    elif [[ -n "$dl_dir" && "$dl_dir" != "CONFIGURED (detected from log-message)" ]]; then
        echo -e "  - Path: $dl_dir"
        # DL_DIR size check (mirroring premirror logic)
        if [[ "$skip_details" -eq 1 ]]; then
            echo -e "  - $TAG_WARN Skipped build is old"
        else
            if [[ -n "$dl_dir" ]]; then
                if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                    print_remote_unavailable "DL_DIR storage lookup" "$target_ip"
                elif run_io test "$target_ip" "$dl_dir" d; then
                    local dl_dir_size=$(run_io size "$target_ip" "$dl_dir" || echo "Unknown")
                    echo -e "  - Size: $dl_dir_size"
                else
                    echo -e "  - Path: $dl_dir (not accessible)"
                fi
            fi
        fi
    elif [[ -n "$dl_dir_detect_line" ]]; then
        echo -e "  - Detected from log: $dl_dir_detect_line"
    else
        echo -e "  - $TAG_WARN DL_DIR path not available"
    fi

    echo -e "${GREEN}[Premirror Storage]${NCOL}"
    if [[ "$skip_details" -eq 1 || "$premirrors" == "CONFIGURED (detected from log-message)" || "$premirrors" =~ "detected from log-message" ]]; then
        echo -e "  - $TAG_WARN Skipped build is old"
    else
        local premirror_path_raw="$premirrors"
        [[ "$premirror_path_raw" =~ "detected from source" ]] && premirror_path_raw="${premirror_path_raw% (detected from source)}"
        local premirror_path=$(extract_pure_path "$premirror_path_raw" "0")
        if [[ -n "$premirror_path" ]]; then
            if [[ -n "$target_ip" && "$remote_ssh_ok" -eq 0 ]]; then
                print_remote_unavailable "Premirror storage lookup" "$target_ip"
            elif run_io test "$target_ip" "$premirror_path" d; then
                local premirror_size=$(run_io size "$target_ip" "$premirror_path" || echo "Unknown")
                echo -e "  - Path: $premirror_path"
                echo -e "  - Size: $premirror_size"
            else
                echo -e "  - Path: $premirror_path (not accessible)"
            fi
        fi
    fi
    
    set -e  # 오류 모드 복원
}


# ------------------------------------------------------------------------------
# 4. 거대 이미지 도출
# ------------------------------------------------------------------------------
# 빌드 결과물 중 큰 파일(100MB 이상) 탐색 및 출력
# 파라미터: $1=log_file (분석 대상 로그 파일 경로), $2=target_ip (원격 서버 IP)
find_large_outputs() {
    local log_file="$1" target_ip="$2"
    local FILESIZE="100M"

    echo -e "\n${CYAN}=== 4. Large Output Files (> $FILESIZE) ===${NCOL}"

    [[ "$skip_details" -eq 1 ]] && { echo -e "$TAG_WARN Skipped because local.conf is newer than build end time"; return 0; }

    set +e  # 명령 실패 허용

    # 빌드 디렉토리 추출 (3번 항목과 동일한 방식)
    local PATH_REMOTESRC=$(grep -a -B1 "SUCCESS: yocto build" "$log_file" | head -1 | grep -oP '[0-9]{2}:[0-9]{2}:[0-9]{2}\s+\K/.*' 2>/dev/null || echo "")
    local inferred_build_dir=""

    if [[ -z "$PATH_REMOTESRC" ]]; then
        inferred_build_dir=$(infer_build_dir_from_deploy_images "$log_file" || echo "")
        [[ -n "$inferred_build_dir" ]] && PATH_REMOTESRC="$inferred_build_dir"
    fi
    
    if [[ -z "$PATH_REMOTESRC" ]]; then
        echo -e "${YELLOW}[WARN] Build directory not found in log.${NCOL}"
        set -e
        return 0
    fi

    # tmp*/deploy/images 디렉토리 패턴 (tmp, tmp-glibc 등 지원)
    local deploy_pattern="$PATH_REMOTESRC/tmp*/deploy/images"
    
    echo -e "${GREEN}[Build Directory]${NCOL}"
    echo "  - Build path: $PATH_REMOTESRC"
    [[ -n "$inferred_build_dir" ]] && echo "  - Derived from first /deploy/images/ match in log"
    echo "  - Search pattern: $deploy_pattern"
    
    # find 명령 생성: 지정된 크기 이상 파일 검색 후 크기순 정렬하여 상위 10개 추출
    local find_cmd="find $deploy_pattern -type f -size +$FILESIZE 2>/dev/null | xargs ls -lh 2>/dev/null | awk '{print \$5, \$9}' | sort -hr | head -n 10"
    
    echo -e "\n${GREEN}[Large Files (Top 10)]${NCOL}"

    if [[ -n "$target_ip" ]] && ! can_ssh_remote "$target_ip"; then
        print_remote_unavailable "Large output scan" "$target_ip"
        set -e
        return 0
    fi
    
    local result=""
    result=$(run_io exec "$target_ip" "$find_cmd" 2>/dev/null || echo "")
    
    # 검색 결과 출력
    if [[ -z "$result" ]]; then
        echo "  - No files larger than $FILESIZE were found"
    else
        echo "$result" | while IFS= read -r line; do
            local size=$(echo "$line" | awk '{print $1}')
            local filepath=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')
            local filename=$(basename "$filepath")
            echo "  - [$size] $filename"
        done
    fi
    
    set -e  # 오류 모드 복원
}

# ------------------------------------------------------------------------------
# 메인 로직
# ------------------------------------------------------------------------------
# 로그 파일 또는 URL을 입력받아 서버 사양, Yocto 설정, 소요 시간, 거대 파일 분석
# 파라미터: $1=input (로그 파일 경로 또는 Jenkins URL)
main() {
    local skip_details=0
    if [[ "${1:-}" == "--jenkins-build-time" ]]; then
        [[ $# -lt 2 ]] && {
            echo -e "$TAG_FAIL Usage: $0 --jenkins-build-time <jenkins_build_url> [timezone]"
            echo -e "  Example: $0 --jenkins-build-time https://vjenkins.lge.com/jenkins06/job/honda_26mypf3__dev_custom_build/44"
            exit 1
        }
        show_jenkins_build_time "$2" "${3:-$DEFAULT_TZ}"
        exit $?
    fi

    # 사용법 출력
    if [[ $# -lt 1 ]]; then
        echo -e "$TAG_FAIL Usage: $0 <logfile path or url>"
        echo -e "  Example: $0 https://jenkins.../27/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog"
        echo -e "  or:      $0 https://jenkins.../27/consoleText"
        echo -e "  or:      $0 https://jenkins.../27/console"
        echo -e "  or:      $0 --jenkins-build-time https://jenkins.../27"
        exit 1
    fi
    
    # 첫 번째 인자만 사용 (URL이 & 문자로 shell에서 분리되어도 기본 URL만 필요)
    local input target_log_ip local_ips build_url="" build_start_epoch=0 build_end_epoch=0
    input="$1"

    # 입력이 URL인 경우 로그 다운로드 처리
    if [[ "$input" =~ ^http:// || "$input" =~ ^https:// ]]; then
        # Jenkins URL인 경우 항상 timestamps 형식으로 정규화
        if [[ "$input" =~ jenkins ]]; then
            # build number까지의 기본 URL 추출: .../job_name/build_number
            if [[ "$input" =~ (https?://[^/]+/.*/[0-9]+) ]]; then
                build_url="${BASH_REMATCH[1]}"
                input="${build_url}/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog"
                echo -e "$TAG_OK Normalized Jenkins URL (final):"
                echo -e "     $input"
            fi
        fi

        echo -e "$TAG_OK Downloading log from URL..."

        # HTTPS 다운로드 시도 후 실패하면 HTTP로 재시도 (Fallback)
        if ! curl -skL "$input" > "$PATH_TEMP_LOG" 2>/dev/null; then
            if [[ "$input" =~ ^https:// ]]; then
                echo -e "$TAG_WARN HTTPS download failed, trying HTTP..."
                input="${input/#https/http}"
                if ! curl -sL "$input" > "$PATH_TEMP_LOG" 2>/dev/null; then
                    echo -e "$TAG_FAIL Failed to download log via HTTP as well"
                    exit 1
                fi
            else
                echo -e "$TAG_FAIL Failed to download log"
                exit 1
            fi
        fi
    elif [[ -f "$input" ]]; then
        # 로컬 파일인 경우 임시 파일로 복사
        echo -e "$TAG_OK Copying target log file..."
        cp "$input" "$PATH_TEMP_LOG"
    else
        echo -e "$TAG_FAIL Target log is neither valid HTTP url nor existing file."
        exit 1
    fi

    # 원격 빌드 서버 IP 추출 및 로컬/원격 판별
    # 로그에서 "Building remotely on" 문구 검색하여 IP 주소 추출
    target_log_ip=$(head -n 25 "$PATH_TEMP_LOG" | grep -Ei "Building remotely on" | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 || echo "")
    local_ips=$(hostname -I 2>/dev/null || echo "127.0.0.1")
    [[ -n "$target_log_ip" ]] && [[ ! "$local_ips" =~ $target_log_ip ]] && echo -e "${YELLOW}[WARN] Script runs locally but log generated on remote server: ${target_log_ip}${NCOL}"
    if [[ -n "$build_url" ]]; then
        read -r build_start_epoch build_end_epoch < <(get_jenkins_build_window "$build_url" 2>/dev/null || echo "0 0")
    fi

    # 분석 함수 순차 실행: 서버 사양 → 시간 분석 → 설정 및 캐시 분석 → 대용량 파일 검색
    check_server_spec "$target_log_ip"
    analyze_time "$PATH_TEMP_LOG" "$build_start_epoch" "$build_end_epoch"
    analyze_config_and_cache "$PATH_TEMP_LOG" "$target_log_ip" "$build_end_epoch"
    [[ "$skip_details" -eq 0 ]] && find_large_outputs "$PATH_TEMP_LOG" "$target_log_ip"

    echo -e "\n$TAG_OK Analysis Complete!"
}

main "$@"
