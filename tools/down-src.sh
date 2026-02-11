#!/bin/bash
# filepath: /data001/vc.integrator/.proFILEs/tools/down_src.sh

# 색상 코드 (가독성용)
declare -A JOB_COLORS
JOB_COLORS[0]='\033[1;36m'  # 빨간색 (END용)
JOB_COLORS[1]='\033[0;32m'  # 녹색
JOB_COLORS[2]='\033[0;34m'  # 파랑
JOB_COLORS[3]='\033[0;33m'  # 노랑
JOB_COLORS[4]='\033[0;35m'  # 마젠타
NC='\033[0m' # No Color

# ==============================================================================
# 설정 및 초기화
# ==============================================================================
INPUT_FILE="$1"
MIRROR_PATH="$2"
MAX_JOBS=3
LOG_DIR="log"

# MIRROR_PATH를 절대 경로로 변환
if [ -n "$MIRROR_PATH" ]; then
    MIRROR_PATH=$(readlink -f "$MIRROR_PATH")
    mkdir -p "$MIRROR_PATH"
fi

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
    * 기존 다운로드 결과를 재사용하지 않으려면, 먼저 rm -rf down.* 로 지워야함.
    * mirror_path를 지정하면 지정한 dir에 bare repository mirror를 생성하고 이를 참조하여 다운로드한다.
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
JOBDIR_PREFIX="down"
active_jobs=0
has_error=0  # error 발생 여부 추적
declare -A job_logs  # PID와 로그 파일을 매핑할 연관 배열
declare -A job_pids  # PID와 job_id를 매핑할 연관 배열
START_DIR="$(pwd)"  # 시작 디렉토리 저장

