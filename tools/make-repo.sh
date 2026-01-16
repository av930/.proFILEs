#!/bin/bash
# Initialize repo structure in down-src directory
# Creates .repo/manifests/default.xml by merging manifests from down.list

INPUT_FILE="${1:-down.list}"
WORK_DIR="$(cd "$(dirname "$INPUT_FILE")" && pwd)"
REPO_DIR="${WORK_DIR}/.repo"
MANIFEST_DIR="${REPO_DIR}/manifests"
OUTPUT_MANIFEST="${MANIFEST_DIR}/default.xml"
INCLUDE_MANIFEST="${WORK_DIR}/down.list.xml"
PREFIX_GITNAME="$2"
JOB_DIR="result."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Initializing repo structure in: $WORK_DIR" >&2
echo "Input file: $INPUT_FILE" >&2
echo "Output manifest: $OUTPUT_MANIFEST" >&2

# 작업 디렉토리로 이동
cd "$WORK_DIR" || { echo "Error: Cannot access $WORK_DIR" >&2; exit 1; }

# 1단계: down.list 파일 검증
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found" >&2
    exit 1
fi

# .repo/manifests 디렉토리 생성
echo "Creating .repo/manifests directory..." >&2
mkdir -p "$MANIFEST_DIR"

# 2단계: down.list에서 블록별로 manifest xml 파일 추출
echo "Scanning for manifest files in $INPUT_FILE..." >&2
echo '<?xml version="1.0" encoding="UTF-8"?>' > "$INCLUDE_MANIFEST"
echo '<manifest>' >> "$INCLUDE_MANIFEST"

job_id=0
while IFS= read -r line || [ -n "$line" ]; do
    # 빈 줄이면 블록 구분
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
        continue
    fi

    # repo init 또는 git clone 명령 감지
    if [[ "$line" =~ (repo[[:space:]]+init|git[[:space:]]+clone) ]]; then
        ((job_id++))
        job_dir="${JOB_DIR}${job_id}"
        manifest_file=""
        manifest_path=""

        # -m 옵션이 있는 경우
        if [[ "$line" =~ -m[[:space:]]+([^[:space:]]+\.xml) ]]; then
            manifest_file="${BASH_REMATCH[1]}"
        else
            # -m 옵션이 없는 경우: repo init은 default.xml, git clone은 chipcode.xml
            if [[ "$line" =~ repo[[:space:]]+init ]]; then
                manifest_file="default.xml"
            elif [[ "$line" =~ git[[:space:]]+clone ]]; then
                manifest_file="chipcode.xml"
            fi
        fi

        if [ -n "$manifest_file" ]; then
            # 실제 파일 경로 찾기
            if [[ "$line" =~ repo[[:space:]]+init ]]; then
                # repo init: .repo/manifests/ 안에 있음
                manifest_path="${job_dir}/.repo/manifests/${manifest_file}"
            elif [[ "$line" =~ git[[:space:]]+clone ]]; then
                # git clone: clone된 디렉토리 안에서 찾기
                if [ -d "$job_dir" ]; then
                    found_path=$(find "$job_dir" -maxdepth 2 -name "$manifest_file" -type f 2>/dev/null | head -1)
                    [ -n "$found_path" ] && manifest_path="$found_path"
                fi
                # 못찾으면 기본 경로 사용
                [ -z "$manifest_path" ] && manifest_path="${job_dir}/${manifest_file}"
            fi

            echo "  <include name=\"${manifest_path}\"/>" >> "$INCLUDE_MANIFEST"
            [ -f "$manifest_path" ] && echo "Found: ${manifest_path}" >&2 || echo "Expected: ${manifest_path} (not exists)" >&2
        fi
    fi
done < "$INPUT_FILE"

echo '</manifest>' >> "$INCLUDE_MANIFEST"
echo "Include manifest created: $INCLUDE_MANIFEST" >&2

# 3단계: repo 구조 수동 생성 (repo init 없이)
echo "" >&2
echo "Setting up repo structure..." >&2

cd "$WORK_DIR" || exit 1

# repo tool 다운로드 (git clone으로 직접 다운로드)
if [ ! -d ".repo/repo" ] || [ ! -f ".repo/repo/main.py" ]; then
    echo "Downloading repo tool..." >&2
    rm -rf .repo/repo
    mkdir -p .repo/repo
    git clone -q https://gerrit.googlesource.com/git-repo .repo/repo 2>&1 | grep -v "^remote:" || true
    if [ -f ".repo/repo/main.py" ]; then
        echo "Repo tool downloaded successfully" >&2
    else
        echo "Warning: Failed to download repo tool" >&2
    fi
fi

# manifests를 git 저장소로 초기화 (default.xml이 생성된 후에 수행)
cd "$MANIFEST_DIR" || exit 1
if [ ! -d ".git" ]; then
    echo "Manifest git repository not yet created (will be created after merge-manifests.sh)" >&2
fi

# .repo/manifest.xml 심볼릭 링크 생성
cd "$REPO_DIR" || exit 1
ln -sf manifests/default.xml manifest.xml 2>/dev/null || true

# 필요한 디렉토리 구조 생성
mkdir -p projects project-objects

# 결과 출력
cd "$WORK_DIR" || exit 1

echo "" >&2
echo "===================================" >&2
echo "Repo structure initialized!" >&2
echo "Repo directory: $REPO_DIR" >&2
echo "Include manifest: $INCLUDE_MANIFEST" >&2
echo "===================================" >&2
echo "" >&2
echo "Running merge-manifests.sh to create default.xml and complete setup..." >&2

# merge-manifests.sh 자동 실행
"${SCRIPT_DIR}/merge-manifests.sh" "$INCLUDE_MANIFEST" "$OUTPUT_MANIFEST" "$WORK_DIR" "$PREFIX_GITNAME"

exit_code=$?
if [ $exit_code -eq 0 ]; then
    echo "" >&2
    echo "===================================" >&2
    echo "Repo project setup completed!" >&2
    echo "You can now use repo commands:" >&2
    echo "  repo list" >&2
    echo "  repo info" >&2
    echo "  repo status" >&2
    echo "===================================" >&2
else
    echo "Error: merge-manifests.sh failed with exit code $exit_code" >&2
    exit $exit_code
fi
