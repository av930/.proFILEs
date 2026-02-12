#!/bin/bash
# make-repo.sh - Manifest 병합 및 소스 다운로드 스크립트

# xmlstarlet 설치 확인
if ! command -v xmlstarlet &> /dev/null; then
    echo "Error: xmlstarlet is not installed. Please install it first." >&2
    echo "  Ubuntu/Debian: sudo apt-get install xmlstarlet" >&2
    echo "  CentOS/RHEL: sudo yum install xmlstarlet" >&2
    exit 1
fi

set -e

COMMAND="$1"
TARGET_PATH="$2"

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
Usage: $0 <command> <path>

Commands:
  mani <ori_dir_path>
              git clone과 repo init의 manifest 파일을 merge

  down <target_dir_path>
              merged manifest로 repo init & sync (unified mirror 사용)

Examples:
  $0 mani /data001/vc.integrator/mirror/down-down/ori
  $0 down /data001/vc.integrator/mirror/down-down/new

EOF
    exit 1
}

# ============================================================================
# mani: manifest 병합
# ============================================================================
merge_mani_handler() {
    local ori_dir="$1"

    if [ -z "$ori_dir" ]; then
        log_error "Ori directory path is required"
        usage
    fi

    # ori_dir를 절대 경로로 변환
    if [[ "$ori_dir" != /* ]]; then
        ori_dir="$(cd "$ori_dir" 2>/dev/null && pwd)" || ori_dir="$(pwd)/${ori_dir}"
    fi

    # ori_dir에서 work_dir 추론
    # ori_dir = /path/to/down-down/ori
    # work_dir = /path/to/down-down
    local work_dir=$(dirname "$ori_dir")

    log_info "Starting manifest merge..."
    log_info "Work directory: $work_dir"
    log_info "Ori directory: $ori_dir"

    # down.list 파일 확인
    local down_list="${work_dir}/down.list"
    if [ ! -f "$down_list" ]; then
        log_error "down.list not found: $down_list"
        exit 1
    fi

    # .repo/manifests 디렉토리 생성
    local manifests_dir="${ori_dir}/.repo/manifests"
    mkdir -p "$manifests_dir"

    # merged 디렉토리 생성 (전처리된 manifest 저장)
    local merged_dir="${manifests_dir}/merged"
    mkdir -p "$merged_dir"

    # down.list에서 manifest 파일명 추출
    local -a manifest_files=()
    while IFS= read -r line; do
        if [[ "$line" =~ repo[[:space:]]+init.*-m[[:space:]]+([^[:space:]]+) ]]; then
            manifest_files+=("${BASH_REMATCH[1]}")
        fi
    done < "$down_list"

    log_info "Found ${#manifest_files[@]} repo init manifest files in down.list"

    # unified_mirror 경로 추론 (work_dir/mirror/unified) - 먼저 정의
    local unified_mirror="${work_dir}/mirror/unified"

    # 전처리된 manifest 파일 목록
    local -a preprocessed_manifests=()
    # chipcode에서 사용하는 remote 정보 저장
    declare -A chipcode_remotes
    # 원본 manifest에서 추출한 모든 remote 정보 저장
    local temp_all_remotes="/tmp/all_remotes_$$.txt"
    > "$temp_all_remotes"

    # 1. down.git.* 디렉토리에서 chipcode.xml 전처리
    log_info "Processing git clone manifests..."
    for down_dir in "${work_dir}"/down.git.*; do
        [ ! -d "$down_dir" ] && continue

        local number=$(basename "$down_dir" | sed 's/down\.git\.//')
        log_info "Processing down.git.${number}..."

        local chipcode_xml=$(find "$down_dir" -maxdepth 3 -name "chipcode.xml" | head -1)
        if [ -n "$chipcode_xml" ]; then
            log_info "  Found: $chipcode_xml"

            # chipcode의 remote 정보 저장 (git.X 서브디렉토리 사용)
            local original_remote=$(xmlstarlet sel -t -v "//remote/@name" "$chipcode_xml" 2>/dev/null | head -1)
            if [ -n "$original_remote" ]; then
                chipcode_remotes["${original_remote}.${number}"]="${unified_mirror}/git.${number}"
            fi

            local preprocessed_file="${merged_dir}/chipcode_${number}.xml"
            preprocess_manifest "$chipcode_xml" "$preprocessed_file" "$number"
            preprocessed_manifests+=("chipcode_${number}.xml")
        fi
    done

    # 2. down.repo.* 디렉토리에서 manifest 전처리
    log_info "Processing repo init manifests..."
    local repo_idx=0
    for down_dir in "${work_dir}"/down.repo.*; do
        [ ! -d "$down_dir/.repo" ] && continue

        local number=$(basename "$down_dir" | sed 's/down\.repo\.//')
        log_info "Processing down.repo.${number}..."

        if [ $repo_idx -lt ${#manifest_files[@]} ]; then
            local manifest_name="${manifest_files[$repo_idx]}"
            local manifest_file="${down_dir}/.repo/manifests/${manifest_name}"

            if [ -f "$manifest_file" ]; then
                log_info "  Found: $manifest_file"

                # 전처리 전에 원본 manifest에서 remote 정보 추출 (repo.X 서브디렉토리 사용)
                xmlstarlet sel -t -m "//remote" \
                    -v "concat(@name, '.', '$number')" -o '|' \
                    -v "concat('${unified_mirror}/repo.', '$number')" -o '|' \
                    -v "@review" -n \
                    "$manifest_file" 2>/dev/null >> "$temp_all_remotes" || true

                local preprocessed_file="${merged_dir}/repo_${number}.xml"
                preprocess_manifest "$manifest_file" "$preprocessed_file" "$number"
                preprocessed_manifests+=("repo_${number}.xml")
            else
                log_warn "  Manifest not found: $manifest_file"
            fi
        fi
        repo_idx=$((repo_idx + 1))
    done

    # 3. merged.xml 생성 (include 방식) - manifests 루트에 생성
    local merged_file="${manifests_dir}/merged.xml"

    log_info "Creating merged manifest: $merged_file"
    log_info "Using unified mirror: $unified_mirror"

    cat > "$merged_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="local" fetch="file://${unified_mirror}" />
  <default remote="local" revision="master" />

EOF

    # chipcode에서 사용하는 remote 추가
    for remote_name in "${!chipcode_remotes[@]}"; do
        local fetch_url="${chipcode_remotes[$remote_name]}"
        echo "  <remote name=\"${remote_name}\" fetch=\"file://${fetch_url}\" />" >> "$merged_file"
        log_info "Added chipcode remote: $remote_name"
    done

    # 수집된 remote 정보를 merged.xml에 추가
    if [ -s "$temp_all_remotes" ]; then
        log_info "Adding collected remote definitions..."
        while IFS='|' read -r name fetch review; do
            [ -z "$name" ] && continue
            # fetch 경로 그대로 사용 (이미 repo.X 서브디렉토리 포함)
            if [ -n "$review" ] && [ "$review" != "null" ]; then
                echo "  <remote name=\"${name}\" fetch=\"file://${fetch}\" review=\"${review}\"/>" >> "$merged_file"
            else
                echo "  <remote name=\"${name}\" fetch=\"file://${fetch}\"/>" >> "$merged_file"
            fi
        done < "$temp_all_remotes"
    fi

    echo "" >> "$merged_file"

    # 각 전처리된 manifest를 include (merged/ 디렉토리 내의 파일들)
    for mani in "${preprocessed_manifests[@]}"; do
        echo "  <include name=\"merged/${mani}\" />" >> "$merged_file"
    done

    echo "</manifest>" >> "$merged_file"

    # 임시 파일 삭제
    rm -f "$temp_all_remotes"

    log_info "Manifest merge completed!"
    log_info "Total manifests merged: ${#preprocessed_manifests[@]}"
    log_info "Output: $merged_file"
    log_info "Preprocessed manifests in: $merged_dir"
}

# manifest 전처리 함수
preprocess_manifest() {
    local input_file="$1"
    local output_file="$2"
    local number="$3"

    log_info "  Preprocessing manifest..."

    # xmlstarlet을 사용하여 remote name을 변경한 XSLT 스타일시트 생성
    local xsl_file="/tmp/transform_${number}_$$.xsl"

    # remote name mapping을 위한 임시 파일
    local temp_remotes="/tmp/temp_remotes_${number}_$$.txt"
    xmlstarlet sel -t -m "//remote" -v "@name" -n "$input_file" 2>/dev/null > "$temp_remotes" || true

    # default remote 추출
    local default_remote=$(xmlstarlet sel -t -v "//default/@remote" "$input_file" 2>/dev/null | head -1)
    [ -z "$default_remote" ] && default_remote=""

    # remote name mapping 생성
    declare -A remote_mapping
    while IFS= read -r original_name; do
        [ -z "$original_name" ] && continue
        local new_name="${original_name}.${number}"
        remote_mapping["$original_name"]="$new_name"
        log_info "      Remote mapping: $original_name -> $new_name"
    done < "$temp_remotes"

    # Python 스크립트를 사용하여 XML 변환
    python3 - "$input_file" "$output_file" "$number" "$default_remote" << 'PYTHON_SCRIPT'
import sys
import xml.etree.ElementTree as ET

input_file = sys.argv[1]
output_file = sys.argv[2]
number = sys.argv[3]
default_remote = sys.argv[4] if len(sys.argv) > 4 else ""

# XML 파싱
tree = ET.parse(input_file)
root = tree.getroot()

# remote mapping 생성
remote_mapping = {}
for remote in root.findall('remote'):
    original_name = remote.get('name')
    if original_name:
        new_name = f"{original_name}.{number}"
        remote_mapping[original_name] = new_name

# chipcode.xml인지 확인 (remote fetch가 /data001로 시작하면 local git clone)
is_chipcode = False
for remote in root.findall('remote'):
    fetch = remote.get('fetch', '')
    if fetch.startswith('/data001') or fetch.startswith('file://'):
        is_chipcode = True
        break

# chipcode.xml의 경우
if is_chipcode:
    # 1단계: remote name을 변경
    for remote in root.findall('remote'):
        original_name = remote.get('name')
        if original_name and original_name in remote_mapping:
            remote.set('name', remote_mapping[original_name])

    # 2단계: 모든 project에 변경된 remote 속성 추가/변경 및 name을 path로 변경
    for project in root.findall('.//project'):
        # chipcode의 경우 name을 path로 변경 (ex: sa525m-.../SA525M_aop -> SA525M_aop)
        path = project.get('path')
        if path and path != '.':
            project.set('name', path)

        remote = project.get('remote')
        if remote:
            # remote 속성이 이미 있으면 변경
            if remote in remote_mapping:
                project.set('remote', remote_mapping[remote])
        else:
            # remote 속성이 없으면 default remote 사용
            if default_remote and default_remote in remote_mapping:
                project.set('remote', remote_mapping[default_remote])

    # 3단계: remote와 default 태그만 제거 (project의 remote 속성은 유지)
    for remote in root.findall('remote'):
        root.remove(remote)
    for default in root.findall('default'):
        root.remove(default)
else:
    # repo init manifest의 경우 remote name 변경
    for remote in root.findall('remote'):
        original_name = remote.get('name')
        if original_name and original_name in remote_mapping:
            remote.set('name', remote_mapping[original_name])

    # default 태그의 remote 변경
    for default in root.findall('default'):
        remote = default.get('remote')
        if remote and remote in remote_mapping:
            default.set('remote', remote_mapping[remote])

    # project 태그의 remote 변경/추가, upstream 속성 제거
    for project in root.findall('.//project'):
        remote = project.get('remote')
        if remote:
            # remote 속성이 이미 있으면 변경
            if remote in remote_mapping:
                project.set('remote', remote_mapping[remote])
        else:
            # remote 속성이 없으면 default remote 사용
            if default_remote and default_remote in remote_mapping:
                project.set('remote', remote_mapping[default_remote])

        # upstream 속성 제거 (mirror에서 upstream branch fetch 방지)
        if 'upstream' in project.attrib:
            del project.attrib['upstream']

    # repo init manifest도 remote와 default 태그 제거 (total.xml에 통합)
    for remote in root.findall('remote'):
        root.remove(remote)
    for default in root.findall('default'):
        root.remove(default)

# 저장
tree.write(output_file, encoding='UTF-8', xml_declaration=True)
PYTHON_SCRIPT

    if [ $? -eq 0 ]; then
        local project_count=$(grep -c '<project' "$output_file" || echo 0)
        log_info "      Processed $project_count projects"
        log_info "  Preprocessing completed: $(basename "$output_file")"
    else
        log_error "  Preprocessing failed for $(basename "$input_file")"
    fi

    # 임시 파일 삭제
    rm -f "$temp_remotes" "$xsl_file"
}

# ============================================================================
# down: 소스 다운로드
# ============================================================================
down_mani_handler() {
    local target_dir="$1"

    if [ -z "$target_dir" ]; then
        log_error "Target directory path is required"
        usage
    fi

    # target_dir를 절대 경로로 변환
    if [[ "$target_dir" != /* ]]; then
        target_dir="$(pwd)/${target_dir}"
    fi

    # target_dir에서 work_dir 추론
    # target_dir = /path/to/down-down/new
    # work_dir = /path/to/down-down
    local work_dir=$(cd "$(dirname "$target_dir")" && pwd)

    # work_dir로 이동 (down.list가 있는 디렉토리)
    cd "${work_dir}" || {
        log_error "Failed to change to work directory: ${work_dir}"
        exit 1
    }

    # work_dir의 .repo 삭제 (target_dir에서 새로 초기화하기 위해)
    if [ -d ".repo" ]; then
        log_info "Removing existing .repo directory from work directory..."
        rm -rf .repo
    fi

    # ori_dir와 unified_mirror 경로 설정
    local ori_dir="${work_dir}/ori"
    local manifests_dir="${ori_dir}/.repo/manifests"
    local merged_dir="${manifests_dir}/merged"
    local manifest_url="file://${manifests_dir}"
    local unified_mirror="${work_dir}/mirror/unified"

    log_info "Starting download with merged manifest..."
    log_info "Target directory: $target_dir"
    log_info "Work directory: $work_dir"
    log_info "Manifest URL: $manifest_url"
    log_info "Unified mirror: $unified_mirror"

    # merged.xml 존재 확인
    local merged_manifest="${manifests_dir}/merged.xml"
    if [ ! -f "$merged_manifest" ]; then
        log_error "Merged manifest not found: $merged_manifest"
        log_error "Please run 'mani ${ori_dir}' command first"
        exit 1
    fi

    # unified mirror 존재 확인
    if [ ! -d "$unified_mirror" ]; then
        log_error "Unified mirror not found: $unified_mirror"
        log_error "Please run merge-mirror.sh first"
        exit 1
    fi

    # manifests 디렉토리를 git repo로 초기화
    if [ ! -d "${manifests_dir}/.git" ]; then
        log_info "Initializing manifests directory as git repository..."
        cd "${manifests_dir}"
        git init
        git checkout -b default 2>/dev/null || git branch -m master default
        git add merged/ merged.xml
        git commit -m "Add merged manifests"
        cd "${work_dir}"
    else
        # 이미 git repo가 있으면 merged 디렉토리와 merged.xml 변경사항 commit
        log_info "Updating manifests git repository..."
        cd "${manifests_dir}"
        git add merged/ merged.xml
        git diff --cached --quiet || git commit -m "Update merged manifests"
        cd "${work_dir}"
    fi

    # target 디렉토리 생성 및 이동
    mkdir -p "$target_dir"

    log_info "Changing to target directory: $target_dir"
    cd "$target_dir" || {
        log_error "Failed to change to target directory: $target_dir"
        exit 1
    }

    log_info "Current directory: $(pwd)"
    log_info "Initializing repo..."
    log_info "Command: repo init -u \"${manifest_url}\" -b default -m merged.xml --reference=\"${unified_mirror}\""

    # repo init 실행
    if repo init -u "${manifest_url}" -b default -m merged.xml --reference="${unified_mirror}"; then
        log_info "repo init completed successfully"
    else
        log_error "repo init failed (exit code: $?)"
        exit 1
    fi

    log_info "Starting repo sync..."
    log_info "Command: repo sync --current-branch --fail-fast"

    local start_time=$(date +%s)

    # repo sync 실행 (--current-branch: upstream branch fetch 비활성화)
    if repo sync --current-branch --fail-fast; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_info "repo sync completed successfully!"
        log_info "Sync duration: ${duration} seconds ($(($duration / 60))m $(($duration % 60))s)"

        # 결과 통계
        local synced_projects=$(find "$target_dir" -maxdepth 3 -name ".git" -o -type l -name ".git" 2>/dev/null | wc -l)
        local total_size=$(du -sh "$target_dir" 2>/dev/null | awk '{print $1}')

        log_info "Total projects synced: $synced_projects"
        log_info "Total size: $total_size"
    else
        local exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_error "repo sync failed (exit code: $exit_code)"
        log_info "Sync duration before failure: ${duration} seconds"

        # 실패한 프로젝트 확인
        log_info "Checking for failed projects..."
        repo status 2>&1 | head -20

        exit $exit_code
    fi
}

# ============================================================================
# 메인 명령 처리
# ============================================================================
case "$COMMAND" in
    mani)
        merge_mani_handler "$TARGET_PATH"
        ;;
    down)
        down_mani_handler "$TARGET_PATH"
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        ;;
esac