for idx in "${!command_blocks[@]}"; do
    JOB_ID=$((idx + 1))
    cmd_block="${command_blocks[$idx]}"

    # 명령어 타입 결정 (디렉토리 이름 결정을 위해 먼저 수행)
    cmd_type=""
    if [[ "$cmd_block" =~ git[[:space:]]+clone ]]; then cmd_type="git_clone"; JOBDIR_PREFIX="down.git"
    elif [[ "$cmd_block" =~ repo[[:space:]]+init ]]; then cmd_type="repo_init"; JOBDIR_PREFIX="down.repo"
    else cmd_type="other"; JOBDIR_PREFIX="down.xxx"
    fi

    JOB_DIR="${JOBDIR_PREFIX}.${JOB_ID}"
    LOG_FILE="$(pwd)/${LOG_DIR}/downcmd_${JOB_ID}.log"
    # JOB_COLOR="${JOB_COLORS[$JOB_ID]:-\033[0m}"
    # Color rotation (1~4)
    color_idx=$(( (JOB_ID - 1) % 4 + 1 ))

    case $color_idx in
        1) JOB_COLOR='\033[0;32m' ;;
        2) JOB_COLOR='\033[0;34m' ;;
        3) JOB_COLOR='\033[0;33m' ;;
        4) JOB_COLOR='\033[0;35m' ;;
        *) JOB_COLOR='\033[0m' ;;
    esac

    # 작업 디렉토리 생성/이동
    mkdir -p "$JOB_DIR" && pushd "$JOB_DIR" > /dev/null

    # 원래 명령 출력
    echo -e "${JOB_COLOR}[${JOB_ID}.CMD-ORI] ${cmd_block// && / && \\n}${NC}" | sed 's/ ; / ;\n/g'
    actual_cmd="$cmd_block"

    # MIRROR_PATH 및 명령어 타입에 따른 처리
    case "${MIRROR_PATH:+mirror}~${cmd_type}" in
        # MIRROR_PATH가 없고 git clone 명령인 경우 - 재실행시 git pull로 처리
        ~git_clone)
            clone_dir=$(find . -maxdepth 2 -type d -name .git -exec dirname {} \; 2>/dev/null | head -1)
            [ -n "$clone_dir" ] && cd "$clone_dir" && actual_cmd="git pull"

        # MIRROR_PATH가 설정되고 git clone 명령인 경우
        ;; mirror~git_clone)
            mirror_git_dir="$MIRROR_PATH/down.git.${JOB_ID}"

            # 이미 clone된 디렉토리가 있는지 확인
            clone_dir=$(find . -maxdepth 2 -type d -name .git -exec dirname {} \; 2>/dev/null | head -1)

            if [ -n "$clone_dir" ]; then
                # 이미 clone되어 있으면 git pull로 업데이트
                echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Repository already exists. Updating with git pull${NC}"
                actual_cmd="cd \"$clone_dir\" && git pull"
            else
                # clone이 안되어 있으면 mirror 사용
                git_clone_with_ref="${actual_cmd/git clone /git clone --reference \"$mirror_git_dir\" }"

                # 미러 생성 또는 업데이트를 actual_cmd에 포함
                if [ ! -d "$mirror_git_dir/refs" ]; then
                    # 미러 미존재시 git clone --mirror로 실행
                    echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Creating mirror at $mirror_git_dir${NC}"
                    rm -rf "$mirror_git_dir" 2>/dev/null || true
                    mirror_cmd="${actual_cmd/git clone /git clone --mirror }"
                    actual_cmd="$mirror_cmd \"$mirror_git_dir\" && $git_clone_with_ref"
                else
                    # 미러 존재시, git remote update로 실행 후 --reference 옵션 추가
                    echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Updating mirror at $mirror_git_dir${NC}"
                    actual_cmd="(cd \"$mirror_git_dir\" && git remote update) || true && $git_clone_with_ref"
                fi
            fi


        # MIRROR_PATH가 설정되고 repo init 명령인 경우
        ;; mirror~repo_init)
            repo_mirror_base="$MIRROR_PATH/down.repo.${JOB_ID}"

            # Mirror 디렉토리 초기화/업데이트
            if [ ! -d "$repo_mirror_base/.repo" ]; then #미러 미존재시
                echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Creating repo mirror at $repo_mirror_base/${NC}"
                mkdir -p "$repo_mirror_base"
                # repo init --mirror로 실행
                mirror_init_cmd="${actual_cmd//repo init /repo init --mirror }"
                # --depth 옵션 제거 (sed delimiter |)
                mirror_init_cmd="$(echo "$mirror_init_cmd" | sed -E '0,/repo init/s|(^|[[:space:]])--depth(=[0-9]+|[[:space:]]+[0-9]+)([[:space:]]|$)| |g' | sed -E 's|  +| |g')"
                # mirror에서 repo sync까지 실행 (첫 번째 repo sync까지만)
                mirror_sync_cmd="$(echo "$mirror_init_cmd" | sed -n '1{s|\(.*repo sync[^;]*\).*|\1|p}')"
                # mirror_sync_cmd가 공백일 경우 (repo sync가 없는 경우), repo init --mirror 후 repo sync -cj8 실행
                if [ -z "$mirror_sync_cmd" ]; then
                    mirror_sync_cmd="${mirror_init_cmd} && repo sync -cj8"
                fi
                actual_cmd="(cd \"$repo_mirror_base\" && $mirror_sync_cmd) && $actual_cmd"
            fi

            # 미러존재시만 --reference 옵션 추가 (작업 디렉토리의 첫 번째 repo init에만)
            if [[ -d "$repo_mirror_base/.repo" && ! "$actual_cmd" =~ --reference ]]; then
                # 첫 번째 repo init에만 --reference 추가 (경로 내 / 충돌 방지를 위해 구분자 | 사용)
                actual_cmd="$(echo "$actual_cmd" | sed '0,/repo init /s|repo init |repo init --reference='"$repo_mirror_base"' |')"
            fi
    esac

    # --depth 옵션이 있는 경우는 무조건 제거
    if [[ "$actual_cmd" =~ --depth(=|[[:space:]]+)[0-9]+ ]]; then
        # git clone 또는 repo init 명령인 경우만 처리
        if [[ "$actual_cmd" =~ (git[[:space:]]+clone|repo[[:space:]]+init) ]]; then
            actual_cmd="$(echo "$actual_cmd" | sed -E 's/(^|[[:space:]])--depth(=[0-9]+|[[:space:]]+[0-9]+)([[:space:]]|$)/ /g' | sed -E 's/  +/ /g')"
        fi
    fi

    # repo init 명령의 -m manifest 파일에서 clone-depth 제거 (repo init 실행 후)
    if [[ "$actual_cmd" =~ repo[[:space:]]+init.*-m[[:space:]]+([^[:space:]]+) ]]; then
        manifest_file="${BASH_REMATCH[1]}"

        # heredoc으로 manifest 수정 스크립트 생성
        cat > fix_manifest.sh << 'MANIFEST_FIX_EOF' && chmod +x fix_manifest.sh
