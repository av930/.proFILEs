#!/bin/bash
# filepath: /data001/vc.integrator/.proFILEs/tools/down_src.sh

# ==============================================================================
# 설정 및 초기화
# ==============================================================================
INPUT_FILE="$1"
MIRROR_PATH="$2"
MAX_JOBS=3
LOG_DIR="log"
JOB_DIR="result."
MIRROR_DIR="$MIRROR_PATH"
[ -n "$MIRROR_PATH" ] && [ ! -e "$MIRROR_DIR" ] && mkdir -p "$MIRROR_DIR"


# 색상 코드 (가독성용)
declare -A JOB_COLORS
JOB_COLORS[0]='\033[0;31m'  # 빨간색 (END용)
JOB_COLORS[1]='\033[0;32m'  # 녹색
JOB_COLORS[2]='\033[0;34m'  # 파랑
JOB_COLORS[3]='\033[0;33m'  # 노랑
JOB_COLORS[4]='\033[0;35m'  # 마젠타
NC='\033[0m' # No Color

# ==============================================================================
# 유효성 검사
# ==============================================================================
if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
    echo "  Usage: $0 <input_file> [mirror_path]"

	cat << EOF
	ex) down_src.sh down.list .mirror
	ex) down_src.sh down.list /path/to/mirror
	1. down.list에는 빈줄로 구분된 download 명령을 기록한다.
	2. download 명령은 여러줄도 가능하지만 동시 실행은 최대 3개까지 가능하다.
    3. 실행후 [RUNNING] 상태에 있으면 정상동작이다.
    4. 모든 다운로드가 완료되면 [FINISH]가 출력되고 그렇지 않으면 [ERROR]가 출력된다.
    * 기존 다운로드 결과를 재사용하지 않으려면, 먼저 rm -rf result.* 로 지워야함.
    * mirror_path를 지정하면 해당 경로에 bare repository mirror를 생성하고 이를 참조하여 다운로드한다.
    * mirror_path를 생략하면 mirror를 사용하지 않고 직접 다운로드한다.
EOF
    exit 1
fi

# ==============================================================================
# 기존 프로세스 정리
# ==============================================================================
# 현재 디렉토리에서 실행 중인 기존 down_src.sh 프로세스와 자식 프로세스들을 종료
SCRIPT_NAME=$(basename "$0")
CURRENT_DIR=$(pwd)
CURRENT_PID=$$

# 현재 실행 중인 down_src.sh 프로세스 찾기 (자기 자신 제외)
OLD_PIDS=$(ps aux | grep "[d]own_src.sh" | grep -v "grep" | awk '{print $2}' | grep -v "^${CURRENT_PID}$")

if [ -n "$OLD_PIDS" ]; then
    echo "Killing existing down_src.sh processes..."
    for pid in $OLD_PIDS; do
        # 프로세스 그룹 전체 종료 (자식 프로세스들도 함께)
        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    done
    sleep 1
    echo "Cleanup completed."
fi

#rm -rf ./${JOB_DIR}*|| true
mkdir -p "$LOG_DIR"
echo "Logs will be saved to: ${LOG_DIR}"

# ==============================================================================
# 입력 파일 파싱 (빈 줄을 기준으로 블록 분리)
# ==============================================================================
# 전처리:
#   1. 공백만 포함된 줄을 완전한 빈 줄로 변환 (sed 's/^[[:space:]]*$//')
#   2. 연속된 빈 줄(2개 이상)을 하나의 구분자로 처리
#   - awk에서 빈 줄이 2개 이상 연속되면 블록 구분, 1개 빈줄은 무시
#   - 이렇게 하면 repo init과 repo sync가 별도 줄에 있어도 같은 블록으로 인식
# BEGIN{RS=""; FS="\n"}: paragraph mode로 하나 이상의 빈 줄을 구분자로
# gsub는 블록 앞뒤 공백을 제거합니다.
mapfile -t command_blocks < <(sed 's/^[[:space:]]*$//' "$INPUT_FILE" | awk 'BEGIN{RS=""; FS="\n"} NF{gsub(/^[[:space:]]+|[[:space:]]+$/,""); gsub(/\n+/," ; "); print}')

