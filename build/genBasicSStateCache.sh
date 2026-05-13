#!/bin/bash
set -e
# --------------------------------------------------
# 용도: Yocto 빌드에서 Image build후 basic library와 toolchain, cross/native tool들에 대한 sstate-cache만 추출하여 별도 디렉토리에 저장하는 스크립트
#      전체 sstate-cache에서 필요한 항목만 선별하여 daily나 event build에서 이용가능하도록 BASIC sstate-cache만 추출하는 기능
# 사용법: source generate_basic_sstate.sh <yocto-build-dir> <sstate-base-dir> [<prefix>-<machine>]
# 예제: source genBasicSStateCache.sh /SRC/nad/sa515m/SA515M_apps/apps_proc/build /data001/vc.integrator/mirror/tsu_26my_release/sstate-cache/BASIC 26tsu-sa515m

echo "================================================="
echo "Generating BASIC SSTATE into:"
echo "$BASIC_DIR"
echo "Yocto build dir:"
echo "$PATH_BUILD"
echo "================================================="

    echo "Expected one of: $PATH_BUILD/tmp-glibc/pkgdata or $PATH_BUILD/tmp/pkgdata"
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
gcc-cross-${TARGET_ARCH_NAME}
binutils-cross-${TARGET_ARCH_NAME}
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
# 5. extraction-only 방식으로 selected recipe에 해당하는 sstate만 선별
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

    while read -r mapped_pn; do
        [[ -n "$mapped_pn" ]] || continue
        find "$DEFAULT_SSTATE_DIR" \( -type f -o -type l \) -name "sstate:${mapped_pn}:*" -print >> "$FOUND_FILE_LIST"
    done < <(expand_sstate_recipes "$pn")

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
else
    echo "Error: no matching sstate files found for selected recipes"
    return 1 2>/dev/null || exit 1
fi

done < "$OUT_FILE"

[[ -s "$MISSING_RECIPE_LIST" ]] && echo "Missing recipe list: $MISSING_RECIPE_LIST"

sort -u "$FOUND_FILE_LIST" -o "$FOUND_FILE_LIST"

if [[ -s "$FOUND_FILE_LIST" ]]; then
    sed "s#^${DEFAULT_SSTATE_DIR}/##" "$FOUND_FILE_LIST" > "$REL_FILE_LIST"

# --------------------------------------------------
# 6. 사용자 검증용 비교 명령 출력
# --------------------------------------------------
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
echo "✅ BASIC SSTATE generation complete"
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