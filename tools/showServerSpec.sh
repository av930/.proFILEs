#!/bin/bash
set -euo pipefail

# ==============================================================================
# 서버 사양과 네트워크 경로를 조회하는 스크립트
# 사용법: ./showServerSpec.sh [status|install]
# ==============================================================================

readonly RED='\e[1;31m'
readonly GREEN='\e[1;32m'
readonly YELLOW='\e[1;33m'
readonly BLUE='\e[1;34m'
readonly CYAN='\e[1;36m'
readonly NCOL='\e[0m'

readonly TAG_OK="${GREEN}[OKAY]${NCOL}"
readonly TAG_FAIL="${RED}[FAIL]${NCOL}"
readonly TAG_WARN="${YELLOW}[WARN]${NCOL}"
readonly TARGET_HOST="google.com"
readonly TRACE_MAX_HOPS=16
readonly PING_COUNT=4
readonly SSH_OPTS=(-q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5)

# 사용법 출력
# 스크립트 실행 옵션 및 예제를 표시
usage() {
    echo "Usage: $0 [server_ip] [install]"
    echo "  (no args)              : Show CPU, memory, storage, and network summary (default)"
    echo "  server_ip              : Run on the remote server via ssh"
    echo "  install                : Install optional tools required for detailed network route analysis"
    echo "  server_ip install      : Install tools on the remote server"
    echo "ex: showServerSpec.sh"
    echo "ex: showServerSpec.sh 10.159.47.21 install"
}

# IPv4 주소 형식 판별
# 입력된 문자열이 유효한 IPv4 주소 형식인지 확인
is_ipv4_address() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# 입력 IP가 현재 서버의 로컬 IPv4인지 판별
# loopback 및 현재 인터페이스에 바인딩된 IPv4 주소와 비교
is_local_target_ip() {
    local target_ip="$1" local_ip=""

    [[ -z "$target_ip" ]] && return 1
    [[ "$target_ip" == "127.0.0.1" ]] && return 0

    if has_cmd ip; then
        while IFS= read -r local_ip; do
            [[ -z "$local_ip" ]] && continue
            [[ "$local_ip" == "$target_ip" ]] && return 0
        done < <(ip -o -4 addr show up 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    fi

    while IFS= read -r local_ip; do
        [[ -z "$local_ip" ]] && continue
        [[ "$local_ip" == "$target_ip" ]] && return 0
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    return 1
}

# 명령 존재 여부 확인
# 시스템에서 지정된 명령어 사용 가능 여부를 체크
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# lscpu 키 값 추출
# lscpu 출력에서 특정 필드명의 값을 추출
get_lscpu_field() {
    local field_name="$1"
    lscpu | while IFS= read -r line; do
        local lhs rhs
        lhs="$(trim "${line%%:*}")"
        rhs="$(trim "${line#*:}")"
        [[ "$lhs" == "$field_name" ]] && { echo "$rhs"; break; }
    done
}

# 여러 lscpu 키 중 첫 번째 값을 추출
# 여러 필드명 중 값이 존재하는 첫 번째 필드의 값을 반환
get_first_lscpu_field() {
    local field_name=""
    for field_name in "$@"; do
        local field_value
        field_value="$(get_lscpu_field "$field_name")"
        [[ -n "$field_value" ]] && { echo "$field_value"; return 0; }
    done
}

# 문자열 앞뒤 공백 제거
# 입력 문자열의 leading/trailing whitespace 제거
trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    echo "$value"
}

# 문자 반복 출력
# 지정된 문자를 주어진 횟수만큼 반복하여 출력
repeat_char() {
    printf '%*s' "$2" '' | tr ' ' "$1"
}

# IPv4가 RFC1918 사설망인지 판별
# 10.x.x.x, 172.16-31.x.x, 192.168.x.x 대역 체크
is_private_ip() {
    local ip="$1" o1 o2
    [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 1
    IFS='.' read -r o1 o2 _ <<< "$ip"
    [[ "$o1" -eq 10 ]] && return 0
    [[ "$o1" -eq 192 && "$o2" -eq 168 ]] && return 0
    [[ "$o1" -eq 172 && "$o2" -ge 16 && "$o2" -le 31 ]] && return 0
    return 1
}

# IPv4 분류 라벨 반환
# IP 주소를 Private/Public/Special/Unknown으로 분류
classify_ip() {
    local ip="$1" o1 o2
    [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "Unknown"; return 0; }
    IFS='.' read -r o1 o2 _ <<< "$ip"
    is_private_ip "$ip" && { echo "Private"; return 0; }
    [[ "$o1" -eq 127 || "$o1" -eq 0 || ( "$o1" -eq 169 && "$o2" -eq 254 ) || ( "$o1" -eq 100 && "$o2" -ge 64 && "$o2" -le 127 ) ]] && { echo "Special"; return 0; }
    echo "Public"
}

# 패키지 매니저 판별
# 시스템에서 사용 가능한 패키지 매니저를 탐지하여 반환
detect_pkg_manager() {
    for mgr in apt-get dnf yum zypper; do
        has_cmd "$mgr" && { echo "$mgr"; return 0; }
    done
}

# 상세 네트워크 도구 설치
# traceroute, ethtool 등 네트워크 분석 도구를 설치
install_tools() {
    local pkg_mgr="$(detect_pkg_manager)"
    [[ -z "$pkg_mgr" ]] && { echo -e "$TAG_FAIL No supported package manager found."; return 1; }

    echo -e "${CYAN}=== Install Optional Tools ===${NCOL}"
    case "$pkg_mgr" in
        apt-get) echo -e "$TAG_OK Using apt-get"
                 sudo apt-get update
                 sudo apt-get install -y traceroute iputils-ping ethtool
    ;;  dnf)     echo -e "$TAG_OK Using dnf"
                 sudo dnf install -y traceroute iputils ethtool
    ;;  yum)     echo -e "$TAG_OK Using yum"
                 sudo yum install -y traceroute iputils ethtool
    ;;  zypper)  echo -e "$TAG_OK Using zypper"
                 sudo zypper --non-interactive install traceroute iputils ethtool
    esac

    has_cmd traceroute && echo -e "$TAG_OK traceroute installed successfully." || echo -e "$TAG_WARN traceroute still not available."
    has_cmd ethtool && echo -e "$TAG_OK ethtool installed successfully." || echo -e "$TAG_WARN ethtool still not available."
}

