#!/bin/bash
# merge-mirror.sh - Mirror 통합 스크립트
#
# Purpose:
#   Manifest 파일의 모든 project를 분석하여 mirror/merged 디렉토리에 심볼릭 링크를 생성합니다.
#   여러 소스(git clone, repo sync, split)에서 생성된 .git 디렉토리들을 하나의 통합 mirror로 구성합니다.
#
# Features:
#   - 다중 소스 지원: down.git.*, down.repo.*, *_split 디렉토리 자동 감지
#   - Split 우선순위: split 버전이 있으면 우선적으로 사용
#   - 자동 링크 생성: manifest의 모든 project에 대해 .git 심볼릭 링크 생성
#   - 중복 방지: 이미 존재하는 링크는 건너뛰기
#   - 작업 디렉토리 자동 탐색: down.list 파일을 기준으로 작업 디렉토리 자동 탐지
#
# Usage:
#   merge-mirror.sh [MANIFEST] [WORK_DIR]
#
# Arguments:
#   MANIFEST   - 병합된 manifest 파일 경로 (default: merged-manifest.xml)
#   WORK_DIR   - 작업 디렉토리 (default: down.list가 있는 디렉토리)
#
# Environment Variables:
#   MARKER_FILE        - 작업 디렉토리 탐색 기준 파일 (default: down.list)
#   MIRROR_SUBDIR      - Mirror 생성 경로 (default: mirror/merged)
#   REPO_OBJECTS_PATH  - Repo project-objects 경로 (default: .repo/project-objects)
#
# Output:
#   ${WORK_DIR}/mirror/merged/*.git - 각 project의 .git 심볼릭 링크
#
# Example:
#   merge-mirror.sh merged-manifest.xml /path/to/work/dir
#   MIRROR_SUBDIR="mirror/custom" merge-mirror.sh manifest.xml
#

# ==================== 설정 ====================
MANIFEST="${1:-merged-manifest.xml}"
WORK_DIR="${2}"
MARKER_FILE="${MARKER_FILE:-down.list}"
MIRROR_SUBDIR="${MIRROR_SUBDIR:-mirror/merged}"
REPO_OBJECTS_PATH="${REPO_OBJECTS_PATH:-.repo/project-objects}"

# ==================== 작업 디렉토리 찾기 ====================
if [ -z "$WORK_DIR" ]; then
    [[ "$MANIFEST" = /* ]] && manifest_abs="$MANIFEST" || manifest_abs="$(pwd)/$MANIFEST"
    search_dir="$(dirname "$manifest_abs")"
    while [ "$search_dir" != "/" ]; do
        [ -f "$search_dir/$MARKER_FILE" ] && WORK_DIR="$search_dir" && echo "Found $MARKER_FILE in: $WORK_DIR" && break
        search_dir="$(dirname "$search_dir")"
    done
    [ -z "$WORK_DIR" ] && WORK_DIR="." && echo "Warning: $MARKER_FILE not found, using current directory"
fi

WORK_DIR=$(cd "$WORK_DIR" && pwd)
[[ "$MANIFEST" = /* ]] && MANIFEST_PATH="$MANIFEST" || MANIFEST_PATH="${WORK_DIR}/${MANIFEST}"
MERGED_DIR="$WORK_DIR/$MIRROR_SUBDIR"

echo "Creating mirror links..."
echo "  Work directory: $WORK_DIR"
echo "  Manifest: $MANIFEST_PATH"
echo "  Merged directory: $MERGED_DIR"

[ ! -f "$MANIFEST_PATH" ] && { echo "Error: Manifest file not found: $MANIFEST_PATH" >&2; exit 1; }
mkdir -p "$MERGED_DIR"

# ==================== 소스 디렉토리 구축 ====================
declare -A source_paths split_bases

# 1. split 구조 찾기 (부모 디렉토리를 source_path로 설정)
for dir in "$WORK_DIR"/down.git.*/*_split; do
    if [ -d "$dir" ]; then
        parent_dir=$(dirname "$dir")
        split_bases["${dir%_split}"]=1
        source_paths["split:$(basename $parent_dir):$(basename $dir)"]="$parent_dir"
    fi
done

# 2. 일반 git 디렉토리 찾기 (split 버전 제외)
for dir in "$WORK_DIR"/down.git.*; do
    [ -d "$dir" ] && [[ ! "$dir" =~ _split$ ]] && [[ ! -v split_bases["${dir}_split"] ]] && source_paths["git:$(basename $dir)"]="$dir"
done

# 3. repo 구조 찾기
for dir in "$WORK_DIR"/down.repo.*; do
    [ -d "$dir/$REPO_OBJECTS_PATH" ] && source_paths["repo:$(basename $dir)"]="$dir/$REPO_OBJECTS_PATH"
done
##소스가 들어있는 모든 path list 나열
echo "Found ${#source_paths[@]} source directories"


# ==================== .git path에 대한 mirror 링크 생성 ====================
total=0 skip=0 notfound=0

while read -r project_name; do
    target_path="$MERGED_DIR/${project_name}.git"

    if [ -L "$target_path" ] || [ -e "$target_path" ]; then
        ((skip++))
        continue
    fi

    mkdir -p "$(dirname "$target_path")"
    found=0

    for source_key in "${!source_paths[@]}"; do
        source_path="${source_paths[$source_key]}"
        source_type="${source_key%%:*}"

        case "$source_type" in
            split) src="$source_path/${project_name}/.git" ;;
            git) src="$source_path/${project_name}/.git" ;;
            repo) src="$source_path/${project_name}.git" ;;
        esac

        if [ -d "$src" ]; then
            ln -s "$src" "$target_path"
            echo "  Link: $project_name -> ${source_key#*:}"
            ((total++))
            found=1
            break
        fi
    done

    [ $found -eq 0 ] && echo "  WARN: Not found: $project_name" && ((notfound++))
done < <(grep -oP '<project name="\K[^"]+' "$MANIFEST_PATH")

echo ""
echo "Done! Created: $total, Skipped: $skip, Not found: $notfound"


