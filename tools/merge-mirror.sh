#!/bin/bash
# merge-mirror.sh - Mirror 통합 스크립트
# manifest 파일 기반으로 mirror/merged 디렉토리에 링크 생성

set -e

MANIFEST="${1:-merged-manifest.xml}"
WORK_DIR="${2}"

# WORK_DIR이 비어있으면 MANIFEST 경로에서 down.list가 있는 디렉토리 찾기
if [ -z "$WORK_DIR" ]; then
    # MANIFEST의 절대 경로 구하기
    [[ "$MANIFEST" = /* ]] && manifest_abs="$MANIFEST" || manifest_abs="$(pwd)/$MANIFEST"

    # manifest 파일의 디렉토리부터 시작
    search_dir="$(dirname "$manifest_abs")"

    # 상위로 올라가면서 down.list 찾기
    while [ "$search_dir" != "/" ]; do
        if [ -f "$search_dir/down.list" ]; then
            WORK_DIR="$search_dir"
            echo "Found down.list in: $WORK_DIR"
            break
        fi
        search_dir="$(dirname "$search_dir")"
    done

    # 못 찾으면 현재 디렉토리 사용
    [ -z "$WORK_DIR" ] && WORK_DIR="." && echo "Warning: down.list not found, using current directory"
fi

# 작업 디렉토리를 절대 경로로 변환
WORK_DIR=$(cd "$WORK_DIR" && pwd)

# MANIFEST 경로 설정 (절대 경로면 그대로, 상대 경로면 WORK_DIR 기준)
[[ "$MANIFEST" = /* ]] && MANIFEST_PATH="$MANIFEST" || MANIFEST_PATH="${WORK_DIR}/${MANIFEST}"

# MERGED_DIR 설정
MERGED_DIR="$WORK_DIR/mirror/merged"

echo "Creating mirror links..."
echo "  Work directory: $WORK_DIR"
echo "  Manifest: $MANIFEST_PATH"
echo "  Merged directory: $MERGED_DIR"

# manifest 파일 확인
if [ ! -f "$MANIFEST_PATH" ]; then
    echo "Error: Manifest file not found: $MANIFEST_PATH" >&2
    exit 1
fi

# merged 디렉토리 생성
mkdir -p "$MERGED_DIR"

# 통계
total=0
skip=0
git1=0
repo2=0
repo3=0
notfound=0

# manifest에서 모든 프로젝트 추출 및 링크 생성
grep -oP '<project name="\K[^"]+' "$MANIFEST_PATH" | while read -r project_name; do
    target_path="$MERGED_DIR/${project_name}.git"

    # 이미 존재하면 스킵
    if [ -L "$target_path" ] || [ -e "$target_path" ]; then
        skip=$((skip + 1))
        continue
    fi

    # 디렉토리 구조 생성
    target_dir=$(dirname "$target_path")
    mkdir -p "$target_dir"

    # 소스 .git 디렉토리 찾기
    found=0

    # 1. down.git.1에서 검색
    # 1-1. 전체 경로로 검색 (서브프로젝트용)
    src="$WORK_DIR/down.git.1/sa525m-le-3-1_amss_standard_oem_split/${project_name##*/}/.git"
    [ "$project_name" != "${project_name##*/}" ] && [ -d "$src" ] && ln -s "$src" "$target_path" && echo "  Link: $project_name -> down.git.1" && git1=$((git1 + 1)) && total=$((total + 1)) && continue
    
    # 1-2. 루트 프로젝트로 검색
    src="$WORK_DIR/down.git.1/${project_name}/.git"
    [ -d "$src" ] && ln -s "$src" "$target_path" && echo "  Link: $project_name -> down.git.1" && git1=$((git1 + 1)) && total=$((total + 1)) && continue

    # 2. down.repo.2 project-objects에서 검색
    src="$WORK_DIR/down.repo.2/.repo/project-objects/${project_name}.git"
    if [ -d "$src" ]; then
        ln -s "$src" "$target_path"
        echo "  Link: $project_name -> down.repo.2"
        repo2=$((repo2 + 1))
        total=$((total + 1))
        continue
    fi

    # 3. down.repo.3 project-objects에서 검색
    src="$WORK_DIR/down.repo.3/.repo/project-objects/${project_name}.git"
    if [ -d "$src" ]; then
        ln -s "$src" "$target_path"
        echo "  Link: $project_name -> down.repo.3"
        repo3=$((repo3 + 1))
        total=$((total + 1))
        continue
    fi

    echo "  WARN: Not found: $project_name"
    notfound=$((notfound + 1))
done

echo ""
echo "Done!"
echo "  Total created: $total"
echo "  From down.git.1: $git1"
echo "  From down.repo.2: $repo2"
echo "  From down.repo.3: $repo3"
echo "  Skipped (exists): $skip"
echo "  Not found: $notfound"