#!/bin/bash
manifest_file="$1"
if [ -f ".repo/manifests/${manifest_file}" ] && grep -q 'clone-depth' ".repo/manifests/${manifest_file}"; then
    cp ".repo/manifests/${manifest_file}" ".repo/manifests/${manifest_file}.ori"
    sed -i -E 's/[[:space:]]*clone-depth="[0-9]+"//g' ".repo/manifests/${manifest_file}"
    echo "Removed clone-depth from ${manifest_file}"
fi
MANIFEST_FIX_EOF

        # repo init과 repo sync 사이에 fix_manifest.sh 삽입
        # "repo init ... ; repo sync ..." → "repo init ... ; ./fix_manifest.sh ... && repo sync ..."
        # START_DIR 기준 절대 경로
        fix_script_path="${START_DIR}/${JOB_DIR}/fix_manifest.sh"
        actual_cmd=$(echo "$actual_cmd" | sed "s|repo sync|${fix_script_path} '${manifest_file}' ; repo sync|g")
    fi


    ##최종 실행되는 실제 command를 출력한다.
    echo -e "${JOB_COLOR}[${JOB_ID}.CMD-FINAL] ${actual_cmd//;/;\\n}${NC}"
    bash -ec "$actual_cmd" &> "$LOG_FILE" &
    popd > /dev/null

    # PID 저장 및 카운트 증가
    pid=$!
    job_logs[$pid]="$LOG_FILE"
    job_pids[$pid]=$JOB_ID
    sleep 2
    # 프로세스가 아직 실행 중인 경우에만 출력
    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${JOB_COLOR}[${JOB_ID}.RUNNING]: ${JOB_ID} in ${JOB_DIR}/ (PID: $pid, Log: ${LOG_DIR}/downcmd_${JOB_ID}.log)${NC}"
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
        if [ $exit_code -ne 0 ]; then has_error=1; fi

        # 종료된 작업 찾기 (실행 중이지 않은 PID 찾기)
        for p in "${!job_logs[@]}"; do
            if ! kill -0 "$p" 2>/dev/null; then
                job_id_end=${job_pids[$p]}
                JOB_COLOR_end="${JOB_COLORS[0]}"
                echo -e "${JOB_COLOR_end}[${job_id_end}.END] Check log: ${LOG_DIR}/downcmd_${job_id_end}.log${NC}"
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
    if [ $exit_code -ne 0 ]; then has_error=1; fi

    job_id_final=${job_pids[$pid]}
    JOB_COLOR_final="${JOB_COLORS[0]}"
    echo -e "${JOB_COLOR_final}[${job_id_final}.END] Check log: ${LOG_DIR}/downcmd_${job_id_final}.log${NC}"
done

# error 발생 여부에 따라 메시지 출력
if [ $has_error -eq 1 ];
then echo -e "${JOB_COLORS[0]}[${JOB_ID}.ERROR] Some jobs failed. Check logs for details.${NC}" ; exit 1;
else echo -e "${JOB_COLORS[4]}[${JOB_ID}.FINISH] All download jobs completed.${NC}"; exit 0;
fi