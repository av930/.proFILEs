#!/bin/bash
# ==============================================================================
# Yocto Build 환경 변수 최적화 검증 스크립트
# 목적: Yocto 빌드 환경 진입 후 bitbake 명령어 실행 시 최적화 변수를 가로채 출력 (Injection)
# ==============================================================================

# 색상 정의
readonly COLOR_GREEN="\033[92m\033[1m"
readonly COLOR_CYAN="\033[96m"
readonly COLOR_YELLOW="\033[93m\033[1m"
readonly COLOR_RED="\033[91m\033[1m"
readonly COLOR_RESET="\033[0m"

# Yocto 빌드 환경 파라미터를 출력하는 함수
print_yocto_build_env() {
    echo -e "\n${COLOR_GREEN}[OKAY]${COLOR_RESET} Yocto Build Optimization Variables Check"

    # --------------------------------------------------------------------------
    # Bitbake 환경 유효성 체크
    # 환경이 구성되지 않았을 경우 경고 후 정상 리턴(bitbake 실행 거부 안함)
    # --------------------------------------------------------------------------
    if ! command -v bitbake >/dev/null 2>&1; then
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} bitbake command not found. Please source oe-init-build-env first."
        return 1
    fi

    echo "Extracting configuration via 'bitbake -e' (Please wait...)"

    # --------------------------------------------------------------------------
    # bitbake -e 를 통해 글로벌 환경변수 추출
    # 개별적으로 호출하면 너무 오래 걸리므로, 한번의 dump에서 일괄 grep 처리
    # --------------------------------------------------------------------------
    local env_dump
    env_dump=$(command bitbake -e | grep -E '^(BB_NUMBER_THREADS|PARALLEL_MAKE|SCONS_OVERRIDE_NUM_JOBS|DL_DIR|PREMIRRORS|MIRRORS)=')

    # --------------------------------------------------------------------------
    # 체크 타겟 리스트를 순회하며 결과값 파싱 및 포맷 출력
    # --------------------------------------------------------------------------
    for var in BB_NUMBER_THREADS PARALLEL_MAKE SCONS_OVERRIDE_NUM_JOBS DL_DIR PREMIRRORS MIRRORS; do
        local val
        val=$(echo "$env_dump" | grep "^${var}=" | cut -d= -f2- || true)

        if [[ -n "$val" ]]; then
            printf "  - %-25s : ${COLOR_CYAN}%s${COLOR_RESET}\n" "$var" "$val"
        else
            printf "  - %-25s : ${COLOR_YELLOW}Not Set${COLOR_RESET}\n" "$var"
        fi
    done
    echo ""
    return 0
}

# ------------------------------------------------------------------------------
# Bitbake 래퍼(Wrapper) 함수
# 사용자가 터미널에서 bitbake 입력 시 실제 명령어 수행 전 이 함수가 Intercept 함
# ------------------------------------------------------------------------------
bitbake() {
    # 1. 최초 1회 환경 설정 점검 수행
    print_yocto_build_env || true

    # 2. Wrapper 함수 자신을 메모리에서 삭제 (Injection 해제)
    unset -f bitbake

    # 4. 실제 시스템의 bitbake 명령어 수행
    command bitbake "$@"
}
echo -e "       Your next 'bitbake' command will automatically check and print optimization configs."

echo -e "${COLOR_GREEN}[OKAY]${COLOR_RESET} printYoctoBuild.sh successfully injected!"