# CPU idle 비율 계산
# top 명령으로 현재 CPU idle 백분율을 추출
get_idle_pct() {
    local idle_line idle_pct
    idle_line=$(top -bn1 | grep -E 'Cpu\(s\)|%Cpu' | head -1 || true)
    idle_pct=$(echo "$idle_line" | sed -n 's/.*, *\([0-9.][0-9.]*\)%* id.*/\1/p' | awk '{print int($1)}' || true)
    [[ -z "$idle_pct" ]] && idle_pct=0
    echo "$idle_pct"
}

# 스토리지 타입 판별
# lsblk rota 값으로 SSD/NVMe 또는 HDD 여부 확인
get_storage_type() {
    lsblk -d -o rota 2>/dev/null | awk 'NR > 1 { if ($1 == 0) ssd = 1 } END { print ssd ? "SSD/NVMe" : "HDD" }'
}

# byte 값을 사람이 읽기 쉬운 단위로 변환
# B, KiB, MiB, GiB, TiB, PiB 단위로 자동 변환하여 출력
to_human_size() {
    awk -v size="$1" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", unit, " ")
        idx = 1
        while (size >= 1024 && idx < 6) { size /= 1024; idx++ }
        if (idx == 1) printf "%d %s", size, unit[idx]
        else printf "%.1f %s", size, unit[idx]
    }'
}

# 블록 디바이스 타입 라벨 반환
# disk 이름과 rota 값으로 NVMe/SSD/HDD 타입 판별
get_disk_type_label() {
    local disk_name="$1" rota="$2"
    [[ "$disk_name" == nvme* ]] && { echo "NVMe"; return 0; }
    [[ "$rota" == "0" ]] && echo "SSD" || echo "HDD"
}

# 기본 라우트 인터페이스 반환
# default route에 설정된 네트워크 인터페이스명 추출
get_default_iface() { ip route 2>/dev/null | awk '/default/ {print $5; exit}'; }

