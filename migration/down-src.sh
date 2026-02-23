#!/bin/bash
## ======================================================================
## down-src.sh - 병렬 소스 다운로드 관리 스크립트
## ======================================================================
## 목적:
##   - git clone/repo init 명령을 병렬로 실행 (최대 3개 동시 실행)
##   - Mirror를 활용한 빠른 재다운로드 지원
##   - 재실행시 자동으로 git pull 전환
##   - Shallow clone 방지 (--depth 제거)
##   - Manifest clone-depth 속성 제거
##
## 사용법:
##   down-src.sh <input_file> [mirror_path]
##
## 입력 파일 형식:
##   - 빈 줄로 구분된 명령 블록
##   - repo init과 repo sync는 한 블록으로 인식
##
## 실행 흐름:
##   1. 명령어 타입 분석 (git clone / repo init)
##   2. 재실행 감지 및 git pull 전환
##   3. Mirror 활용 (있는 경우)
##   4. --depth 옵션 제거
##   5. Manifest clone-depth 제거
##   6. 병렬 실행 및 Throttling
##   7. 결과 집계 및 실패 로그 출력
## ======================================================================

## 색상 정의 (작업별 구분용)
declare -A JOB_COLORS
# 청록                       # 녹색                      # 파랑                      # 노랑                        # 마젠타                     #초기화
JOB_COLORS[0]='\033[1;36m'; JOB_COLORS[1]='\033[0;32m'; JOB_COLORS[2]='\033[0;34m'; JOB_COLORS[3]='\033[0;33m'; JOB_COLORS[4]='\033[0;35m' ; NC='\033[0m'

## ======================================================================
## 설정 및 초기화
## ======================================================================
INPUT_FILE="$1"
MIRROR_PATH="$2"
MAX_JOBS=3
LOG_DIR="log"

## Mirror 경로 절대 경로 변환
if [ -n "$MIRROR_PATH" ]; then { MIRROR_PATH=$(readlink -f "$MIRROR_PATH"); mkdir -p "$MIRROR_PATH"; }; fi

## ======================================================================
## 유효성 검사
## ======================================================================
if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
    echo "  Usage: $0 <input_file> [mirror_path]"

	cat << EOF
	ex) down_src.sh down.list .mirror
        git clone -b tsu_26my_cpl2_migration_260211 ssh://vc.integrator@vgit.lge.com:29448/honda/linux/build_tsu

        repo init -u ssh://vc.integrator@vgit.lge.com:29448/manifest_honda_tsu -b tsu_26my_cpl2_migration_260211 -m default.xml
        repo sync -j4

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

## ======================================================================
## 기존 프로세스 정리
## ======================================================================
## 현재 디렉토리에서 실행 중인 기존 down_src.sh 및 자식 프로세스 종료
CURRENT_PID=$$

OLD_PIDS=$(ps aux | grep "[d]own_src.sh" | grep -v "grep" | awk '{print $2}' | grep -v "^${CURRENT_PID}$")

if [ -n "$OLD_PIDS" ]; then
    echo "Killing existing down_src.sh processes..."
    for pid in $OLD_PIDS; do
        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    done
    sleep 1
    echo "Cleanup completed."
fi

mkdir -p "$LOG_DIR"
echo "Logs will be saved to: ${LOG_DIR}"

## ======================================================================
## 입력 파일 파싱 (빈 줄 기준 블록 분리)
## ======================================================================
## 전처리:
##   1. 공백만 있는 줄을 빈 줄로 변환
##   2. 연속된 빈 줄을 하나의 구분자로 처리
##   - repo init과 repo sync가 다른 줄에 있어도 같은 블록으로 인식
## awk paragraph mode (RS=""): 1개 이상 빈 줄을 레코드 구분자로 사용

mapfile -t command_blocks < <(sed 's/^[[:space:]]*$//' "$INPUT_FILE" | awk 'BEGIN{RS=""; FS="\n"} NF{gsub(/^[[:space:]]+|[[:space:]]+$/,""); gsub(/\n+/," ; "); print}')
echo "Total blocks found: ${#command_blocks[@]}"

## ======================================================================
## 병렬 실행 메인 루프
## ======================================================================
JOBDIR_PREFIX="down"
active_jobs=0
has_error=0
declare -A job_logs      # PID → 로그 파일 매핑
declare -A job_pids      # PID → JOB_ID 매핑
declare -a failed_logs   # 실패한 작업 로그 목록
START_DIR="$(pwd)"

