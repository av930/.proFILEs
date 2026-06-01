#!/bin/bash
set -euo pipefail
# --------------------------------------------------
# 용도: Yocto 빌드에서 Image build후 basic library와 toolchain, cross/native tool들에 대한 sstate-cache만 추출하여 별도 디렉토리에 저장하는 스크립트
#      전체 sstate-cache에서 필요한 항목만 선별하여 daily나 event build에서 이용가능하도록 BASIC sstate-cache만 추출하는 기능
# 사용법: generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> [<prefix>-<machine>]
# 예제: genBasicSStateCache.sh /SRC/nad/sa515m/SA515M_apps/apps_proc/build /data001/vc.integrator/mirror/tsu_26my_release/sstate-cache/BASIC 26tsu-sa515m
# 예제: genBasicSStateCache.sh /SRC/nad/sa515m/SA515M_apps/apps_proc/build /data001/vc.integrator/mirror/tsu_26my_release/sstate-cache/BASIC


# expand_sstate_recipes 내부에서만 사용하는 helper bundle 식별 토큰
readonly PN_BASIC_NATIVE_HELPERS="__basic_native_helpers__"

# --------------------------------------------------
# 1. 입력 인자 확인 및 build dir 검사
# --------------------------------------------------
PATH_BUILD_INPUT="${1:-}"
SSTATE_BASE="${2:-}"
ARG_VARIANT="${3:-}"
ARG_EXTRA="${4:-}"

# prefix-machine 문자열에서 project prefix와 machine 분리
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

# deploy/images 아래 manifest 이름 규칙으로 variant 자동 추론
detect_variant_from_manifest() {
    local tmp_base="$1"
    local manifest_path machine_name manifest_name variant_name

    while read -r manifest_path; do
        [[ -n "$manifest_path" ]] || continue
        [[ "$manifest_path" == *.rootfs.manifest ]] && continue

        machine_name=$(basename "$(dirname "$manifest_path")")
        manifest_name=$(basename "$manifest_path")
        variant_name=${manifest_name%-${machine_name}.manifest}

        [[ "$variant_name" == "$manifest_name" ]] && continue
        [[ "$variant_name" == *-* ]] || continue

        echo "$variant_name"
        return 0
    done < <(find "$tmp_base/deploy/images" -mindepth 2 -maxdepth 2 \( -type f -o -type l \) -name '*.manifest' 2>/dev/null | sort)

    return 1
}

# pkgdata 기준으로 target arch 이름 추출
detect_target_arch() {
    local pkgdata_base="$1"
    local tmp_base arch_from_pkgdata arch_from_sstate

    arch_from_pkgdata=$(find "$pkgdata_base" \( -type f -o -type d \) \( -name 'gcc-cross-*' -o -name 'binutils-cross-*' \) -exec basename {} \; 2>/dev/null |
        sed -n 's/^gcc-cross-//p; s/^binutils-cross-//p' |
        grep -v '^$' |
        sort -u |
        head -1)
    [[ -n "$arch_from_pkgdata" ]] && {
        echo "$arch_from_pkgdata"
        return 0
    }

    tmp_base=${pkgdata_base%/pkgdata}
    arch_from_sstate=$(grep -rhoE '/sysroots-components/[^/]+/' "$tmp_base"/sstate-control/manifest-*.populate_sysroot 2>/dev/null |
        sed -E 's#^.*/sysroots-components/([^/]+)/#\1#' |
        grep -Ev '^(allarch|any|noarch|x86_64|x86_64-linux)$' |
        sort | uniq -c | sort -rn | awk 'NR==1 { print $2 }')
    [[ -n "$arch_from_sstate" ]] && echo "$arch_from_sstate"
}

