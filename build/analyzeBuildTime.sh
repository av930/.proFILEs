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
# 2. Yocto 설정값 분석
# ------------------------------------------------------------------------------
# 로그에서 Yocto 빌드 관련 설정값 추출 및 검증
# 파라미터: $1=log_file (분석 대상 로그 파일 경로)
analyze_yocto_config() {
    local log_file="$1"
    echo -e "\n${COLOR_CYAN}=== 2. Yocto Build Configuration Check ===${COLOR_RESET}"

    # 내부 함수: 로그에서 특정 변수의 값을 추출
    # 타임스탬프가 있는/없는 로그 모두 지원 (TIMESTAMP_OPTIONAL regexp 사용)
    # 따옴표 및 작은따옴표 제거하여 순수 값만 반환
    extract_val() {
        grep -E "${TIMESTAMP_OPTIONAL}[[:space:]]*$1[[:space:]]*[?:]?=" "$log_file" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo ""
    }

    # Yocto 주요 설정값 추출: 병렬 빌드 설정
    local threads=$(extract_val BB_NUMBER_THREADS)
    local make_jobs=$(extract_val PARALLEL_MAKE)
    local scons_jobs=$(extract_val SCONS_OVERRIDE_NUM_JOBS)
    
    # 소스 다운로드 디렉토리 및 미러 설정 추출
    local dl_dir=$(extract_val DL_DIR)
    local premirrors=$(extract_val SOURCE_MIRROR_URL)
    [[ -z "$premirrors" ]] && premirrors=$(extract_val PREMIRRORS)
    local mirrors=$(extract_val MIRRORS)
    
    # Sstate 캐시 디렉토리 추출 (여러 변수명 시도)
    local sstate=$(extract_val SSTATE_LOCAL_MIRROR)
    [[ -z "$sstate" ]] && sstate=$(extract_val SSTATE_DIR)
    [[ -z "$sstate" ]] && sstate=$(extract_val SSTATECACHE)

    # 추출된 설정값 검증 및 출력 (값이 있으면 OK, 없으면 WARN)
    [[ -n "$threads" ]] && echo -e "$TAG_OK BB_NUMBER_THREADS = $threads" || echo -e "$TAG_WARN BB_NUMBER_THREADS not found"
    [[ -n "$make_jobs" ]] && echo -e "$TAG_OK PARALLEL_MAKE = $make_jobs" || echo -e "$TAG_WARN PARALLEL_MAKE not found"
    [[ -n "$scons_jobs" ]] && echo -e "$TAG_OK SCONS_OVERRIDE_NUM_JOBS = $scons_jobs" || echo -e "$TAG_WARN SCONS_OVERRIDE_NUM_JOBS not found"
    [[ -n "$dl_dir" ]] && echo -e "$TAG_OK DL_DIR = $dl_dir" || echo -e "$TAG_WARN DL_DIR not found"
    [[ -n "$premirrors" ]] && echo -e "$TAG_OK PREMIRRORS = $premirrors" || echo -e "$TAG_WARN PREMIRRORS not found"
    [[ -n "$mirrors" ]] && echo -e "$TAG_OK MIRRORS = $mirrors" || echo -e "$TAG_WARN MIRRORS not found"
    [[ -n "$sstate" ]] && echo -e "$TAG_OK SSTATE_DIR = $sstate" || echo -e "$TAG_WARN SSTATE_DIR not found"

    # Sstate 캐시 적중률 요약 정보 출력 (로그에 있는 경우)
    grep -a "Sstate summary:" "$log_file" || true
}