# ethtool 기반 네트워크 속도 정보 반환 (human readable 포맷)
# 네트워크 인터페이스의 링크 속도를 Mb/s, Gb/s, Tb/s 단위로 반환
get_network_speed_info() {
    local net_if="$1" speed_raw speed_value speed_human
    [[ -z "$net_if" ]] && { echo "|unavailable|0"; return 0; }
    has_cmd ethtool || { echo "$net_if|unavailable|0"; return 0; }

    speed_raw=$(ethtool "$net_if" 2>/dev/null | awk -F': ' '/Speed:/ {print $2; exit}')
    [[ -z "$speed_raw" || "$speed_raw" == "Unknown!" ]] && { echo "$net_if|unavailable|0"; return 0; }
    speed_value=$(echo "$speed_raw" | grep -oE '[0-9]+' | head -1)
    [[ -z "$speed_value" ]] && speed_value=0

    if   (( speed_value >= 100000 )); then speed_human="$((speed_value / 1000))Tb/s"
    elif (( speed_value >= 1000 ));   then speed_human="$((speed_value / 1000))Gb/s"
    else speed_human="${speed_value}Mb/s"
    fi
    echo "$net_if|$speed_human|$speed_value"
}

# CPU 점수 계산
# 코어 수와 클럭 속도 기반으로 CPU 성능 점수 산출 (최대 200점)
calc_cpu_score() {
    local cpu_cores="$1" cpu_ghz="$2" raw_score
    raw_score=$(( cpu_cores * cpu_ghz ))
    (( raw_score > 200 )) && raw_score=200
    echo "$raw_score"
}

# RAM 점수 계산
# 코어당 RAM 용량 비율로 메모리 점수 산출 (50~160점)
calc_ram_score() {
    local ram_gb="$1" cpu_cores="$2" per_core=0
    (( cpu_cores > 0 )) && per_core=$(( ram_gb / cpu_cores ))

    if   (( per_core >= 8 )); then echo 160
    elif (( per_core >= 4 )); then echo 130
    elif (( per_core >= 2 )); then echo 90
    else echo 50
    fi
}

# DISK 점수 계산
# 디스크 타입(NVMe/SSD/HDD)과 개수로 스토리지 점수 산출 (최대 180점)
calc_disk_score() {
    local best_disk_type="$1" disk_count="$2" score=0
    case "$best_disk_type" in
        NVMe) score=140
    ;;  SSD)  score=110
    ;;  HDD)  score=50
    ;;  *)    score=20
    esac
    (( disk_count > 1 )) && score=$(( score + (disk_count - 1) * 10 ))
    (( score > 180 )) && score=180
    echo "$score"
}

# NETWORK 점수 계산
# 네트워크 속도와 패킷 손실률로 네트워크 점수 산출 (최대 180점)
calc_network_score() {
    local speed_mbps="$1" ping_loss_pct="$2" score=0

    if   (( speed_mbps >= 100000 )); then score=180
    elif (( speed_mbps >=  40000 )); then score=160
    elif (( speed_mbps >=  25000 )); then score=145
    elif (( speed_mbps >=  10000 )); then score=120
    elif (( speed_mbps >=   5000 )); then score=95
    elif (( speed_mbps >=   2500 )); then score=80
    elif (( speed_mbps >=   1000 )); then score=60
    elif (( speed_mbps >=    100 )); then score=30
    elif (( speed_mbps >       0 )); then score=10
    else score=0
    fi

    (( ping_loss_pct > 0 )) && score=$(( score - ping_loss_pct * 5 ))
    (( score < 0 )) && score=0
    echo "$score"
}