# local.conf에서 경로형 설정값을 절대경로로 해석
resolve_conf_value() {
    local conf_file="$1"
    local var_name="$2"
    local raw_line value

    raw_line=$(grep -E "^[[:space:]]*${var_name}[[:space:]]*[?+:]?=" "$conf_file" | grep -v '^[[:space:]]*#' | tail -1) || true
    [[ -n "$raw_line" ]] || return 1

    value=${raw_line#*=}
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'\''//;s/'\''$//')
    [[ -n "$value" ]] || return 1

    value=${value//\$\{TOPDIR\}/$PATH_BUILD}
    value=${value//\$TOPDIR/$PATH_BUILD}

    case "$value" in
        /*) ;;
        *) value="$PATH_BUILD/${value#./}" ;;
    esac

    echo "$value"
}

# build 설정의 SSTATE_DIR 우선 사용, 없으면 기본 경로 사용
resolve_sstate_dir() {
    local configured_dir

    configured_dir=$(resolve_conf_value "$PATH_BUILD/conf/local.conf" "SSTATE_DIR") || true
    [[ -n "$configured_dir" ]] && {
        echo "$configured_dir"
        return 0
    }

    echo "$PATH_BUILD/sstate-cache"
}

# recipe alias와 BASIC helper bundle을 실제 sstate recipe 이름으로 확장
expand_sstate_recipes() {
    local pn="${1:-}"

    case "$pn" in
        "$PN_BASIC_NATIVE_HELPERS")
            # BASIC에 추가로 포함할 native/build helper whitelist
            cat <<-EOF
				autoconf-native
				automake-native
				binutils-native
				bison-native
				cmake-native
				curl-native
				e2fsprogs-native
				expat-native
				file-native
				flex-native
				gettext-minimal-native
				gettext-native
				glib-2.0-native
				gmp-native
				gperf-native
				intltool-native
				libarchive-native
				libcap-native
				libedit-native
				libxml2-native
				libxslt-native
				m4-native
				make-native
				meson-native
				ninja-native
				openssl-native
				patch-native
				perl-native
				pkgconfig-native
				pseudo-native
				python3-native
				python3-setuptools-native
				python3-six-native
				qemu-native
				quilt-native
				re2c-native
				rsync-native
				squashfs-tools-native
				unzip-native
				util-linux-native
				xz-native
				zlib-native
				zstd-native
				cross-localedef-native
EOF
        ;;
        libstdc++)        printf '%s\n' gcc-runtime ;;
        glibc-native)     printf '%s\n' glibc cross-localedef-native ;;
        "")               return 0 ;;
        *)                printf '%s\n' "$pn" ;;
    esac
}

[[ -z "$PATH_BUILD_INPUT" || -z "$SSTATE_BASE" ]] && {
    echo "Usage: source genBasicSStateCache.sh <yocto-build-dir> <sstate-base-dir> [<prefix>-<machine>]"
    return 1 2>/dev/null || exit 1
}

[[ -n "$ARG_EXTRA" ]] && {
    echo "Usage: source genBasicSStateCache.sh <yocto-build-dir> <sstate-base-dir> [<prefix>-<machine>]"
    return 1 2>/dev/null || exit 1
}

PATH_BUILD=$(cd "$PATH_BUILD_INPUT" 2>/dev/null && pwd -P) || {
    echo "Error: invalid build dir path: $PATH_BUILD_INPUT"
    return 1 2>/dev/null || exit 1
}

[[ -f "$PATH_BUILD/conf/local.conf" && -f "$PATH_BUILD/conf/bblayers.conf" ]] || {
    echo "Error: not a Yocto build dir: $PATH_BUILD"
    return 1 2>/dev/null || exit 1
}

TMP_BASE=$(detect_tmp_base "$PATH_BUILD") || {
    echo "Error: failed to detect tmp output dir under $PATH_BUILD"
    echo "Expected one of: $PATH_BUILD/tmp-glibc/pkgdata or $PATH_BUILD/tmp/pkgdata"
    return 1 2>/dev/null || exit 1
}

if   [[ -n "$ARG_VARIANT" ]]; then
    parse_variant "$ARG_VARIANT" || {
        echo "Error: invalid manual input: $ARG_VARIANT"
        echo "Manual input required: source genBasicSStateCache.sh <yocto-build-dir> <sstate-base-dir> <prefix>-<machine>"
        echo "Example: source genBasicSStateCache.sh $PATH_BUILD_INPUT $SSTATE_BASE 26tsu-sa515m"
        return 1 2>/dev/null || exit 1
    }
elif parse_variant "${BUILD_TARGET_VARIANT:-}";              then :
elif [[ "${PATH_OUT:-}" =~ /upload_images/([^/]+-[^/]+)/ ]]; then parse_variant "${BASH_REMATCH[1]}"
elif detected_variant=$(detect_variant_from_manifest "$TMP_BASE"); then parse_variant "$detected_variant"
else
    echo "Error: failed to detect <prefix>-<machine> from BUILD_TARGET_VARIANT, PATH_OUT, or manifests under $TMP_BASE/deploy/images"
    echo "Manual input required: source genBasicSStateCache.sh <yocto-build-dir> <sstate-base-dir> <prefix>-<machine>"
    echo "Example: source genBasicSStateCache.sh $PATH_BUILD_INPUT $SSTATE_BASE 26tsu-sa515m"
    return 1 2>/dev/null || exit 1
fi

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
# 3. manifest/pkgdata/sstate 선별 결과 파일 경로 설정
# --------------------------------------------------
IMAGE_MANIFEST="${TMP_BASE}/deploy/images/${MACHINE}/${PRJ_PREFIX}-${MACHINE}-${MACHINE}.manifest"
PKGDATA_BASE="${TMP_BASE}/pkgdata"
RUNTIME_DIR="${PKGDATA_BASE}/${MACHINE}/runtime"
OUT_FILE="${PATH_BUILD}/basic-sstate-recipe-list.txt"
FOUND_FILE_LIST="${PATH_BUILD}/basic-sstate-found-files.txt"
REL_FILE_LIST="${PATH_BUILD}/basic-sstate-relative-files.txt"
MISSING_RECIPE_LIST="${PATH_BUILD}/basic-sstate-missing-recipes.txt"

[[ -f "$IMAGE_MANIFEST" ]] || {
    echo "Error: manifest not found: $IMAGE_MANIFEST"
    return 1 2>/dev/null || exit 1
}

[[ -d "$RUNTIME_DIR" ]] || {
    echo "Error: runtime pkgdata not found: $RUNTIME_DIR"
    return 1 2>/dev/null || exit 1
}

TARGET_ARCH_NAME="${TARGET_ARCH:-$(detect_target_arch "$PKGDATA_BASE")}" 

[[ -n "$TARGET_ARCH_NAME" ]] || {
    echo "Error: failed to detect TARGET_ARCH from pkgdata"
    return 1 2>/dev/null || exit 1
}

# --------------------------------------------------
# 4. Image manifest 기반 PN에 alias/helper/toolchain 확장을 합쳐 최종 recipe list 생성
# --------------------------------------------------
{
    # 4-1. manifest에서 package 추출 후 PN 변환
    awk '{print $1}' "$IMAGE_MANIFEST" | sort -u |
    while read -r pkg; do
        [[ -f "${RUNTIME_DIR}/${pkg}" ]] &&
        awk '/^PN:/ {print $2}' "${RUNTIME_DIR}/${pkg}"
    done | sort -u |

    # 4-2. 각 PN에 대해 alias와 native/cross 연관 recipe를 함께 확장
    while read -r pn; do
        [[ -n "$pn" ]] || continue
        expand_sstate_recipes "$pn"
        find "$PKGDATA_BASE" \( -name "${pn}-native" -o -name "${pn}-cross*" \) \
            -type f -exec basename {} \; 2>/dev/null
    done

    # 4-3. 기본 toolchain/libc는 manifest와 무관하게 항상 포함
    while read -r pn; do
        expand_sstate_recipes "$pn"
    done <<EOF
gcc-cross-${TARGET_ARCH_NAME}
binutils-cross-${TARGET_ARCH_NAME}
gcc-runtime
glibc
glibc-native
libgcc
libstdc++
EOF

    # 4-4. BASIC에서 재사용할 native/build helper 묶음 추가
    expand_sstate_recipes "$PN_BASIC_NATIVE_HELPERS"

# 중복 제거 후 최종 recipe list 생성
} | sort -u > "$OUT_FILE"

echo "Recipe list generated: $OUT_FILE"
echo "Total recipes: $(wc -l < "$OUT_FILE")"

# --------------------------------------------------
# 5. recipe list 기준으로 matching sstate만 추출 복사
# --------------------------------------------------
DEFAULT_SSTATE_DIR=$(resolve_sstate_dir)

[[ -d "$DEFAULT_SSTATE_DIR" ]] || {
    echo "Error: SSTATE_DIR not found: $DEFAULT_SSTATE_DIR"
    return 1 2>/dev/null || exit 1
}

echo "Default SSTATE_DIR detected:"
echo "$DEFAULT_SSTATE_DIR"

echo "Copying matching sstate objects to BASIC..."

: > "$FOUND_FILE_LIST"
: > "$REL_FILE_LIST"
: > "$MISSING_RECIPE_LIST"

while read -r pn; do
    [[ -n "$pn" ]] || continue

    # alias까지 확장한 recipe 이름으로 실제 sstate 파일 수집
    while read -r mapped_pn; do
        [[ -n "$mapped_pn" ]] || continue
        find "$DEFAULT_SSTATE_DIR" \( -type f -o -type l \) -name "sstate:${mapped_pn}:*" -print >> "$FOUND_FILE_LIST"
    done < <(expand_sstate_recipes "$pn")

    # 원본 pn과 alias 어느 쪽에도 매칭이 없으면 missing 처리
    if ! grep -Fq "sstate:${pn}:" "$FOUND_FILE_LIST"; then
        found_alias_match=0
        while read -r mapped_pn; do
            [[ -n "$mapped_pn" ]] || continue
            if grep -Fq "sstate:${mapped_pn}:" "$FOUND_FILE_LIST"; then
                found_alias_match=1
                break
            fi
        done < <(expand_sstate_recipes "$pn")

        [[ "$found_alias_match" -eq 0 ]] && echo "$pn" >> "$MISSING_RECIPE_LIST"
    fi
done < "$OUT_FILE"

sort -u "$FOUND_FILE_LIST" -o "$FOUND_FILE_LIST"

if [[ -s "$FOUND_FILE_LIST" ]]; then
    sed "s#^${DEFAULT_SSTATE_DIR}/##" "$FOUND_FILE_LIST" > "$REL_FILE_LIST"
    rsync -a --ignore-existing --files-from="$REL_FILE_LIST" \
        "$DEFAULT_SSTATE_DIR"/ \
        "$BASIC_DIR"/
else
    echo "Error: no matching sstate files found for selected recipes"
    return 1 2>/dev/null || exit 1
fi

echo "Matched sstate files: $(wc -l < "$FOUND_FILE_LIST")"
echo "Missing recipes: $(wc -l < "$MISSING_RECIPE_LIST")"
[[ -s "$MISSING_RECIPE_LIST" ]] && echo "Missing recipe list: $MISSING_RECIPE_LIST"

echo "================================================="
echo "[OKAY] BASIC SSTATE generation complete"
echo "Location: $BASIC_DIR"
echo "================================================="

# --------------------------------------------------
# 6. 사용자 검증용 비교 명령 출력
# --------------------------------------------------
echo ""
echo "===== Verification Commands ====="
echo "1) BASIC sstate 파일 개수 확인"
echo "   find $BASIC_DIR -type f | wc -l"
echo ""
echo "2) 선별 복사된 파일 목록 확인"
echo "   head $FOUND_FILE_LIST"
echo ""
echo "3) 누락된 recipe 확인"
echo "   cat $MISSING_RECIPE_LIST"
echo ""
echo "4) BASIC에 존재하는 항목 비율 확인"
echo "   echo \"FULL:\" \$(find $DEFAULT_SSTATE_DIR -type f | wc -l)"
echo "   echo \"BASIC:\" \$(find $BASIC_DIR -type f | wc -l)"
echo "=================================="