for idx in "${!command_blocks[@]}"; do
    JOB_ID=$((idx + 1))
    cmd_block="${command_blocks[$idx]}"

    ## ==================================================================
    ## 1단계: 명령어 타입 분석 및 작업 환경 설정
    ## ==================================================================
    ## 명령어 타입(git clone/repo init)을 판별하고 작업 디렉토리명 결정
    if [[ "$cmd_block" =~ git[[:space:]]+clone ]]; then
        cmd_type="git_clone"
        JOBDIR_PREFIX="down.git"
    elif [[ "$cmd_block" =~ repo[[:space:]]+init ]]; then
        cmd_type="repo_init"
        JOBDIR_PREFIX="down.repo"
    else
        cmd_type="other"
        JOBDIR_PREFIX="down.xxx"
    fi

    JOB_DIR="${JOBDIR_PREFIX}.${JOB_ID}"
    LOG_FILE="$(pwd)/${LOG_DIR}/downcmd_${JOB_ID}.log"

    ## 색상 순환 할당 (1~4번 색상 반복)
    color_idx=$(( (JOB_ID - 1) % 4 + 1 ))
    JOB_COLOR="${JOB_COLORS[$color_idx]}"

    ## 작업 디렉토리 생성 및 이동
    mkdir -p "$JOB_DIR" && pushd "$JOB_DIR" > /dev/null
    echo -e "${JOB_COLOR}[${JOB_ID}.CMD-ORI] ${cmd_block// && / && \\n}${NC}" | sed 's/ ; / ;\n/g'
    actual_cmd="$cmd_block"

    ## ==================================================================
    ## 2단계: git clone 명령 분석 (재실행 대비)
    ## ==================================================================
    ## git clone에서 branch명과 예상 디렉토리명을 추출하고,
    ## 이미 clone된 경우 git pull 명령으로 변환 준비
    git_branch=""
    expected_dir=""
    git_pull_cmd=""

    if [ "$cmd_type" == "git_clone" ]; then
        ## branch 추출: -b <branch_name>
        [[ "$cmd_block" =~ -b[[:space:]]+([^[:space:]]+) ]] && git_branch="${BASH_REMATCH[1]}"

        ## 디렉토리명 추출: URL 마지막 부분에서 .git 제거
        ## 예: .../sa525m-le-3-1_amss_standard_oem.git → sa525m-le-3-1_amss_standard_oem
        [[ "$cmd_block" =~ /([^/[:space:]]+)\.git([[:space:]]|$) ]] && expected_dir="${BASH_REMATCH[1]}"

        ## 이미 clone된 디렉토리 존재 확인 → git pull 명령 생성
        if [ -n "$expected_dir" ] && [ -d "./$expected_dir/.git" ]; then
            if [ -n "$git_branch" ]; then
                git_pull_cmd="cd \"$expected_dir\" && git pull origin \"$git_branch\""
            else
                git_pull_cmd="cd \"$expected_dir\" && git pull"
            fi
        fi
    fi

    ## ==================================================================
    ## 3단계: Mirror 사용 여부에 따른 명령 변환
    ## ==================================================================
    ## MIRROR_PATH 유무와 명령어 타입 조합으로 4가지 케이스 처리:
    ## 1) mirror 없음 + git clone  → 재실행시 git pull
    ## 2) mirror 있음 + git clone  → mirror 업데이트 후 --reference로 clone
    ## 3) mirror 상관없이 + repo init  → mirror 생성/업데이트 후 --reference 추가

    case "${MIRROR_PATH:+mirror}~${cmd_type}" in
        ## Case 1: Mirror 미사용, git clone 재실행
        ~git_clone)
            [ -n "$git_pull_cmd" ] && actual_cmd="$git_pull_cmd"
            ;;

        ## Case 2: Mirror 사용, git clone
        mirror~git_clone)
            mirror_git_dir="$MIRROR_PATH/down.git.${JOB_ID}"

            if [ -n "$git_pull_cmd" ]; then
                ## 이미 clone 완료 → git pull로 업데이트
                echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Repository exists. Updating...${NC}"
                actual_cmd="$git_pull_cmd"
            else
                ## 신규 clone → mirror 활용
                git_clone_with_ref="${actual_cmd/git clone /git clone --reference \"$mirror_git_dir\" }"

                if [ ! -d "$mirror_git_dir/refs" ]; then
                    ## Mirror 없음 → git clone --mirror로 생성 후 --reference clone
                    echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Creating mirror at $mirror_git_dir${NC}"
                    rm -rf "$mirror_git_dir" 2>/dev/null || true
                    mirror_cmd="${actual_cmd/git clone /git clone --mirror }"
                    actual_cmd="$mirror_cmd \"$mirror_git_dir\" && $git_clone_with_ref"
                else
                    ## Mirror 있음 → git remote update 후 --reference clone
                    echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Updating mirror at $mirror_git_dir${NC}"
                    actual_cmd="(cd \"$mirror_git_dir\" && git remote update) || true && $git_clone_with_ref"
                fi
            fi
            ;;

        ## Case 3: Mirror 사용, repo init
        mirror~repo_init)
            repo_mirror_base="$MIRROR_PATH/down.repo.${JOB_ID}"

            ## Mirror 디렉토리 초기화
            if [ ! -d "$repo_mirror_base/.repo" ]; then
                echo -e "${JOB_COLOR}[${JOB_ID}.MIRROR-USE] Creating repo mirror at $repo_mirror_base/${NC}"
                mkdir -p "$repo_mirror_base"

                ## repo init --mirror 명령 생성 (--depth 제거)
                mirror_init_cmd="${actual_cmd//repo init /repo init --mirror }"
                mirror_init_cmd="$(echo "$mirror_init_cmd" | sed -E '0,/repo init/s|(^|[[:space:]])--depth(=[0-9]+|[[:space:]]+[0-9]+)([[:space:]]|$)| |g' | sed -E 's|  +| |g')"

                ## repo sync 명령 추출 (없으면 기본값 사용)
                mirror_sync_cmd="$(echo "$mirror_init_cmd" | sed -n '1{s|\(.*repo sync[^;]*\).*|\1|p}')"
                [ -z "$mirror_sync_cmd" ] && mirror_sync_cmd="${mirror_init_cmd} && repo sync -cj8"

                ## Mirror 생성 후 실제 작업 디렉토리에서도 실행
                actual_cmd="(cd \"$repo_mirror_base\" && $mirror_sync_cmd) && $actual_cmd"
            fi

            ## Mirror 존재시 --reference 옵션 추가
            if [[ -d "$repo_mirror_base/.repo" && ! "$actual_cmd" =~ --reference ]]; then
                actual_cmd="$(echo "$actual_cmd" | sed '0,/repo init /s|repo init |repo init --reference='"$repo_mirror_base"' |')"
            fi
            ;;
    esac

    ## ==================================================================
    ## 4단계: --depth 옵션 제거 (shallow clone 방지)
    ## ==================================================================
    ## 전체 히스토리 확보를 위해 --depth 옵션 제거
    ## git clone과 repo init 명령에서 모두 제거

    if [[ "$actual_cmd" =~ --depth(=|[[:space:]]+)[0-9]+ ]]; then
        if [[ "$actual_cmd" =~ (git[[:space:]]+clone|repo[[:space:]]+init) ]]; then
            actual_cmd="$(echo "$actual_cmd" | sed -E 's/(^|[[:space:]])--depth(=[0-9]+|[[:space:]]+[0-9]+)([[:space:]]|$)/ /g' | sed -E 's/  +/ /g')"
        fi
    fi

    ## ==================================================================
    ## 5단계: Manifest 파일 내 clone-depth 속성 제거
    ## ==================================================================
    ## repo init의 -m manifest에서 clone-depth 속성 제거 스크립트 생성

    if [[ "$actual_cmd" =~ repo[[:space:]]+init.*-m[[:space:]]+([^[:space:]]+) ]]; then
        manifest_file="${BASH_REMATCH[1]}"

        ## Manifest 수정 스크립트 생성 (clone-depth 제거)
        cat > fix_manifest.sh << 'MANIFEST_FIX_EOF' && chmod +x fix_manifest.sh
