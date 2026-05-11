#!/bin/bash
set -e
# --------------------------------------------------
# 용도: Yocto 빌드에서 Image build후 basic library와 toolchain, cross/native tool들에 대한 sstate-cache만 추출하여 별도 디렉토리에 저장하는 스크립트
#      전체 sstate-cache에서 필요한 항목만 선별하여 daily나 event build에서 이용가능하도록 BASIC sstate-cache만 추출하는 기능
# 사용법: source generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> [<prefix>-<machine>]
# 예제: source genBasicSStateCache.sh /SRC/nad/sa515m/SA515M_apps/apps_proc/build /data001/vc.integrator/mirror/tsu_26my_release/sstate-cache/BASIC 26tsu-sa515m


# --------------------------------------------------
# 1. 입력 인자 확인 및 build dir 검사
# --------------------------------------------------
PATH_BUILD_INPUT="$1"
SSTATE_BASE="$2"
ARG_VARIANT="$3"
ARG_EXTRA="$4"

# prefix-machine 문자열에서 값 추출
parse_variant() {
    local variant="$1"

    [[ "$variant" == *-* ]] || return 1

    PRJ_PREFIX="${variant%-*}"
    MACHINE="${variant##*-}"
    [[ -n "$PRJ_PREFIX" && -n "$MACHINE" ]] || return 1
    return 0
}

# tmp 출력 루트 자동 탐색
detect_tmp_base() {
    local path_build="$1"

    [[ -d "$path_build/tmp-glibc/pkgdata" ]] && { echo "$path_build/tmp-glibc"; return 0; }
    [[ -d "$path_build/tmp/pkgdata" ]]       && { echo "$path_build/tmp";       return 0; }
    return 1
}

[ -z "$PATH_BUILD_INPUT" ] || [ -z "$SSTATE_BASE" ] && {
    echo "Usage: source generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> <prefix>-<machine>"
    return 1 2>/dev/null || exit 1
}

[ -n "$ARG_EXTRA" ] && {
    echo "Usage: source generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> [<prefix>-<machine>]"
    return 1 2>/dev/null || exit 1
}

if   [[ -n "$ARG_VARIANT" ]]; then
    parse_variant "$ARG_VARIANT" || {
        echo "Error: invalid manual input: $ARG_VARIANT"
        echo "Manual input required: source generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> <prefix>-<machine>"
        echo "Example: source generate_basic_sstate.sh $PATH_BUILD_INPUT $SSTATE_BASE 26tsu-sa515m"
        return 1 2>/dev/null || exit 1
    }
elif parse_variant "$BUILD_TARGET_VARIANT";              then :
elif [[ "$PATH_OUT" =~ /upload_images/([^/]+-[^/]+)/ ]]; then parse_variant "${BASH_REMATCH[1]}"
else
    echo "Error: failed to detect <prefix>-<machine> from BUILD_TARGET_VARIANT or PATH_OUT"
    echo "Manual input required: source generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> <prefix>-<machine>"
    echo "Example: source generate_basic_sstate.sh $PATH_BUILD_INPUT $SSTATE_BASE 26tsu-sa515m"
    return 1 2>/dev/null || exit 1
fi

PATH_BUILD=$(cd "$PATH_BUILD_INPUT" 2>/dev/null && pwd -P) || {
    echo "Error: invalid build dir path: $PATH_BUILD_INPUT"
    return 1 2>/dev/null || exit 1
}

[[ -f "$PATH_BUILD/conf/local.conf" && -f "$PATH_BUILD/conf/bblayers.conf" ]] || {
    echo "Error: not a Yocto build dir: $PATH_BUILD"
    return 1 2>/dev/null || exit 1
}

[[ "${SSTATE_BASE##*/}" == "BASIC" ]] && BASIC_DIR="$SSTATE_BASE" || BASIC_DIR="${SSTATE_BASE}/BASIC"

# --------------------------------------------------
# 2. BASIC sstate 저장 디렉토리 생성
# --------------------------------------------------
mkdir -p "$BASIC_DIR"

echo "================================================="
echo "Generating BASIC SSTATE into:"
echo "$BASIC_DIR"
echo "Yocto build dir:"
echo "$PATH_BUILD"
echo "================================================="