# ------------------------------------------------------------------------------
# 3. 소요 시간 파싱
# ------------------------------------------------------------------------------
# 로그에서 빌드 시작/종료 시간 추출 및 각 Yocto Task별 수행 시간 분석
# 파라미터: $1=log_file (분석 대상 로그 파일 경로)
analyze_time() {
    local log_file="$1"
    echo -e "\n${COLOR_CYAN}=== 3. Time Analysis ===${COLOR_RESET}"

    local start_time end_time total_duration s_sec=0 e_sec=0 total_diff=0

    # 로그 시작/종료 시간 추출 (타임스탬프 있는/없는 로그 모두 지원)
    # 로그 앞부분 50줄과 뒷부분 100줄에서 HH:MM:SS 패턴 검색
    start_time=$(head -n 50 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || echo "Unknown")
    end_time=$(tail -n 100 "$log_file" | grep -Eo "${TIMESTAMP_OPTIONAL}[0-9]{2}:[0-9]{2}:[0-9]{2}" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}" | tail -1 || echo "Unknown")

    # 전체 빌드 소요 시간 계산 및 출력
    if [[ "$start_time" != "Unknown" && "$end_time" != "Unknown" ]]; then
        total_duration=$(calc_duration "$start_time" "$end_time")
        echo "Overall Start Time ~ Overall End Time: ($start_time ~ $end_time) = $total_duration"

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
# 4. Premirror 및 Sstate-cache 피드백
# ------------------------------------------------------------------------------
# Premirror와 Sstate-cache 사용 현황 분석 및 피드백 제공
# 파라미터: $1=log_file (분석 대상 로그 파일 경로)
report_feedback() {
    local log_file="$1"
    echo -e "\n${COLOR_CYAN}=== 4. Premirror & Sstate-cache Feedback ===${COLOR_RESET}"

    # 내부 함수: 로그에서 특정 변수의 값을 추출
    extract_val() {
        grep -E "${TIMESTAMP_OPTIONAL}[[:space:]]*$1[[:space:]]*[?:]?=" "$log_file" | head -1 | sed 's/.*=[[:space:]]*//;s/^"//;s/"$//;s/'\''//g' || echo ""
    }

    # 이 함수 내에서는 명령 실패를 허용 (grep 매치 실패 등)
    set +e

    # ------------------------------------------------------------------------------
    # 4.1. Premirror 분석
    # ------------------------------------------------------------------------------
    local premirrors=$(extract_val SOURCE_MIRROR_URL)
    [[ -z "$premirrors" ]] && premirrors=$(extract_val PREMIRRORS)
    
    if [[ -n "$premirrors" ]]; then
        echo -e "\n${COLOR_BLUE}--- 4.1. Premirror Analysis ---${COLOR_RESET}"
        
        # 현재 적용 결과: do_fetch 통계 추출
        echo -e "\n[Current Status]"
        local total_fetch premirror_fetch internet_fetch
        
        total_fetch=$(grep -a "do_fetch" "$log_file" 2>/dev/null | wc -l | xargs)
        total_fetch=${total_fetch:-0}
        
        premirror_fetch=$(grep -a "Fetching.*from PREMIRRORS" "$log_file" 2>/dev/null | wc -l | xargs)
        premirror_fetch=${premirror_fetch:-0}
        
        internet_fetch=$(grep -a "Fetching.*from upstream" "$log_file" 2>/dev/null | wc -l | xargs)
        internet_fetch=${internet_fetch:-0}
        
        # 통계가 명시적이지 않으면 로그 패턴으로 추정
        if [[ "$premirror_fetch" -eq 0 ]] && [[ "$internet_fetch" -eq 0 ]]; then
            premirror_fetch=$(grep -aE "Trying PREMIRROR|from PREMIRRORS" "$log_file" 2>/dev/null | wc -l | xargs)
            premirror_fetch=${premirror_fetch:-0}
            
            internet_fetch=$(grep -aE "Fetching.*http[s]?://|do_fetch.*from upstream" "$log_file" 2>/dev/null | wc -l | xargs)
            internet_fetch=${internet_fetch:-0}
        fi
        
        printf "  - Total fetch tasks    : %s\n" "$total_fetch"
        printf "  - Fetched from premirror: %s\n" "$premirror_fetch"
        printf "  - Downloaded from internet: %s\n" "$internet_fetch"
        
        # 현재 설정: premirror 설정 파일 및 라인 번호 추출
        echo -e "\n[Configuration]"
        local config_info=$(grep -naE "SOURCE_MIRROR_URL|PREMIRRORS" "$log_file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$config_info" ]]; then
            local line_num=$(echo "$config_info" | cut -d: -f1)
            echo -e "  - Setting: PREMIRRORS = $premirrors"
            echo -e "  - Location: Log line $line_num"
        else
            echo -e "  - Setting: PREMIRRORS = $premirrors"
            echo -e "  - Location: Not found in log"
        fi
        
        # 실제 premirror 경로 및 크기
        echo -e "\n[Premirror Storage]"
        # premirror 경로에서 file:// 프로토콜 제거하고 실제 경로 추출
        local premirror_path=$(echo "$premirrors" | grep -oP 'file://\K[^ ]+' | head -1 || echo "")
        if [[ -z "$premirror_path" ]]; then
            premirror_path=$(echo "$premirrors" | sed 's/.*file:\/\/\([^ ]*\).*/\1/' | head -1)
        fi
        # 경로 중복 제거 (// 등)
        premirror_path=$(echo "$premirror_path" | sed 's|//*|/|g')
        
        if [[ -n "$premirror_path" && -d "$premirror_path" ]]; then
            local premirror_size=$(du -sh "$premirror_path" 2>/dev/null | awk '{print $1}' || echo "Unknown")
            echo -e "  - Path: $premirror_path"
            echo -e "  - Size: $premirror_size"
        elif [[ -n "$premirror_path" ]]; then
            echo -e "  - Path: $premirror_path (not accessible or does not exist)"
        else
            echo -e "  - Path: Could not extract from PREMIRRORS setting"
        fi
        
        # do_fetch를 수행한 모듈 및 premirror 미사용 이유
        echo -e "\n[Modules requiring internet fetch]"
        local fetch_modules=$(grep -aE "do_fetch.*\[.*\]|NOTE: recipe .*: task do_fetch" "$log_file" 2>/dev/null | head -10 || echo "")
        if [[ -n "$fetch_modules" ]]; then
            echo "$fetch_modules" | while IFS= read -r line; do
                # 모듈명 추출
                local module=$(echo "$line" | grep -oP '(?<=recipe ).*?(?=:)' || echo "$line" | grep -oP '\[.*?\]' || echo "")
                [[ -n "$module" ]] && echo "  - $module"
            done | head -10
            
            echo -e "\n  [Possible reasons for not using premirror]"
            echo "  - File not present in premirror directory"
            echo "  - Checksum mismatch with premirror file"
            echo "  - Git/SVN repositories (premirror only works for tarballs)"
            echo "  - Recipe explicitly requires fresh download"
        else
            echo "  - No internet fetch detected or all fetches used premirror"
        fi
    else
        echo -e "\n${COLOR_BLUE}--- 4.1. Premirror Analysis ---${COLOR_RESET}"
        echo -e "$TAG_WARN PREMIRRORS not configured"
    fi

    # ------------------------------------------------------------------------------
    # 4.2. Sstate-cache 분석
    # ------------------------------------------------------------------------------
    local sstate=$(extract_val SSTATE_LOCAL_MIRROR)
    [[ -z "$sstate" ]] && sstate=$(extract_val SSTATE_DIR)
    [[ -z "$sstate" ]] && sstate=$(extract_val SSTATECACHE)
    
    if [[ -n "$sstate" ]]; then
        echo -e "\n${COLOR_BLUE}--- 4.2. Sstate-cache Analysis ---${COLOR_RESET}"
        
        # 현재 적용 결과: Sstate summary 추출 및 해석
        echo -e "\n[Current Status - Sstate Summary]"
        local sstate_summary=$(grep -a "Sstate summary:" "$log_file" 2>/dev/null || echo "")
        if [[ -n "$sstate_summary" ]]; then
            echo "$sstate_summary" | while IFS= read -r line; do
                echo "  $line"
            done
            
            # 통계 추출 및 해석
            local wanted=$(echo "$sstate_summary" | grep -oP 'Wanted \K[0-9]+' || echo "0")
            local found=$(echo "$sstate_summary" | grep -oP 'Found \K[0-9]+' || echo "0")
            local missed=$(echo "$sstate_summary" | grep -oP 'Missed \K[0-9]+' || echo "0")
            
            if [[ "$wanted" -gt 0 ]]; then
                local hit_rate=$(( found * 100 / wanted ))
                echo -e "\n  - Hit rate: ${hit_rate}% ($found/$wanted)"
                echo -e "  - Miss count: $missed"
            fi
        else
            echo "  - Sstate summary not found in log"
        fi
        
        # 현재 설정: sstate 설정 파일 및 라인 번호 추출
        echo -e "\n[Configuration]"
        local sstate_config=$(grep -naE "SSTATE_LOCAL_MIRROR|SSTATE_DIR|SSTATECACHE" "$log_file" 2>/dev/null | head -1 || echo "")
        if [[ -n "$sstate_config" ]]; then
            local line_num=$(echo "$sstate_config" | cut -d: -f1)
            echo -e "  - Setting: SSTATE_DIR = $sstate"
            echo -e "  - Location: Log line $line_num"
        else
            echo -e "  - Setting: SSTATE_DIR = $sstate"
            echo -e "  - Location: Not found in log"
        fi
        
        # 실제 sstate-cache 경로 및 크기
        echo -e "\n[Sstate-cache Storage]"
        # sstate 경로에서 file:// 프로토콜 제거
        local sstate_path=$(echo "$sstate" | sed 's|file://||' | sed 's|^"||' | sed 's|"$||')
        # 경로 중복 제거 (// 등)
        sstate_path=$(echo "$sstate_path" | sed 's|//*|/|g')
        
        if [[ -n "$sstate_path" && -d "$sstate_path" ]]; then
            local sstate_size=$(du -sh "$sstate_path" 2>/dev/null | awk '{print $1}' || echo "Unknown")
            echo -e "  - Path: $sstate_path"
            echo -e "  - Size: $sstate_size"
        elif [[ -n "$sstate_path" ]]; then
            echo -e "  - Path: $sstate_path (not accessible or does not exist)"
        else
            echo -e "  - Path: Could not extract from SSTATE setting"
        fi
        
        # Cache miss한 모듈 및 이유
        echo -e "\n[Modules with cache miss]"
        local miss_modules=$(grep -aE "Sstate.*not yet built|NOTE: No suitable staging package|Sstate: Looked for but didn't find" "$log_file" 2>/dev/null | head -10 || echo "")
        if [[ -n "$miss_modules" ]]; then
            echo "$miss_modules" | while IFS= read -r line; do
                # 모듈명 추출
                local module=$(echo "$line" | grep -oP 'for .*' || echo "$line")
                echo "  - $module"
            done | head -10
            
            echo -e "\n  [Possible reasons for cache miss]"
            echo "  - Recipe or dependency changed (different signature)"
            echo "  - Never built before on this configuration"
            echo "  - Sstate-cache was cleared or not shared properly"
            echo "  - Build machine or architecture mismatch"
            echo "  - Recipe version or patch updated"
        else
            # 대안: do_populate_sysroot 또는 do_package 작업 확인
            local rebuild_tasks=$(grep -aE "do_populate_sysroot|do_package_write" "$log_file" 2>/dev/null | head -10)
            if [[ -n "$rebuild_tasks" ]]; then
                echo "  - Tasks that required rebuild (cache miss):"
                echo "$rebuild_tasks" | while IFS= read -r line; do
                    local task=$(echo "$line" | grep -oP 'recipe .*?:' || echo "$line" | head -c 80)
                    [[ -n "$task" ]] && echo "    $task"
                done | head -10
            else
                echo "  - No explicit cache miss detected or all tasks used cache"
            fi
        fi
    else
        echo -e "\n${COLOR_BLUE}--- 4.2. Sstate-cache Analysis ---${COLOR_RESET}"
        echo -e "$TAG_WARN SSTATE_DIR not configured"
    fi
    
    # 함수 종료 전 set -e 복원
    set -e
}