#!/bin/bash
manifest_file="$1"
if [ -f ".repo/manifests/${manifest_file}" ] && grep -q 'clone-depth' ".repo/manifests/${manifest_file}"; then
    cp ".repo/manifests/${manifest_file}" ".repo/manifests/${manifest_file}.ori"
    sed -i -E 's/[[:space:]]*clone-depth="[0-9]+"//g' ".repo/manifests/${manifest_file}"
    echo "Removed clone-depth from ${manifest_file}"
fi
MANIFEST_FIX_EOF

        ## repo init과 sync 사이에 fix 스크립트 삽입
        ## 변환: "repo init ... ; repo sync ..." → "repo init ... ; ./fix_manifest.sh ... && repo sync ..."
        fix_script_path="${START_DIR}/${JOB_DIR}/fix_manifest.sh"
        actual_cmd=$(echo "$actual_cmd" | sed "s|repo sync|${fix_script_path} '${manifest_file}' ; repo sync|g")
    fi

    ## ==================================================================
    ## 6단계: 명령 실행 및 PID 추적
    ## ==================================================================
    ## 백그라운드 실행 후 PID와 로그 파일 매핑

    echo -e "${JOB_COLOR}[${JOB_ID}.CMD-FINAL] ${actual_cmd//;/;\\n}${NC}"
    bash -ec "$actual_cmd" &> "$LOG_FILE" &
    popd > /dev/null

    ## PID 추적 및 실행 상태 출력
    pid=$!
    job_logs[$pid]="$LOG_FILE"
    job_pids[$pid]=$JOB_ID
    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${JOB_COLOR}[${JOB_ID}.RUNNING]: ${JOB_ID} in ${JOB_DIR}/ (PID: $pid, Log: ${LOG_DIR}/downcmd_${JOB_ID}.log)${NC}"
    fi
    ((active_jobs++))

    ## ==================================================================
    ## 7단계: 동시 실행 제어 (Throttling)
    ## ==================================================================
    ## MAX_JOBS 도달시 하나가 완료될 때까지 대기
    ## 완료된 작업의 종료 코드 확인 및 실패 로그 수집

    if (( active_jobs >= MAX_JOBS )); then
        wait -n
        exit_code=$?

        ## 종료된 작업 찾기 (kill -0으로 프로세스 존재 확인)
        for p in "${!job_logs[@]}"; do
            if ! kill -0 "$p" 2>/dev/null; then
                job_id_end=${job_pids[$p]}
                log_file_end="${job_logs[$p]}"
                JOB_COLOR_end="${JOB_COLORS[0]}"
                echo -e "${JOB_COLOR_end}[${job_id_end}.END] Check log: ${LOG_DIR}/downcmd_${job_id_end}.log${NC}"

                ## 실패한 작업 로그 수집
                if [ $exit_code -ne 0 ]; then
                    has_error=1
                    failed_logs+=("$log_file_end")
                fi

                ## PID/로그 매핑 제거
                unset "job_logs[$p]"
                unset "job_pids[$p]"
                break
            fi
        done
        ((active_jobs--))
    fi