# 물리 디스크와 최대 파티션 요약 출력
# 각 디스크의 크기, 타입, 가장 큰 파티션 정보를 표시
show_storage_summary() {
    local disk_lines disk_count=0 disk_sort_input="" disk_partition_lines="" is_first_disk=1
    local six_tib_bytes=6597069766656

    disk_lines=$(lsblk -dnbr -o NAME,SIZE,ROTA,TYPE 2>/dev/null | awk '$4 == "disk" {print}')
    disk_count=$(echo "$disk_lines" | sed '/^$/d' | wc -l | xargs)
    printf "%-18s : %s (biggest partition info on each disk)\n" "Physical Disks" "$disk_count"

    [[ -z "$disk_lines" ]] && { echo "  - (None)"; return 0; }

    while IFS=' ' read -r disk_name disk_size disk_rota disk_type; do
        [[ -z "$disk_name" ]] && continue
        disk_sort_input+="$disk_size|$disk_name|$disk_rota|$disk_type"$'\n'
    done <<< "$disk_lines"

    disk_partition_lines=$(lsblk -pnbr -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,PKNAME 2>/dev/null | awk '$3 == "part" {
        name=$1; size=$2; mount=$4; fs=$5; parent=$6;
        if (mount == "") mount="-";
        if (fs == "") fs="-";
        print parent "|" name "|" size "|" mount "|" fs
    }')

    while IFS='|' read -r disk_size disk_name disk_rota disk_type; do
        local disk_size_h disk_kind part_name="" part_size=0 part_mount="-" part_fs="-" type_label show_red_size=0
        [[ -z "$disk_name" ]] && continue
        disk_size_h="$(to_human_size "$disk_size")"
        disk_kind="$(get_disk_type_label "$disk_name" "$disk_rota")"
        
        # 첫 번째 disk(가장 큰 disk)가 6 TiB 이하인지 체크
        if (( is_first_disk == 1 && disk_size <= six_tib_bytes )); then
            show_red_size=1
        fi
        is_first_disk=0
        
        while IFS='|' read -r parent_name candidate_part candidate_size candidate_mount candidate_fs; do
            [[ "$parent_name" == "/dev/$disk_name" ]] || continue
            (( candidate_size > part_size )) || continue
            part_name="$candidate_part"
            part_size="$candidate_size"
            part_mount="$candidate_mount"
            part_fs="$candidate_fs"
        done <<< "$disk_partition_lines"

        # 출력 포맷 결정 (HDD 및 6TiB 이하 디스크는 빨간색)
        local size_prefix="" size_suffix="" type_prefix="" type_suffix=""
        (( show_red_size == 1 )) && { size_prefix="${RED}"; size_suffix="${NCOL}"; }
        [[ "$disk_kind" == "HDD" ]] && { type_prefix="${RED}"; type_suffix="${NCOL}"; }

        if [[ -n "$part_name" ]]; then
            printf "  %-8s : ${size_prefix}%-9s${size_suffix} (${type_prefix}%-3s${type_suffix})  %s, %s, %-12s %s\n" "$disk_name" "$disk_size_h" "$disk_kind" "$part_name" "$part_fs" "$(to_human_size "$part_size")," "$part_mount"
        else
            printf "  %-8s : ${size_prefix}%-9s${size_suffix} (${type_prefix}%-3s${type_suffix})\n" "$disk_name" "$disk_size_h" "$disk_kind"
        fi
    done < <(printf "%s" "$disk_sort_input" | sed '/^$/d' | sort -t'|' -k1,1nr)
}

