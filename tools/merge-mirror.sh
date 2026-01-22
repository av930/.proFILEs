#!/bin/bash
# merge-mirror.sh - Mirror 통합 스크립트

# xmlstarlet 설치 확인
if ! command -v xmlstarlet &> /dev/null; then
    echo "Error: xmlstarlet is not installed. Please install it first." >&2
    echo "  Ubuntu/Debian: sudo apt-get install xmlstarlet" >&2
    echo "  CentOS/RHEL: sudo yum install xmlstarlet" >&2
    exit 1
fi

set -e

UNIFIED_MIRROR="$1"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로그 함수
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 사용법 출력
usage() {
    cat << EOF
Usage: $0 <unified_mirror_path>

Description:
  기존 git clone과 repo init으로 생성된 mirror를 unified로 통합
  실제 디렉토리 생성을 최소화하고 대부분 링크로 처리

Example:
  $0 /data001/vc.integrator/mirror/down-down/mirror/unified

EOF
    exit 1
}

if [ -z "$UNIFIED_MIRROR" ]; then
    log_error "Unified mirror path is required"
    usage
fi

# unified_mirror에서 work_dir 추론
# unified_mirror = /path/to/down-down/mirror/unified
# work_dir = /path/to/down-down
WORK_DIR=$(dirname "$(dirname "$UNIFIED_MIRROR")")

log_info "Starting unified mirror creation..."
log_info "Work directory: $WORK_DIR"
log_info "Unified mirror: $UNIFIED_MIRROR"

# unified mirror 디렉토리 생성
mkdir -p "$UNIFIED_MIRROR"

# ============================================================================
# git clone 기반 mirror 통합
# ============================================================================
merge_git_clone_mirrors() {
    local work_dir="$1"
    local unified_mirror="$2"

    log_info "Processing git clone directories..."

    local total_count=0
    # down.git.* 디렉토리 탐색
    for down_dir in "${work_dir}"/down.git.*; do
        [ ! -d "$down_dir" ] && continue

        local number=$(basename "$down_dir" | sed 's/down\.git\.//')
        log_info "Processing: $down_dir"

        # chipcode.xml 파일 찾기
        local chipcode_xml=$(find "$down_dir" -maxdepth 2 -name "chipcode.xml" | head -1)

        if [ -n "$chipcode_xml" ]; then
            log_info "Found chipcode.xml: $chipcode_xml"
            local base_dir=$(dirname "$chipcode_xml")

            # git.X 디렉토리 생성
            local git_dir_name="git.${number}"
            local git_mirror_dir="${unified_mirror}/${git_dir_name}"
            mkdir -p "$git_mirror_dir"
            log_info "Created directory: ${git_dir_name}/"

            # chipcode.xml에서 project name과 path를 기준으로 .git 링크 생성
            local temp_projects="/tmp/chipcode_projects_$$.txt"
            xmlstarlet sel -t -m "//project" -v "concat(@name,'|',@path)" -n "$chipcode_xml" 2>/dev/null > "$temp_projects"

            local count=0
            while read -r line; do
                [ -z "$line" ] && continue

                local proj_name="${line%%|*}"
                local proj_path="${line#*|}"

                local src_git_dir=""
                local mirror_name=""
                if [ "$proj_path" = "." ]; then
                    # 루트 프로젝트는 name 기준으로 링크 생성
                    src_git_dir="${base_dir}/.git"
                    mirror_name="$proj_name"
                else
                    # 하위 프로젝트는 path 기준으로 링크 생성
                    src_git_dir="${base_dir}/${proj_path}/.git"
                    mirror_name="$proj_path"
                fi

                if [ -d "$src_git_dir" ]; then
                    local mirror_path="${git_mirror_dir}/${mirror_name}.git"

                    if [ ! -e "$mirror_path" ]; then
                        local absolute_src_git_dir="$(cd "$(dirname "$src_git_dir")" && pwd)/$(basename "$src_git_dir")"
                        ln -sf "$absolute_src_git_dir" "$mirror_path"
                        count=$((count + 1))
                    fi
                fi
            done < "$temp_projects"
            rm -f "$temp_projects"

            log_info "Created $count .git links in ${git_dir_name}/"
            total_count=$((total_count + count))
        else
            # chipcode.xml이 없으면 전체 디렉토리를 링크
            local link_name="git.${number}"
            local mirror_path="${unified_mirror}/${link_name}"

            if [ ! -e "$mirror_path" ]; then
                local absolute_down_dir="$(cd "$down_dir" && pwd)"
                ln -sf "$absolute_down_dir" "$mirror_path"
                log_info "Created directory link: ${link_name} -> ${absolute_down_dir}"
                total_count=$((total_count + 1))
            fi
        fi
    done

    log_info "Processed git clone sources (${total_count} links)"
}

# ============================================================================
# repo init 기반 mirror 통합
# ============================================================================
merge_repo_init_mirrors() {
    local work_dir="$1"
    local unified_mirror="$2"

    log_info "Processing repo init directories..."

    local count=0
    # down.repo.* 디렉토리 탐색
    for down_dir in "${work_dir}"/down.repo.*; do
        [ ! -d "$down_dir/.repo" ] && continue

        local number=$(basename "$down_dir" | sed 's/down\.repo\.//')
        log_info "Processing: $down_dir"

        # project-objects 디렉토리를 통째로 링크
        local project_objects="${down_dir}/.repo/project-objects"
        if [ -d "$project_objects" ]; then
            local link_name="repo.${number}"
            local mirror_path="${unified_mirror}/${link_name}"

            if [ ! -e "$mirror_path" ]; then
                # project_objects를 절대 경로로 변환
                local absolute_project_objects="$(cd "$project_objects" && pwd)"
                ln -sf "$absolute_project_objects" "$mirror_path"
                log_info "Created directory link: ${link_name} -> ${absolute_project_objects}"
                count=$((count + 1))
            else
                log_warn "Mirror link already exists: ${link_name}"
            fi
        else
            log_warn "project-objects not found: $project_objects"
        fi
    done

    log_info "Processed $count repo init sources"
}

# ============================================================================
# 메인 실행
# ============================================================================
merge_git_clone_mirrors "$WORK_DIR" "$UNIFIED_MIRROR"
merge_repo_init_mirrors "$WORK_DIR" "$UNIFIED_MIRROR"

# 결과 요약
log_info "Unified mirror creation completed!"
log_info "Mirror location: $UNIFIED_MIRROR"