# --------------------------------------------------
# 3. 기본 경로 설정 (manifest / pkgdata)
# --------------------------------------------------
TMP_BASE=$(detect_tmp_base "$PATH_BUILD") || {
    echo "Error: failed to detect tmp output dir under $PATH_BUILD"
    echo "Expected one of: $PATH_BUILD/tmp-glibc/pkgdata or $PATH_BUILD/tmp/pkgdata"
    return 1 2>/dev/null || exit 1
}

IMAGE_MANIFEST="${TMP_BASE}/deploy/images/${MACHINE}/${PRJ_PREFIX}-${MACHINE}-${MACHINE}.manifest"
PKGDATA_BASE="${TMP_BASE}/pkgdata"
RUNTIME_DIR="${PKGDATA_BASE}/${MACHINE}/runtime"
OUT_FILE="${PATH_BUILD}/basic-sstate-recipe-list.txt"

[[ -f "$IMAGE_MANIFEST" ]] || {
    echo "Error: manifest not found: $IMAGE_MANIFEST"
    return 1 2>/dev/null || exit 1
}

[[ -d "$RUNTIME_DIR" ]] || {
    echo "Error: runtime pkgdata not found: $RUNTIME_DIR"
    return 1 2>/dev/null || exit 1
}

# --------------------------------------------------
# 4. Image → PN → native/cross 확장 + toolchain 포함
# --------------------------------------------------
{
    # 4-1. manifest에서 package 추출 후 PN 변환
    awk '{print $1}' "$IMAGE_MANIFEST" | sort -u |
    while read -r pkg; do
        [ -f "${RUNTIME_DIR}/${pkg}" ] &&
        awk '/^PN:/ {print $2}' "${RUNTIME_DIR}/${pkg}"
    done | sort -u |

    # 4-2. 각 PN에 대해 native / cross 확장
    while read -r pn; do
        echo "$pn"
        find "$PKGDATA_BASE" \( -name "${pn}-native" -o -name "${pn}-cross*" \) \
            -type f -exec basename {} \; 2>/dev/null
    done

    # 4-3. 기본 toolchain / libc 강제 포함
    cat <<EOF
gcc-cross-${TARGET_ARCH}
binutils-cross-${TARGET_ARCH}
gcc-runtime
glibc
glibc-native
libgcc
libstdc++
EOF

# 중복 제거 후 최종 recipe list 생성
} | sort -u > "$OUT_FILE"

echo "Recipe list generated: $OUT_FILE"
echo "Total recipes: $(wc -l < "$OUT_FILE")"

# --------------------------------------------------
# 5. BASIC sstate 생성 (기존 FULL sstate 그대로 사용)
#    → build 완료 상태이므로 재컴파일 없이 sstate만 생성됨
# --------------------------------------------------
echo "Populating BASIC sstate-cache..."
bitbake $(cat "$OUT_FILE")

# --------------------------------------------------
# 6. 생성된 sstate 중 BASIC에 해당하는 파일만 복사
#    (현재 default SSTATE_DIR 기준에서 추출)
# --------------------------------------------------
DEFAULT_SSTATE_DIR=$(bitbake -e | grep '^SSTATE_DIR=' | cut -d'"' -f2)

echo "Default SSTATE_DIR detected:"
echo "$DEFAULT_SSTATE_DIR"

echo "Copying matching sstate objects to BASIC..."

grep -o 'sstate:[^ ]*' "$OUT_FILE" 2>/dev/null || true

# 실제 파일 복사 (task hash 기반 전체 복사 방식)
rsync -a --ignore-existing \
    "$DEFAULT_SSTATE_DIR"/ \
    "$BASIC_DIR"/

echo "================================================="
echo "✅ BASIC SSTATE generation complete"
echo "Location: $BASIC_DIR"
echo "================================================="

# --------------------------------------------------
# 7. 사용자 검증용 비교 명령 출력
# --------------------------------------------------
echo ""
echo "===== Verification Commands ====="
echo "1) BASIC sstate 파일 개수 확인"
echo "   find $BASIC_DIR -type f | wc -l"
echo ""
echo "2) FULL vs BASIC 파일 차이 확인"
echo "   diff <(ls $DEFAULT_SSTATE_DIR | sort) <(ls $BASIC_DIR | sort)"
echo ""
echo "3) BASIC에 존재하는 항목 비율 확인"
echo "   echo \"FULL:\" \$(find $DEFAULT_SSTATE_DIR -type f | wc -l)"
echo "   echo \"BASIC:\" \$(find $BASIC_DIR -type f | wc -l)"
echo "=================================="