echo "Total blocks found: ${#command_blocks[@]}"

# ==============================================================================
# 병렬 실행 루프
# ==============================================================================
active_jobs=0
has_error=0  # error 발생 여부 추적
declare -A job_logs  # PID와 로그 파일을 매핑할 연관 배열
declare -A job_pids  # PID와 job_id를 매핑할 연관 배열

for idx in "${!command_blocks[@]}"; do
    job_id=$((idx + 1))
    job_dir="${JOB_DIR}${job_id}"
    cmd_block="${command_blocks[$idx]}"
    log_file="$(pwd)/${LOG_DIR}/downcmd_${job_id}.log"
    job_color="${JOB_COLORS[$job_id]:-\033[0m}"

    # 작업 디렉토리 생성
    mkdir -p "$job_dir"


    # 작업 디렉토리로 이동
    pushd "$job_dir" > /dev/null

    # git clone 재실행 처리: 기존 경로 존재시 git pull, 아니면 git clone
    echo -e "${job_color}[START:${job_id}] $cmd_block${NC}"
    actual_cmd="$cmd_block"

    # Mirror 모드에서 git clone 처리
    if [[ "$cmd_block" =~ git[[:space:]]+clone ]] && [ -n "$MIRROR_PATH" ]; then
        # 기존 clone된 디렉토리가 있으면 git pull
        clone_dir=$(find . -maxdepth 2 -type d -name .git -exec dirname {} \; 2>/dev/null | head -1)
        if [ -n "$clone_dir" ]; then
            cd "$clone_dir" && actual_cmd="git pull"
        else
            # git clone 명령에서 URL 추출
            if [[ "$cmd_block" =~ git[[:space:]]+clone[[:space:]]+([^[:space:]]+) ]]; then
                repo_url="${BASH_REMATCH[1]}"
                # URL에서 repository 이름 추출
                repo_name=$(basename "$repo_url" .git)
                mirror_path="$MIRROR_DIR/${repo_name}.git"

                # Mirror가 없으면 mirror 생성 후 실제 clone 실행
                if [ ! -d "$mirror_path" ]; then
                    echo -e "${job_color}[MIRROR] Creating mirror at $mirror_path${NC}"
                    # mirror 생성 후 그 mirror를 사용하여 실제 clone
                    clone_cmd="$(echo "$cmd_block" | sed -E "s|git[[:space:]]+clone[[:space:]]+([^[:space:]]+)|git clone --reference $mirror_path \1|")"
                    actual_cmd="git clone --mirror \"$repo_url\" \"$mirror_path\" && $clone_cmd"
                else
                    # Mirror가 있으면 --reference를 사용하여 clone
                    echo -e "${job_color}[MIRROR] Using existing mirror: $mirror_path${NC}"
                    actual_cmd="$(echo "$cmd_block" | sed -E "s|git[[:space:]]+clone[[:space:]]+([^[:space:]]+)|git clone --reference $mirror_path \1|")"
                fi
            fi
        fi
    elif [[ "$cmd_block" =~ git[[:space:]]+clone ]]; then
        # Mirror 모드가 아닐 때의 기존 로직
        clone_dir=$(find . -maxdepth 2 -type d -name .git -exec dirname {} \; 2>/dev/null | head -1)
        [ -n "$clone_dir" ] && cd "$clone_dir" && actual_cmd="git pull"
    fi

    # git clone 또는 repo init 명령에서 --depth=NUM 옵션 제거
    if [[ "$actual_cmd" =~ (git[[:space:]]+clone|repo[[:space:]]+init) ]]; then
        if [[ "$actual_cmd" =~ --depth(=|[[:space:]]+)[0-9]+ ]]; then
            actual_cmd="$(echo "$actual_cmd" | sed -E 's/(^|[[:space:]])--depth(=[0-9]+|[[:space:]]+[0-9]+)([[:space:]]|$)/ /g' | sed -E 's/  +/ /g')"
        fi
    fi

    # repo init 명령의 -m manifest 파일에서 clone-depth 제거
    if [[ "$actual_cmd" =~ repo[[:space:]]+init ]]; then
        # Mirror 모드에서 --reference-dir 추가
        if [ -n "$MIRROR_PATH" ]; then
            repo_mirror_dir="$MIRROR_DIR/repo_mirror"
            mkdir -p "$repo_mirror_dir"
            # --reference-dir 옵션이 없으면 추가
            if [[ ! "$actual_cmd" =~ --reference-dir ]]; then
                actual_cmd="$actual_cmd --reference-dir=$repo_mirror_dir"
                echo -e "${job_color}[MIRROR] Using repo mirror: $repo_mirror_dir${NC}"
            fi
        fi

        if [[ "$actual_cmd" =~ -m[[:space:]]+([^[:space:]]+) ]]; then
            manifest_file="${BASH_REMATCH[1]}"
            if [ -f "$manifest_file" ]; then
                # 백업 생성
                cp "$manifest_file" "${manifest_file}.ori"
                # clone-depth="숫자" 패턴 제거
                sed -i -E 's/[[:space:]]*clone-depth="[0-9]+"//g' "$manifest_file"
                echo -e "${job_color}[REPO-INIT] Removed clone-depth from $manifest_file (backup: ${manifest_file}.ori)${NC}"
            fi
        fi
    fi


    ##최종 실행되는 실제 command를 출력한다.
    echo -e "${job_color}[FINAL_CMD] $actual_cmd"
    bash -ec "$actual_cmd" &> "$log_file" &
    popd > /dev/null

    # PID 저장 및 카운트 증가
    pid=$!
    job_logs[$pid]="$log_file"
    job_pids[$pid]=$job_id
    sleep 2
    # 프로세스가 아직 실행 중인 경우에만 출력
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${job_color}[RUNNING]: ${job_id} in ${job_dir}/ (PID: $pid, Log: ${LOG_DIR}/downcmd_${job_id}.log)${NC}"
    fi
    ((active_jobs++))

    # ------------------------------------------------------
    # 동시 실행 제어 (Throttling)
    # ------------------------------------------------------
    # 실행 중인 작업이 MAX_JOBS 갯수에 도달하면 하나가 끝날 때까지 대기
    if (( active_jobs >= MAX_JOBS )); then
        wait -n
        exit_code=$?

        # exit code가 0이 아니면 error 발생
        if [ $exit_code -ne 0 ]; then
            has_error=1
        fi

        # 종료된 작업 찾기 (실행 중이지 않은 PID 찾기)
        for p in "${!job_logs[@]}"; do
            if ! kill -0 "$p" 2>/dev/null; then
                job_id_end=${job_pids[$p]}
                job_color_end="${JOB_COLORS[0]}"
                echo -e "${job_color_end}[END:${job_id_end}] Check log: ${LOG_DIR}/downcmd_${job_id_end}.log${NC}"
                unset "job_logs[$p]"
                unset "job_pids[$p]"
                break
            fi
        done

        ((active_jobs--)) # 하나가 끝났으므로 카운트 감소 (논리적 처리)
    fi
done

# ==============================================================================
# 종료 대기
# ==============================================================================
# 모든 작업이 끝날때까지 대기하고 exit code 확인
for pid in "${!job_logs[@]}"; do
    wait "$pid"
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        has_error=1
    fi

    job_id_final=${job_pids[$pid]}
    job_color_final="${JOB_COLORS[0]}"
    echo -e "${job_color_final}[END:${job_id_final}] Check log: ${LOG_DIR}/downcmd_${job_id_final}.log${NC}"
done

# error 발생 여부에 따라 메시지 출력
if [ $has_error -eq 1 ]; then
    echo -e "${JOB_COLORS[0]}[ERROR] Some jobs failed. Check logs for details.${NC}"
else
    echo -e "${JOB_COLORS[4]}[FINISH] All download jobs completed.${NC}"
fi