# ------------------------------------------------------------------------------
# 5. 거대 이미지 도출
# ------------------------------------------------------------------------------
# 빌드 결과물 중 큰 파일(2GB 이상) 탐색 및 출력
# 파라미터: $1=log_file, $2=use_ssh (원격 접속 여부), $3=target_ip (원격 서버 IP)
find_large_outputs() {
    local log_file="$1" use_ssh="$2" target_ip="$3" path_src find_cmd result
    readonly FILESIZE=2G

    echo -e "\n${COLOR_CYAN}=== 5. Large Output Files (> $FILESIZE) ===${COLOR_RESET}"

    # 로그에서 소스 경로(PATH_SRC) 추출
    path_src=$(grep -E -m1 "PATH_SRC=.*" "$log_file" | cut -d= -f2 | tr -d '"\n\r' || echo ".")
    [[ -z "${path_src:-}" ]] && { echo -e "${COLOR_YELLOW}[WARN] PATH_SRC not found in log. ${COLOR_RESET}"; return 0; }

    # find 명령 생성: 지정된 크기 이상 파일 검색 후 크기순 정렬하여 상위 5개 추출
    find_cmd="find \"${path_src:-.}\" -type f -size +$FILESIZE -exec ls -lh {} + 2>/dev/null | awk '{print \$5, \$6, \$7, \$8, \$9}' | sort -hr | head -n 5"

    # 로컬/원격 서버 선택하여 find 명령 실행
    if   [[ "$use_ssh" -eq 1 && -n "$target_ip" ]]; then echo "Searching via SSH on $target_ip in ${path_src:-.}...";  result=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$target_ip" "$find_cmd" 2>/dev/null || echo "FAILED")
    else                                                  echo "Searching locally in ${path_src:-.}...";               result=$(eval "$find_cmd" 2>/dev/null || true)
    fi

    # 검색 결과 출력 (실패/성공/결과없음)
    if   [[ "$result" == "FAILED" ]]; then echo -e "${COLOR_RED}[FAIL] Failed to execute find via SSH.${COLOR_RESET}"
    elif [[ -n "$result" ]];       then echo "$result"
    else                                echo "No files larger than $FILESIZE were found."
    fi
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
    local input target_log_ip local_ips use_ssh=0
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
    [[ -n "$target_log_ip" ]] && [[ ! "$local_ips" =~ $target_log_ip ]] && { echo -e "${COLOR_YELLOW}[WARN] Script runs locally but log generated on remote server: ${target_log_ip}${COLOR_RESET}"; use_ssh=1; }

    # 분석 함수 순차 실행: 서버 사양 → Yocto 설정 → 시간 분석 → 피드백 → 거대 파일 검색
    check_server_spec "$target_log_ip"
    analyze_yocto_config "$PATH_TEMP_LOG"
    analyze_time "$PATH_TEMP_LOG"
    report_feedback "$PATH_TEMP_LOG"
    #find_large_outputs "$PATH_TEMP_LOG" "$use_ssh" "$target_log_ip"

    echo -e "\n$TAG_OK Analysis Complete!"
}

main "$@"