# CPU topology를 ASCII로 출력 (라벨 포함)
# Socket, Core, Thread 구조를 시각적으로 표현
print_socket_topology() {
    local sockets="$1" cores_per_socket="$2" threads_per_core="$3"
    local digits="${#cores_per_socket}" prefix cell_width socket core threads_indent

    prefix="$(repeat_char "|" $((threads_per_core > 0 ? threads_per_core : 1)))-"
    cell_width=$(( ${#prefix} + digits ))

    # Socket 번호 행 + (chips) 라벨
    for ((socket = 1; socket <= sockets; socket++)); do
        printf "#%-${cell_width}s" "$socket"
        (( socket < sockets )) && printf "   "
    done
    printf " (#chips)\n"

    # Core 출력
    for core in 1 2; do
        (( core > cores_per_socket )) && break
        for ((socket = 1; socket <= sockets; socket++)); do
            printf "%s%*d" "$prefix" "$digits" "$core"
            (( socket < sockets )) && printf "   "
        done
        printf "\n"
    done

    if (( cores_per_socket > 3 )); then
        for ((socket = 1; socket <= sockets; socket++)); do
            printf "%s%*s" "$prefix" "$digits" ".."
            (( socket < sockets )) && printf "   "
        done
        printf "\n"
    fi

    # 마지막 코어 + (cores) 라벨
    if (( cores_per_socket >= 3 )); then
        core="$cores_per_socket"
        for ((socket = 1; socket <= sockets; socket++)); do
            printf "%s%*d" "$prefix" "$digits" "$core"
            (( socket < sockets )) && printf "   "
        done
        printf "   (-cores)\n"
    fi

    # (threads) 라벨: 마지막 socket의 || 시작 위치와 align
    threads_indent=$(( (sockets - 1) * (cell_width) ))
    printf "%*s(|threads)\n" "$threads_indent" ""
}

# 네트워크 경로 및 경계선 표시
# traceroute로 목적지까지의 경로와 Private/Public 경계 표시
show_network_route() {
    local target_host="$1" target_ip ping_out ping_rtt ping_loss ping_loss_pct route_out hop_count=0 boundary_printed=0 prev_class="" last_hop_no=0
    local net_if speed_label speed_mbps private_hop_count=0
    local route_cmd=""

    echo -e "\n${GREEN}--- Network Path (${target_host}) ---${NCOL}"

    target_ip=$(getent ahostsv4 "$target_host" 2>/dev/null | awk 'NR == 1 {print $1}')
    [[ -z "$target_ip" ]] && { echo -e "$TAG_FAIL Failed to resolve $target_host"; return 1; }

    ping_out=$(ping -c "$PING_COUNT" -W 1 "$target_host" 2>/dev/null || true)
    ping_rtt=$(echo "$ping_out" | awk -F'=' '/^rtt / {gsub(/ /, "", $2); split($2, arr, "/"); print arr[2] " ms"}')
    ping_loss=$(echo "$ping_out" | awk -F', ' '/packets transmitted/ {print $3}')
    ping_loss_pct=$(echo "$ping_loss" | grep -oE '^[0-9]+' | head -1)
    [[ -z "$ping_rtt" ]] && ping_rtt="unavailable"
    [[ -z "$ping_loss" ]] && ping_loss="unavailable"
    [[ -z "$ping_loss_pct" ]] && ping_loss_pct=0

    net_if="$(get_default_iface)"
    IFS='|' read -r _ speed_label speed_mbps <<< "$(get_network_speed_info "$net_if")"
    [[ -z "$speed_label" ]] && speed_label="unavailable"
    [[ -z "$speed_mbps" ]] && speed_mbps=0

    printf "%-18s : %s (%s)\n" "Target" "$target_host" "$target_ip"
    printf "%-18s : %s (%s)\n" "Ping RTT(avg)" "$ping_rtt" "$ping_loss"
    if (( speed_mbps <= 1000 && speed_mbps > 0 )); then
        printf "%-18s : ${RED}%s${NCOL} (%s)\n" "Network Speed" "$speed_label" "${net_if:--}"
    else
        printf "%-18s : %s (%s)\n" "Network Speed" "$speed_label" "${net_if:--}"
    fi

    if   has_cmd traceroute; then route_cmd="traceroute -n -m ${TRACE_MAX_HOPS} -w 1 -q 1 ${target_ip}"
    elif has_cmd tracepath;  then route_cmd="tracepath -n -m ${TRACE_MAX_HOPS} ${target_ip}"
    else
        echo -e "$TAG_WARN traceroute/tracepath not found. Run '$0 install' for hop analysis."
        return 0
    fi

    route_out=$(eval "$route_cmd" 2>/dev/null || true)
    [[ -z "$route_out" ]] && { echo -e "$TAG_WARN Route analysis failed."; return 0; }

    while IFS= read -r line; do
        local hop_no hop_ip hop_class

        hop_no=$(echo "$line" | awk '{gsub(/[:?]/, "", $1); if ($1 ~ /^[0-9]+$/) print $1}')
        [[ ! "$hop_no" =~ ^[0-9]+$ ]] && continue
        [[ "$hop_no" -eq "$last_hop_no" ]] && continue

        if [[ "$line" == *"no reply"* || "$line" == *"*"* ]]; then
            printf "  %2s. [Unknown] *\n" "$hop_no"
            last_hop_no="$hop_no"
            continue
        fi

        hop_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
        [[ -z "$hop_ip" ]] && continue

        hop_class="$(classify_ip "$hop_ip")"
        
        # Private hop 카운트
        [[ "$hop_class" == "Private" ]] && private_hop_count=$((private_hop_count + 1))
        
        if [[ "$prev_class" == "Private" && "$hop_class" == "Public" && "$boundary_printed" -eq 0 ]]; then
            if (( private_hop_count >= 10 )); then
                echo -e "  ${RED}---- Private/Public Boundary ----${NCOL}"
            else
                echo "  ---- Private/Public Boundary ----"
            fi
            boundary_printed=1
        fi

        printf "  %2s. [%-7s] %s\n" "$hop_no" "$hop_class" "$hop_ip"
        prev_class="$hop_class"
        hop_count="$hop_no"
        last_hop_no="$hop_no"
    done <<< "$route_out"

    [[ "$hop_count" -gt 0 ]] && printf "%-18s : %s\n" "Hop Count" "$hop_count" || printf "%-18s : %s\n" "Hop Count" "unavailable"
}

# 전체 빌드 점수 출력
# CPU, RAM, DISK, NETWORK 점수를 합산하여 종합 점수 표시
show_total_score() {
    local cpu_score="$1" ram_score="$2" disk_score="$3" network_score="$4"
    local total_score=$(( cpu_score + ram_score + disk_score + network_score ))

    echo -e "\n${GREEN}--- Total Build Score ---${NCOL}"
    printf "%-18s : %s\n" "Score CPU" "$cpu_score"
    printf "%-18s : %s\n" "Score RAM" "$ram_score"
    printf "%-18s : %s\n" "Score DISK" "$disk_score"
    printf "%-18s : %s\n" "Score NETWORK" "$network_score"
    printf "%-18s : %s\n" "Total Build Score" "$total_score"
}

# 원격 서버에서 스크립트 실행
# SSH를 통해 원격 서버에서 동일한 스크립트 실행
run_remote_script() {
    local target_ip="$1" action="$2"
    echo -e "${CYAN}=== Remote Execution (${target_ip}) ===${NCOL}"
    ssh "${SSH_OPTS[@]}" "$target_ip" "bash -s -- --remote-exec ${action} ${target_ip}" < "$0"
}

# 서버 기본 사양 출력
# CPU, RAM, DISK, 네트워크 정보 및 성능 점수를 종합 표시
show_server_spec() {
    local host_name cpu_cores cpu_mhz_raw cpu_mhz cpu_ghz cpu_model sockets cores_per_socket threads_per_core target_ip="${1:-}"
    local ram_kb ram_gb avail_ram_kb avail_ram_gb idle_pct idle_cores
    local l1d l1i l2 l3 numa_nodes
    local cpu_score ram_score disk_score network_score disk_count=0 largest_disk_type="Unknown"
    local default_if speed_label speed_mbps ping_probe ping_loss_pct=0

    host_name="$(hostname)"
    cpu_cores="$(nproc 2>/dev/null || echo 1)"
    cpu_mhz_raw="$(get_first_lscpu_field 'CPU max MHz' 'CPU MHz')"
    cpu_mhz="$(echo "${cpu_mhz_raw:-1000}" | awk -F. '{print ($1 > 0 ? $1 : 1000)}')"
    cpu_ghz=$(( cpu_mhz / 1000 ))
    [[ "$cpu_ghz" -eq 0 ]] && cpu_ghz=1
    cpu_model="$(get_lscpu_field 'Model name')"
    sockets="$(get_lscpu_field 'Socket(s)')"
    cores_per_socket="$(get_lscpu_field 'Core(s) per socket')"
    threads_per_core="$(get_lscpu_field 'Thread(s) per core')"
    l1d="$(get_lscpu_field 'L1d cache')"
    l1i="$(get_lscpu_field 'L1i cache')"
    l2="$(get_lscpu_field 'L2 cache')"
    l3="$(get_lscpu_field 'L3 cache')"
    numa_nodes="$(get_lscpu_field 'NUMA node(s)')"
    [[ -z "$cpu_model" ]] && cpu_model="Unknown"
    [[ -z "$sockets" ]] && sockets=1
    [[ -z "$cores_per_socket" ]] && cores_per_socket="$cpu_cores"
    [[ -z "$threads_per_core" ]] && threads_per_core=1
    [[ -z "$numa_nodes" ]] && numa_nodes=1

    ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    avail_ram_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    ram_gb=$(( ram_kb / 1024 / 1024 ))
    avail_ram_gb=$(( avail_ram_kb / 1024 / 1024 ))

    idle_pct="$(get_idle_pct)"
    idle_cores=$(awk -v cores="$cpu_cores" -v idle="$idle_pct" 'BEGIN {printf "%.1f", cores * idle / 100}')

    disk_count=$(lsblk -dnbr -o NAME,SIZE,ROTA,TYPE 2>/dev/null | awk '$4 == "disk" {count++} END {print count + 0}')
    largest_disk_type=$(lsblk -dnbr -o NAME,SIZE,ROTA,TYPE 2>/dev/null | awk '$4 == "disk" {print $2 "|" $1 "|" $3}' | sort -t'|' -k1,1nr | head -1 | awk -F'|' '{if ($2 ~ /^nvme/) print "NVMe"; else if ($3 == 0) print "SSD"; else print "HDD"}')
    [[ -z "$largest_disk_type" ]] && largest_disk_type="Unknown"

    default_if="$(get_default_iface)"
    IFS='|' read -r _ speed_label speed_mbps <<< "$(get_network_speed_info "$default_if")"
    ping_probe=$(ping -c "$PING_COUNT" -W 1 "$TARGET_HOST" 2>/dev/null | awk -F', ' '/packets transmitted/ {print $3}')
    ping_loss_pct=$(echo "$ping_probe" | grep -oE '^[0-9]+' | head -1)
    [[ -z "$ping_loss_pct" ]] && ping_loss_pct=0

    cpu_score="$(calc_cpu_score "$cpu_cores" "$cpu_ghz")"
    ram_score="$(calc_ram_score "$ram_gb" "$cpu_cores")"
    disk_score="$(calc_disk_score "$largest_disk_type" "$disk_count")"
    network_score="$(calc_network_score "${speed_mbps:-0}" "$ping_loss_pct")"

    if [[ -n "$target_ip" ]]; then echo -e "${CYAN}=== Server Specification & Score (Remote Server: ${target_ip} / ${host_name}) ===${NCOL}"
    else echo -e "${CYAN}=== Server Specification & Score (Local Server: ${host_name}) ===${NCOL}"
    fi
    echo -e "\n${GREEN}--- CPU Info ---${NCOL}"
    print_socket_topology "$sockets" "$cores_per_socket" "$threads_per_core"
    printf "\nCPU Topology       : %s\n" "${sockets}S x ${cores_per_socket}C x ${threads_per_core}T = ${cpu_cores} CPUs"

    printf "%-18s : %s\n" "CPU Model" "$(trim "$cpu_model")"
    printf "%-18s : ~%s GHz\n" "CPU Clock" "$cpu_ghz"
    printf "%-18s : %6s / %s\n" "Idle CPU Cores" "$idle_cores" "$cpu_cores"
    printf "%-18s : %s\n" "CPU Cache L1d" "$(trim "$l1d")"
    printf "%-18s : %s\n" "CPU Cache L1i" "$(trim "$l1i")"
    printf "%-18s : %s\n" "CPU Cache L2"  "$(trim "$l2")"
    printf "%-18s : %s\n" "CPU Cache L3"  "$(trim "$l3")"
    printf "%-18s : %s\n" "NUMA Nodes" "$(trim "$numa_nodes")"

    echo -e "\n${GREEN}--- RAM & DISK ---${NCOL}"
    if (( ram_gb <= 256 )); then
        printf "%-18s : ${RED}%6s / %s${NCOL}\n" "Available RAM" "${avail_ram_gb}GB" "${ram_gb}GB"
    else
        printf "%-18s : %6s / %s\n" "Available RAM" "${avail_ram_gb}GB" "${ram_gb}GB"
    fi
    show_storage_summary

    show_network_route "$TARGET_HOST"
    show_total_score "$cpu_score" "$ram_score" "$disk_score" "$network_score"
}

# 메인 진입점
# 명령행 인자를 파싱하고 적절한 동작(status/install)을 실행
main() {
    local action="status" target_ip="" remote_mode=0

    if [[ "${1:-}" == "--remote-exec" ]]; then
        remote_mode=1
        action="${2:-status}"
        target_ip="${3:-}"
        shift 3 || true
    fi

    if (( remote_mode == 0 )); then
        case "${1:-}" in
            -h|--help|help) usage; return 0
        ;;  install)        action="install"
        ;;  "")             action="status"
        ;;  *)              if is_ipv4_address "$1"; then
                                target_ip="$1"
                                [[ "${2:-}" == "install" ]] && action="install" || action="status"
                            else
                                echo -e "$TAG_FAIL Unknown argument: $1"
                                usage
                                return 1
                            fi
        esac
    fi

    if (( remote_mode == 0 )) && [[ -n "$target_ip" ]]; then
        if is_local_target_ip "$target_ip"; then
            target_ip=""
        else
            run_remote_script "$target_ip" "$action"
            return $?
        fi
    fi

    case "$action" in
        status)  show_server_spec "$target_ip"
    ;;  install) install_tools
    ;;  *)       echo -e "$TAG_FAIL Unknown argument: $action"; usage; return 1
    esac
}

main "$@"