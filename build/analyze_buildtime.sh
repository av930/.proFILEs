#!/bin/bash
set -euo pipefail

# ==============================================================================
# Yocto Build Log 시간 분석 및 환경 검사 스크립트
# 사용법: ./analyze_buildtime.sh <logfile_path_or_url>
# 목적: Yocto 환경 설정 확인, 리소스 측정 및 로그 시간 파싱을 통해 병목구간 탐색
# ==============================================================================

readonly COLOR_GREEN="\033[92m\033[1m"
readonly COLOR_RED="\033[91m\033[1m"
readonly COLOR_YELLOW="\033[93m\033[1m"
readonly COLOR_RESET="\033[0m"

readonly TAG_OK="${COLOR_GREEN}[OKAY]${COLOR_RESET}"
readonly TAG_FAIL="${COLOR_RED}[FAIL]${COLOR_RESET}"
readonly TAG_WARN="${COLOR_YELLOW}[WARN]${COLOR_RESET}"

# 종료 시 임시 파일 정리를 위한 글로벌 변수
[[ -n "${PATH_TEMP_LOG:-}" && -f "$PATH_TEMP_LOG" ]] && rm -f "$PATH_TEMP_LOG"
readonly PATH_TEMP_LOG=$(mktemp)

# 스크립트 종료 핸들러
cleanup() {
    [[ -f "$PATH_TEMP_LOG" ]] && rm -f "$PATH_TEMP_LOG"
}
trap cleanup EXIT

# 시간 계산 헬퍼 함수
calc_duration() {
    local start="$1" end="$2"
    [[ -z "$start" || -z "$end" ]] && return
    local s_sec e_sec
    s_sec=$(date -u -d "1970-01-01 $start" +"%s" 2>/dev/null || echo 0)
    e_sec=$(date -u -d "1970-01-01 $end" +"%s" 2>/dev/null || echo 0)
    if (( e_sec < s_sec )); then e_sec=$((e_sec + 86400)); fi
    local diff=$((e_sec - s_sec))
    printf "%02d:%02d:%02d" $((diff/3600)) $((diff%3600/60)) $((diff%60))
}

# ------------------------------------------------------------------------------
# 1. 서버 사양 및 가용 리소스 분석
# ------------------------------------------------------------------------------
check_server_spec() {
    local target_ip="$1"
    local location_str=""

    if [[ -n "$target_ip" ]]; then
        location_str="Remote Server: $target_ip"
    else
        location_str="Local Server: $(hostname)"
    fi

    echo -e "\n=== 1. Server Specification & Score ($location_str) ==="

    local cpu_cores cpu_mhz cpu_ghz ram_kb ram_gb avail_ram_kb avail_ram_gb
    local disk_total disk_avail has_ssd=0 score=0 idle_pct idle_cores

    cpu_cores=$(nproc 2>/dev/null || echo 1)
    cpu_mhz=$(lscpu | grep -i "CPU MHz" | awk '{print $3}' | cut -d. -f1 || echo 1000)
    [[ -z "$cpu_mhz" ]] && cpu_mhz=1000
    cpu_ghz=$(( cpu_mhz / 1000 ))
    [[ "$cpu_ghz" -eq 0 ]] && cpu_ghz=1

    # CPU idle 계산
    idle_pct=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int($1)}' || echo 0)
    idle_cores=$(echo | awk -v cores="$cpu_cores" -v idle="$idle_pct" '{printf "%.1f", cores * idle / 100}')

    # RAM 정보
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_gb=$(( ram_kb / 1024 / 1024 ))
    avail_ram_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}' || echo "0")
    avail_ram_gb=$(( avail_ram_kb / 1024 / 1024 ))

    # Disk 정보
    disk_total=$(df -h / | tail -1 | awk '{print $2}' || echo "Unknown")
    disk_avail=$(df -h / | tail -1 | awk '{print $4}' || echo "Unknown")

    # SSD 스토리지 체크
    if lsblk -d -o name,rota 2>/dev/null | grep -q "0$"; then
        has_ssd=1
    fi

    # RAM 패널티 (코어당 2GB 이하면 효율 감소)
    local mult=10
    [[ $((ram_gb / cpu_cores)) -lt 2 ]] && mult=7

    # SSD가 없으면 전체 점수 반토막
    local ssd_mult=1
    [[ "$has_ssd" -eq 1 ]] && ssd_mult=2

    score=$(( (cpu_cores * cpu_ghz * mult) * ssd_mult ))

    printf "%-18s : %s\n" "CPU Clock" "~${cpu_ghz} GHz"
    printf "%-18s : %6s / %-s\n" "Idle CPU Cores" "${idle_cores}" "${cpu_cores}"
    printf "%-18s : %6s / %-s\n" "Available RAM" "${avail_ram_gb}GB" "${ram_gb}GB"
    printf "%-18s : %6s / %-s\n" "Available Storage" "${disk_avail}" "${disk_total}"

    if [[ "$has_ssd" -eq 1 ]]; then echo -e "$TAG_OK Storage: SSD or NVMe detected."
    else                             echo -e "$TAG_WARN Storage: HDD detected. Consider using SSD."
    fi

    echo "Overall Build Score: $score"
}