done

## ======================================================================
## 종료 대기 및 최종 결과 집계
## ======================================================================
## 모든 백그라운드 작업 완료 대기 및 에러 수집

for pid in "${!job_logs[@]}"; do
    wait "$pid"
    exit_code=$?

    ## 실패한 작업 로그 기록
    if [ $exit_code -ne 0 ]; then
        has_error=1
        failed_logs+=("${job_logs[$pid]}")
    fi

    ## 작업 완료 출력
    job_id_final=${job_pids[$pid]}
    JOB_COLOR_final="${JOB_COLORS[0]}"
    echo -e "${JOB_COLOR_final}[${job_id_final}.END] Check log: ${LOG_DIR}/downcmd_${job_id_final}.log${NC}"
done

## ======================================================================
## 최종 결과 출력
## ======================================================================

if [ $has_error -eq 1 ]; then
    echo -e "${JOB_COLORS[0]}[ERROR] Some jobs failed. Check logs for details.${NC}"

    ## 실패한 모든 작업의 로그 출력
    for log_file in "${failed_logs[@]}"; do
        echo -e "${JOB_COLORS[0]}===== FAILED LOG: ${log_file} =====${NC}"
        cat "$log_file"
    done
    exit 1
else
    echo -e "${JOB_COLORS[4]}[FINISH] All download jobs completed.${NC}"
    exit 0
fi