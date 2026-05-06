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
readonly COLOR_CYAN="\033[96m\033[1m"
readonly COLOR_BLUE="\033[94m\033[1m"
readonly COLOR_RESET="\033[0m"

readonly TAG_OK="${COLOR_GREEN}[OKAY]${COLOR_RESET}"
readonly TAG_FAIL="${COLOR_RED}[FAIL]${COLOR_RESET}"
readonly TAG_WARN="${COLOR_YELLOW}[WARN]${COLOR_RESET}"

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

# 두 시각(HH:MM:SS) 간의 시간차를 계산하여 HH:MM:SS 형식으로 반환
# 파라미터: $1=start_time, $2=end_time
# 반환: HH:MM:SS 형식 문자열 (printf로 출력)
calc_duration() {
    local start="$1" end="$2"
    [[ -z "$start" || -z "$end" ]] && return
    
    # 시작/종료 시간을 epoch 초로 변환
    local s_sec e_sec
    s_sec=$(date -u -d "1970-01-01 $start" +"%s" 2>/dev/null || echo 0)
    e_sec=$(date -u -d "1970-01-01 $end" +"%s" 2>/dev/null || echo 0)
    
    # 자정을 넘긴 경우 처리 (종료 시간이 시작 시간보다 작으면 +24시간)
    if (( e_sec < s_sec )); then e_sec=$((e_sec + 86400)); fi
    
    # 시간차를 HH:MM:SS 형식으로 변환하여 출력
    local diff=$((e_sec - s_sec))
    printf "%02d:%02d:%02d" $((diff/3600)) $((diff%3600/60)) $((diff%60))
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

    echo -e "\n${COLOR_CYAN}=== 1. Server Specification & Score ($location_str) ===${COLOR_RESET}"

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
# 파라미터: $1=log_file (분석 대상 로그 파일 경로)
analyze_time() {
    local log_file="$1"
    echo -e "\n${COLOR_CYAN}=== 2. Time Analysis ===${COLOR_RESET}"

    local start_time end_time total_duration s_sec=0 e_sec=0 total_diff=0

    # 로그 시작/종료 시간 추출 (타임스탬프 있는/없는 로그 모두 지원)
    # 로그 앞부분 50줄과 뒷부분 100줄에서 HH:MM:SS 패턴 검색
    start_time=$(head -n 50 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || echo "Unknown")
    end_time=$(tail -n 100 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | tail -1 || echo "Unknown")

    # 전체 빌드 소요 시간 계산 및 출력
    if [[ "$start_time" != "Unknown" && "$end_time" != "Unknown" ]]; then
        total_duration=$(calc_duration "$start_time" "$end_time")
        echo -e "${COLOR_GREEN}Overall Start Time ~ Overall End Time:${COLOR_RESET} ($start_time ~ $end_time) = $total_duration"

        # 시간차를 초 단위로 변환 (Task 비율 계산용)
        s_sec=$(date -u -d "1970-01-01 $start_time" +"%s" 2>/dev/null || echo 0)
        e_sec=$(date -u -d "1970-01-01 $end_time" +"%s" 2>/dev/null || echo 0)
        (( e_sec < s_sec )) && e_sec=$((e_sec + 86400))  # 자정 넘김 보정
        total_diff=$((e_sec - s_sec))
    else
        echo "Overall Start Time ~ Overall End Time: ($start_time ~ $end_time)"
    fi

    # Yocto Tasks 카운팅 및 첫 등장 시간 비율 계산
    # 각 Task가 로그에 몇 번 등장했는지, 전체 빌드 시간 중 몇 %에 첫 등장했는지 분석
    echo -e "\n- Task Extracted Count (1st hit time ratio):"
    for task in do_fetch do_unpack do_patch do_configure do_compile do_install do_package do_rootfs do_image; do
        local count pct_str="" t_hit t_sec pct
        count=$(grep -a -c "$task" "$log_file" || true)

        if [[ "$count" -gt 0 && "$total_diff" -gt 0 ]]; then
            # 해당 Task의 첫 등장 시간 추출
            t_hit=$(grep -a -m1 "$task" "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || true)
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
# 파라미터: $1=log_file (분석 대상 로그 파일 경로), $2=target_ip (원격 서버 IP)
analyze_config_and_cache() {
    local log_file="$1" target_ip="$2"
    echo -e "\n${COLOR_CYAN}=== 3. Yocto Build Configuration & Cache Analysis ===${COLOR_RESET}"
    
    # 내부 함수: 로그에서 특정 변수의 값을 추출
    extract_val() {
        grep -E "${TIMESTAMP_OPTIONAL}[[:space:]]*$1[[:space:]]*[?:]?=" "$log_file" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo ""
    }
    
    # 내부 함수: 원격/로컬 경로 존재 여부 확인
    check_path_exists() {
        local path="$1" tip="$2"
        if [[ -n "$tip" ]]; then
            ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$tip" "test -d '$path'" 2>/dev/null && echo "1" || echo "0"
        else
            [[ -d "$path" ]] && echo "1" || echo "0"
        fi
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
    local threads=$(extract_val BB_NUMBER_THREADS)
    local make_jobs=$(extract_val PARALLEL_MAKE)
    local scons_jobs=$(extract_val SCONS_OVERRIDE_NUM_JOBS)
    local dl_dir=$(extract_val DL_DIR)
    local premirrors=$(extract_val SOURCE_MIRROR_URL)
    [[ -z "$premirrors" ]] && premirrors=$(extract_val PREMIRRORS)
    local mirrors=$(extract_val MIRRORS)
    local sstate_mirrors=$(extract_val SSTATE_MIRRORS)
    [[ -z "$sstate_mirrors" ]] && sstate_mirrors=$(extract_val SSTATE_LOCAL_MIRROR)
    
    # 간접 증거 감지
    [[ -z "$premirrors" ]] && grep -aq "will check PREMIRRORS\|from PREMIRRORS\|Trying PREMIRROR" "$log_file" 2>/dev/null && premirrors="CONFIGURED (detected from log-message)"
    [[ -z "$sstate_mirrors" ]] && grep -aq "Sstate summary:" "$log_file" 2>/dev/null && sstate_mirrors="CONFIGURED (detected from log-message)"
    
    # 추가 검색: 빌드 디렉토리의 local.conf에서 직접 찾기 (항상 실행)
    local PATH_REMOTESRC=$(grep -a -B1 "SUCCESS: yocto build" "$log_file" | head -1 | grep -oP '[0-9]{2}:[0-9]{2}:[0-9]{2}\s+\K/.*' 2>/dev/null || echo "")
    if [[ -n "$PATH_REMOTESRC" ]]; then
        local local_conf="$PATH_REMOTESRC/conf/local.conf"
        local premirrors_from_conf="" sstate_mirrors_from_conf=""
        
        # 원격/로컬 서버에서 파일 존재 확인 및 내용 읽기
        if [[ -n "$target_ip" ]]; then
            # 원격 서버에서 검색
            if ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "test -f '$local_conf'" 2>/dev/null; then
                premirrors_from_conf=$(ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "grep -E 'SOURCE_MIRROR_URL|PREMIRRORS' '$local_conf' | head -1" 2>/dev/null | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo "")
                sstate_mirrors_from_conf=$(ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "grep -E 'SSTATE_MIRRORS|SSTATE_LOCAL_MIRROR' '$local_conf' | head -1" 2>/dev/null | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo "")
            fi
        else
            # 로컬 파일에서 검색
            if [[ -f "$local_conf" ]]; then
                premirrors_from_conf=$(grep -E 'SOURCE_MIRROR_URL|PREMIRRORS' "$local_conf" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo "")
                sstate_mirrors_from_conf=$(grep -E 'SSTATE_MIRRORS|SSTATE_LOCAL_MIRROR' "$local_conf" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo "")
            fi
        fi
        
        # 결과값이 있으면 업데이트 (detected from source 태그 추가)
        if [[ -n "$premirrors_from_conf" ]]; then
            premirrors="$premirrors_from_conf (detected from source)"
        fi
        if [[ -n "$sstate_mirrors_from_conf" ]]; then
            sstate_mirrors="$sstate_mirrors_from_conf (detected from source)"
        fi
    fi
    
    # ========== 요약 정보 출력 ==========
    [[ -n "$threads" ]] && echo -e "$TAG_OK BB_NUMBER_THREADS = $threads" || echo -e "$TAG_WARN BB_NUMBER_THREADS not found"
    [[ -n "$make_jobs" ]] && echo -e "$TAG_OK PARALLEL_MAKE = $make_jobs" || echo -e "$TAG_WARN PARALLEL_MAKE not found"
    [[ -n "$scons_jobs" ]] && echo -e "$TAG_OK SCONS_OVERRIDE_NUM_JOBS = $scons_jobs" || echo -e "$TAG_WARN SCONS_OVERRIDE_NUM_JOBS not found"
    [[ -n "$dl_dir" ]] && echo -e "$TAG_OK DL_DIR = $dl_dir" || echo -e "$TAG_WARN DL_DIR not found"
    
    # PREMIRRORS 요약
    if [[ -n "$premirrors" ]]; then
        if [[ "$premirrors" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "$TAG_OK PREMIRRORS = Configured (detected from log-message)"
        elif [[ "$premirrors" =~ "detected from source" ]]; then
            local pure_path=$(extract_pure_path "${premirrors% (detected from source)}" "0")
            [[ "$(check_path_exists "$pure_path" "$target_ip")" -eq 1 ]] && echo -e "$TAG_OK PREMIRRORS = $premirrors" || echo -e "${COLOR_RED}[FAIL] PREMIRRORS path not exists: $pure_path${COLOR_RESET}"
        else
            local pure_path=$(extract_pure_path "$premirrors" "0")
            [[ "$(check_path_exists "$pure_path" "$target_ip")" -eq 1 ]] && echo -e "$TAG_OK PREMIRRORS = $premirrors" || echo -e "${COLOR_RED}[FAIL] PREMIRRORS path not exists: $pure_path${COLOR_RESET}"
        fi
    else
        echo -e "$TAG_WARN PREMIRRORS not found"
    fi
    
    # MIRRORS 요약
    if [[ -n "$mirrors" ]]; then
        local pure_path=$(extract_pure_path "$mirrors" "0")
        [[ "$(check_path_exists "$pure_path" "$target_ip")" -eq 1 ]] && echo -e "$TAG_OK MIRRORS = $mirrors" || echo -e "${COLOR_RED}[FAIL] MIRRORS path not exists: $pure_path${COLOR_RESET}"
    else
        echo -e "$TAG_WARN MIRRORS not found"
    fi
    
    # SSTATE_MIRRORS 요약
    if [[ -n "$sstate_mirrors" ]]; then
        if [[ "$sstate_mirrors" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "$TAG_OK SSTATE_MIRRORS = Configured (detected from log-message)"
        elif [[ "$sstate_mirrors" =~ "detected from source" ]]; then
            local pure_path=$(extract_pure_path "${sstate_mirrors% (detected from source)}" "1")
            [[ "$(check_path_exists "$pure_path" "$target_ip")" -eq 1 ]] && echo -e "$TAG_OK SSTATE_MIRRORS = $sstate_mirrors" || echo -e "${COLOR_RED}[FAIL] SSTATE_MIRRORS path not exists: $pure_path${COLOR_RESET}"
        else
            local pure_path=$(extract_pure_path "$sstate_mirrors" "1")
            [[ "$(check_path_exists "$pure_path" "$target_ip")" -eq 1 ]] && echo -e "$TAG_OK SSTATE_MIRRORS = $sstate_mirrors" || echo -e "${COLOR_RED}[FAIL] SSTATE_MIRRORS path not exists: $pure_path${COLOR_RESET}"
        fi
    else
        echo -e "$TAG_WARN SSTATE_MIRRORS not found (sstate-cache sharing not configured)"
    fi
    
    # ========== PREMIRRORS 세부 정보 ==========
    if [[ -n "$premirrors" ]]; then
        echo -e "\n${COLOR_BLUE}--- 3.1. Premirror Details ---${COLOR_RESET}"
        echo -e "${COLOR_GREEN}[Fetch Statistics]${COLOR_RESET}"
        local total_fetch=$(grep -a "recipe.*do_fetch.*Started" "$log_file" 2>/dev/null | wc -l | xargs)
        local premirror_fetch=$(grep -aiE "Trying PREMIRROR|from PREMIRRORS|will check PREMIRRORS" "$log_file" 2>/dev/null | wc -l | xargs)
        local internet_fetch=$(grep -aE "Fetching.*http[s]?://" "$log_file" 2>/dev/null | wc -l | xargs)
        local cache_fetch=$((total_fetch - premirror_fetch - internet_fetch))
        [[ $cache_fetch -lt 0 ]] && cache_fetch=0
        printf "  - Total: %s, From premirror: %s, From internet: %s, From cache: %s\n" "${total_fetch:-0}" "${premirror_fetch:-0}" "${internet_fetch:-0}" "$cache_fetch"
        
        echo -e "${COLOR_GREEN}[Premirror Storage]${COLOR_RESET}"
        if [[ "$premirrors" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "  - Path: CONFIGURED (detected from log-message) (not accessible or does not exist)"
        else
            local premirror_path_raw="$premirrors"
            [[ "$premirror_path_raw" =~ "detected from source" ]] && premirror_path_raw="${premirror_path_raw% (detected from source)}"
            local premirror_path=$(extract_pure_path "$premirror_path_raw" "0")
            if [[ -n "$premirror_path" ]]; then
                if [[ -n "$target_ip" ]]; then
                    # 원격 서버에서 크기 확인
                    if ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "test -d '$premirror_path'" 2>/dev/null; then
                        local premirror_size=$(ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "du -sh '$premirror_path' 2>/dev/null | awk '{print \$1}'" || echo "Unknown")
                        echo -e "  - Path: $premirror_path"
                        echo -e "  - Size: $premirror_size"
                    else
                        echo -e "  - Path: $premirror_path (not accessible)"
                    fi
                elif [[ -d "$premirror_path" ]]; then
                    local premirror_size=$(du -sh "$premirror_path" 2>/dev/null | awk '{print $1}' || echo "Unknown")
                    echo -e "  - Path: $premirror_path"
                    echo -e "  - Size: $premirror_size"
                else
                    echo -e "  - Path: $premirror_path (not accessible)"
                fi
            fi
        fi
        
        echo -e "${COLOR_GREEN}[Modules fetched from internet]${COLOR_RESET}"
        local fetching_lines=$(grep -a "Fetching.*http" "$log_file" 2>/dev/null || echo "")
        if [[ -n "$fetching_lines" ]]; then
            echo "$fetching_lines" | while IFS= read -r line; do
                local timestamp=$(echo "$line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
                local url=$(echo "$line" | grep -oP 'http[s]?://[^\s;]+' | head -1)
                local file=$(basename "$url" | cut -d'?' -f1 | cut -d';' -f1)
                local domain=$(echo "$url" | cut -d'/' -f3)
                if [[ -n "$file" && -n "$domain" ]]; then
                    [[ -n "$timestamp" ]] && echo "  - [$timestamp] $file (from $domain)" || echo "  - $file (from $domain)"
                fi
            done
        else
            echo "  - None (all sources were cached in DL_DIR or PREMIRRORS)"
        fi
        
        echo -e "${COLOR_GREEN}[Modules with fetch activity]${COLOR_RESET}"
        echo "  - These modules had fetch tasks executed (may be from cache):"
        local fetch_lines=$(grep -a "recipe.*do_fetch.*Started" "$log_file" 2>/dev/null || echo "")
        if [[ -n "$fetch_lines" ]]; then
            echo "$fetch_lines" | while IFS= read -r line; do
                local timestamp=$(echo "$line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
                local module=$(echo "$line" | grep -oP 'recipe \K[^:]+' || echo "")
                if [[ -n "$module" ]]; then
                    [[ -n "$timestamp" ]] && echo "    [$timestamp] $module" || echo "    $module"
                fi
            done
        else
            echo "    None"
        fi
    fi
    
    # ========== SSTATE-CACHE 세부 정보 ==========
    if [[ -n "$sstate_mirrors" ]]; then
        echo -e "\n${COLOR_BLUE}--- 3.2. Sstate-cache Details ---${COLOR_RESET}"
        echo -e "${COLOR_GREEN}[Cache Hit Rate]${COLOR_RESET}"
        local sstate_summary=$(grep -a "Sstate summary:" "$log_file" 2>/dev/null || echo "")
        if [[ -n "$sstate_summary" ]]; then
            local wanted=$(echo "$sstate_summary" | grep -oP 'Wanted \K[0-9]+' || echo "0")
            local found=$(echo "$sstate_summary" | grep -oP 'Found \K[0-9]+' || echo "0")
            local missed=$(echo "$sstate_summary" | grep -oP 'Missed \K[0-9]+' || echo "0")
            [[ "$wanted" -gt 0 ]] && local hit_rate=$(( found * 100 / wanted )) || local hit_rate=0
            printf "  - Hit rate: %s%% (%s/%s), Missed: %s\n" "$hit_rate" "$found" "$wanted" "$missed"
        else
            echo "  - Sstate summary not found in log"
        fi
        
        echo -e "${COLOR_GREEN}[Storage]${COLOR_RESET}"
        if [[ "$sstate_mirrors" == "CONFIGURED (detected from log-message)" ]]; then
            echo -e "  - Path: CONFIGURED (detected from log-message) (not accessible or does not exist)"
        else
            local sstate_path_raw="$sstate_mirrors"
            [[ "$sstate_path_raw" =~ "detected from source" ]] && sstate_path_raw="${sstate_path_raw% (detected from source)}"
            local sstate_path=$(extract_pure_path "$sstate_path_raw" "1")
            if [[ -n "$sstate_path" ]]; then
                if [[ -n "$target_ip" ]]; then
                    # 원격 서버에서 크기 확인
                    if ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "test -d '$sstate_path'" 2>/dev/null; then
                        local sstate_size=$(ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "du -sh '$sstate_path' 2>/dev/null | awk '{print \$1}'" || echo "Unknown")
                        echo -e "  - Path: $sstate_path"
                        echo -e "  - Size: $sstate_size"
                    else
                        echo -e "  - Path: $sstate_path (not accessible)"
                    fi
                elif [[ -d "$sstate_path" ]]; then
                    local sstate_size=$(du -sh "$sstate_path" 2>/dev/null | awk '{print $1}' || echo "Unknown")
                    echo -e "  - Path: $sstate_path"
                    echo -e "  - Size: $sstate_size"
                else
                    echo -e "  - Path: $sstate_path (not accessible)"
                fi
            fi
        fi
        
        echo -e "${COLOR_GREEN}[Sstate-cache Miss Analysis]${COLOR_RESET}"
        local sstate_line=$(grep -a "Sstate summary:" "$log_file" 2>/dev/null || echo "")
        if [[ -n "$sstate_line" ]]; then
            local missed=$(echo "$sstate_line" | grep -oP 'Missed \K[0-9]+' || echo "0")
            if [[ "$missed" -gt 0 ]]; then
                echo "  - Reason: $missed tasks not found in sstate-cache (new/modified recipes or different build configuration)"
                echo "  - Impact: These tasks will be rebuilt from source instead of using cached artifacts"
            fi
        fi
        
        echo "  - Modules that required rebuild (first 10):"
        local setscene_tasks=$(grep -a "Running setscene task" "$log_file" 2>/dev/null | head -10 || echo "")
        if [[ -n "$setscene_tasks" ]]; then
            echo "$setscene_tasks" | while IFS= read -r line; do
                local timestamp=$(echo "$line" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || echo "")
                local recipe=$(echo "$line" | grep -oP 'recipes-[^/]+/[^/]+/\K[^:]+' || echo "$line" | grep -oP '/\K[^/:]+\.bb')
                local task=$(echo "$line" | grep -oP ':do_\K[^)]+' || echo "")
                if [[ -n "$recipe" ]]; then
                    [[ -n "$timestamp" ]] && echo "    [$timestamp] $recipe (task: do_$task)" || echo "    • $recipe (task: do_$task)"
                fi
            done
        else
            echo "    (No cache miss tasks found - all from cache)"
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

    echo -e "\n${COLOR_CYAN}=== 4. Large Output Files (> $FILESIZE) ===${COLOR_RESET}"

    set +e  # 명령 실패 허용

    # 빌드 디렉토리 추출 (3번 항목과 동일한 방식)
    local PATH_REMOTESRC=$(grep -a -B1 "SUCCESS: yocto build" "$log_file" | head -1 | grep -oP '[0-9]{2}:[0-9]{2}:[0-9]{2}\s+\K/.*' 2>/dev/null || echo "")
    
    if [[ -z "$PATH_REMOTESRC" ]]; then
        echo -e "${COLOR_YELLOW}[WARN] Build directory not found in log.${COLOR_RESET}"
        set -e
        return 0
    fi

    # tmp*/deploy/images 디렉토리 패턴 (tmp, tmp-glibc 등 지원)
    local deploy_pattern="$PATH_REMOTESRC/tmp*/deploy/images"
    
    echo -e "${COLOR_GREEN}[Build Directory]${COLOR_RESET}"
    echo "  - Build path: $PATH_REMOTESRC"
    echo "  - Search pattern: $deploy_pattern"
    
    # find 명령 생성: 지정된 크기 이상 파일 검색 후 크기순 정렬하여 상위 10개 추출
    local find_cmd="find $deploy_pattern -type f -size +$FILESIZE 2>/dev/null | xargs ls -lh 2>/dev/null | awk '{print \$5, \$9}' | sort -hr | head -n 10"
    
    echo -e "\n${COLOR_GREEN}[Large Files (Top 10)]${COLOR_RESET}"
    
    local result=""
    if [[ -n "$target_ip" ]]; then
        # 원격 서버에서 검색
        result=$(ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "$find_cmd" 2>/dev/null || echo "")
    else
        # 로컬에서 검색
        result=$(eval "$find_cmd" 2>/dev/null || echo "")
    fi
    
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
    # 사용법 출력
    if [[ $# -lt 1 ]]; then
        echo -e "$TAG_FAIL Usage: $0 <logfile path or url>"
        echo -e "  Example: $0 https://jenkins.../27/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog"
        echo -e "  or:      $0 https://jenkins.../27/consoleText"
        echo -e "  or:      $0 https://jenkins.../27/console"
        exit 1
    fi
    
    # 첫 번째 인자만 사용 (URL이 & 문자로 shell에서 분리되어도 기본 URL만 필요)
    local input target_log_ip local_ips
    input="$1"

    # 입력이 URL인 경우 로그 다운로드 처리
    if [[ "$input" =~ ^http:// || "$input" =~ ^https:// ]]; then
        # Jenkins URL인 경우 항상 timestamps 형식으로 정규화
        if [[ "$input" =~ jenkins ]]; then
            # build number까지의 기본 URL 추출: .../job_name/build_number
            if [[ "$input" =~ (https?://[^/]+/.*/[0-9]+) ]]; then
                local base_url="${BASH_REMATCH[1]}"
                input="${base_url}/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog"
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
    [[ -n "$target_log_ip" ]] && [[ ! "$local_ips" =~ $target_log_ip ]] && echo -e "${COLOR_YELLOW}[WARN] Script runs locally but log generated on remote server: ${target_log_ip}${COLOR_RESET}"

    # 분석 함수 순차 실행: 서버 사양 → 시간 분석 → 설정 및 캐시 분석 → 대용량 파일 검색
    check_server_spec "$target_log_ip"
    analyze_time "$PATH_TEMP_LOG"
    analyze_config_and_cache "$PATH_TEMP_LOG" "$target_log_ip"
    find_large_outputs "$PATH_TEMP_LOG" "$target_log_ip"

    echo -e "\n$TAG_OK Analysis Complete!"
}

main "$@"