# ------------------------------------------------------------------------------
# 2. Yocto 설정값 분석
# ------------------------------------------------------------------------------
analyze_yocto_config() {
    local log_file="$1"
    echo -e "\n=== 2. Yocto Build Configuration Check ==="

    extract_val() {
        grep -E "^[[:space:]]*$1[[:space:]]*[?:]?=" "$log_file" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo ""
    }

    local threads=$(extract_val BB_NUMBER_THREADS)
    local make_jobs=$(extract_val PARALLEL_MAKE)
    local scons_jobs=$(extract_val SCONS_OVERRIDE_NUM_JOBS)
    local dl_dir=$(extract_val DL_DIR)
    local premirrors=$(extract_val PREMIRRORS)
    local mirrors=$(extract_val MIRRORS)
    local sstate=$(grep -E "^(SSTATE_DIR|SSTATECACHE)[ \t]*[?:]?=" "$log_file" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//' || echo "")

    [[ -n "$threads" ]] && echo -e "$TAG_OK BB_NUMBER_THREADS = $threads" || echo -e "$TAG_WARN BB_NUMBER_THREADS not found"
    [[ -n "$make_jobs" ]] && echo -e "$TAG_OK PARALLEL_MAKE = $make_jobs" || echo -e "$TAG_WARN PARALLEL_MAKE not found"
    [[ -n "$scons_jobs" ]] && echo -e "$TAG_OK SCONS_OVERRIDE_NUM_JOBS = $scons_jobs" || echo -e "$TAG_WARN SCONS_OVERRIDE_NUM_JOBS not found"
    [[ -n "$dl_dir" ]] && echo -e "$TAG_OK DL_DIR = $dl_dir" || echo -e "$TAG_WARN DL_DIR not found"
    [[ -n "$premirrors" ]] && echo -e "$TAG_OK PREMIRRORS = $premirrors" || echo -e "$TAG_WARN PREMIRRORS not found"
    [[ -n "$mirrors" ]] && echo -e "$TAG_OK MIRRORS = $mirrors" || echo -e "$TAG_WARN MIRRORS not found"
    [[ -n "$sstate" ]] && echo -e "$TAG_OK SSTATE_DIR = $sstate" || echo -e "$TAG_WARN SSTATE_DIR not found"

    grep -a "Sstate summary:" "$log_file" || true
}

# ------------------------------------------------------------------------------
# 3. 소요 시간 파싱
# ------------------------------------------------------------------------------
analyze_time() {
    local log_file="$1"
    echo -e "\n=== 3. Time Analysis ==="

    local start_time end_time total_duration
    local s_sec=0 e_sec=0 total_diff=0

    start_time=$(head -n 50 "$log_file" | grep -Eo "^[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || echo "Unknown")
    end_time=$(tail -n 100 "$log_file" | grep -Eo "^[0-9]{2}:[0-9]{2}:[0-9]{2}" | tail -1 || echo "Unknown")

    if [[ "$start_time" != "Unknown" && "$end_time" != "Unknown" ]]; then
        total_duration=$(calc_duration "$start_time" "$end_time")
        echo "Overall Start Time ~ Overall End Time: ($start_time ~ $end_time) = $total_duration"

        s_sec=$(date -u -d "1970-01-01 $start_time" +"%s" 2>/dev/null || echo 0)
        e_sec=$(date -u -d "1970-01-01 $end_time" +"%s" 2>/dev/null || echo 0)
        (( e_sec < s_sec )) && e_sec=$((e_sec + 86400))
        total_diff=$((e_sec - s_sec))
    else
        echo "Overall Start Time ~ Overall End Time: ($start_time ~ $end_time)"
    fi

    # Yocto Tasks 카운팅
    echo -e "\n- Task Extracted Count (1st hit time ratio):"
    for task in do_fetch do_unpack do_patch do_configure do_compile do_install do_package do_rootfs do_image; do
        local count=$(grep -a -c "$task" "$log_file" || true)
        local pct_str=""

        if [[ "$count" -gt 0 && "$total_diff" -gt 0 ]]; then
            local t_hit=$(grep -a -m1 "$task" "$log_file" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || true)
            if [[ -n "$t_hit" ]]; then
                local t_sec=$(date -u -d "1970-01-01 $t_hit" +"%s" 2>/dev/null || echo 0)
                (( t_sec < s_sec )) && (( t_sec += 86400 ))
                local pct=$(( (t_sec - s_sec) * 100 / total_diff ))
                [[ $pct -lt 0 ]] && pct=0 || { [[ $pct -gt 100 ]] && pct=100; }
                pct_str="(${pct}%)"
            fi
        fi

        printf "  - %-13s : %5s hits  %s\n" "$task" "$count" "$pct_str"
    done
}

# ------------------------------------------------------------------------------
# 4. 거대 이미지 도출
# ------------------------------------------------------------------------------
find_large_outputs() {
    local log_file="$1"
    local use_ssh="$2"
    local target_ip="$3"
    readonly FILESIZE=2G

    echo -e "\n=== 4. Large Output Files (> $FILESIZE) ==="

    local path_src=""
    path_src=$(grep -E -m1 "PATH_SRC=.*" "$log_file" | cut -d= -f2 | tr -d '"\n\r' || echo ".")
    [[ -z "${path_src:-}" ]] && { echo -e "${COLOR_YELLOW}[WARN] PATH_SRC not found in log. ${COLOR_RESET}"; return 0; }

    local find_cmd="find \"${path_src:-.}\" -type f -size +$FILESIZE -exec ls -lh {} + 2>/dev/null | awk '{print \$5, \$6, \$7, \$8, \$9}' | sort -hr | head -n 5"
    local result=""

    if [[ "$use_ssh" -eq 1 && -n "$target_ip" ]]; then
        echo "Searching via SSH on $target_ip in ${path_src:-.}..."
        result=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "$find_cmd" 2>/dev/null || echo "FAILED")
    else
        echo "Searching locally in ${path_src:-.}..."
        result=$(eval "$find_cmd" 2>/dev/null || true)
    fi

    if [[ "$result" == "FAILED" ]]; then echo -e "${COLOR_RED}[FAIL] Failed to execute find via SSH.${COLOR_RESET}"
    elif [[ -n "$result" ]]; then        echo "$result"
    else                                 echo "No files larger than $FILESIZE were found."
    fi
}

# ------------------------------------------------------------------------------
# 메인 로직
# ------------------------------------------------------------------------------
main() {
    [[ $# -lt 1 ]] && { echo -e "$TAG_FAIL Usage: $0 <logfile path or url>"; exit 1; }
    local input="$1"

    # URL 입력 처리
    if [[ "$input" =~ ^http:// || "$input" =~ ^https:// ]]; then
        # Jenkins URL에 timestamp 파라미터가 없으면 추가
        if [[ "$input" =~ jenkins ]] && [[ ! "$input" =~ timestamps/\?time= ]]; then
            if [[ "$input" =~ (.*)/([0-9]+) ]]; then
                input="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog"
                echo -e "$TAG_OK Auto-adjusted Jenkins URL to include timestamp format"
            fi
        fi

        echo -e "$TAG_OK Downloading log from URL: $input"

        # HTTPS 시도 후 실패하면 HTTP로 fallback
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
        echo -e "$TAG_OK Copying target log file..."
        cp "$input" "$PATH_TEMP_LOG"
    else
        echo -e "$TAG_FAIL Target log is neither valid HTTP url nor existing file."
        exit 1
    fi

    # Remote Target Server check
    local target_log_ip=""
    target_log_ip=$(head -n 25 "$PATH_TEMP_LOG" | grep -Ei "Building remotely on" | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 || echo "")

    local local_ips
    local_ips=$(hostname -I 2>/dev/null || echo "127.0.0.1")

    local use_ssh=0
    if [[ -n "$target_log_ip" ]] && [[ ! "$local_ips" =~ $target_log_ip ]]; then
        echo -e "${COLOR_YELLOW}[WARN] Script runs locally but log generated on remote server: ${target_log_ip}${COLOR_RESET}"
        use_ssh=1
    fi

    check_server_spec "$target_log_ip"
    analyze_yocto_config "$PATH_TEMP_LOG"
    analyze_time "$PATH_TEMP_LOG"
    #find_large_outputs "$PATH_TEMP_LOG" "$use_ssh" "$target_log_ip"

    echo -e "\n$TAG_OK Analysis Complete!"
}

main "$@"
