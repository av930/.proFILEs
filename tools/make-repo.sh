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

# include manifest 초기화
echo '<?xml version="1.0" encoding="UTF-8"?>' > "$INCLUDE_MANIFEST"
echo '<manifest>' >> "$INCLUDE_MANIFEST"

# 2단계: down.list에서 블록별로 manifest xml 파일 추출
echo "Scanning for manifest files in $INPUT_FILE..." >&2
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

# 3단계: include manifest를 기반으로 default.xml 생성
echo "" >&2
echo "Merging manifests into default.xml..." >&2

# XML 헤더와 manifest 시작
cat > "$OUTPUT_MANIFEST" << 'XMLHEAD'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
XMLHEAD

# 모든 include 파일에서 remote 정의 추출
echo "  <!-- Merged remote definitions -->" >> "$OUTPUT_MANIFEST"

# 로컬 devops remote 추가 (down-src 디렉토리를 fetch URL로 사용)
echo "  <remote name=\"local-devops\" fetch=\"file://${WORK_DIR}\" review=\"\"/>" >> "$OUTPUT_MANIFEST"

names="|local-devops|"  # 이미 처리된 remote name들을 저장 (|name1|name2| 형태)
while IFS= read -r line; do
    # include 태그에서 파일 경로 추출
    [[ "$line" =~ \<include.*name=\"([^\"]+)\" ]] || continue
    file="${BASH_REMATCH[1]}"
    echo "Processing include: $file" >&2
    [ ! -f "$file" ] && echo "Warning: Include file not found: $file" >&2 && continue

    # 각 파일에서 remote 태그 추출 및 처리
    while IFS= read -r rline; do
        # remote name 추출
        [[ "$rline" =~ name=\"([^\"]+)\" ]] || continue
        name="${BASH_REMATCH[1]}"

        # 중복된 name이면 name.1, name.2 로 변경하여 추가
        if [[ "$names" == *"|$name|"* ]]; then
            i=1
            while [[ "$names" == *"|$name.$i|"* ]]; do ((i++)); done  # 사용 가능한 번호 찾기
            rline="${rline/name=\"$name\"/name=\"$name.$i\"}"  # name 속성 변경
            names="$names$name.$i|"  # 변경된 이름 저장
        else
            names="$names$name|"  # 새로운 이름 저장
        fi
        echo "$rline" >> "$OUTPUT_MANIFEST"
    done < <(grep -E '^ *<remote ' "$file" 2>/dev/null | sort -u)  # remote 태그만 추출 및 정렬
done < "$INCLUDE_MANIFEST"

# default 값은 로컬 devops remote 사용
echo "" >> "$OUTPUT_MANIFEST"
echo "  <!-- Default definition -->" >> "$OUTPUT_MANIFEST"
echo '  <default remote="local-devops" revision="master"/>' >> "$OUTPUT_MANIFEST"

# 각 include 파일의 모든 project list 추가
echo "" >> "$OUTPUT_MANIFEST"

# 실제 git 저장소 경로 매핑 생성 (result.* 디렉토리 스캔)
declare -A git_basename_map
declare -A git_fullpath_map
echo "Scanning for git repositories..." >&2
while IFS= read -r git_dir; do
    # .git 디렉토리의 부모 디렉토리 경로
    project_dir=$(dirname "$git_dir")
    # basename으로 매핑 (예: SA525M_aop -> result.1/.../SA525M_aop)
    basename_key=$(basename "$project_dir")
    git_basename_map["$basename_key"]="$project_dir"
    # 전체 경로도 저장
    git_fullpath_map["$project_dir"]="$project_dir"
done < <(find result.* -name ".git" -type d 2>/dev/null)

echo "Found ${#git_basename_map[@]} git repositories" >&2

# 통계 카운터 초기화
linked_count=0
missing_count=0
skipped_count=0

while IFS= read -r line; do
    if [[ "$line" =~ \<include.*name=\"([^\"]+)\" ]]; then
        include_file="${BASH_REMATCH[1]}"

        if [ -f "$include_file" ]; then
            echo "" >> "$OUTPUT_MANIFEST"
            echo "  <!-- ==================== Projects from: $include_file ==================== -->" >> "$OUTPUT_MANIFEST"

            # include_file 경로에서 result.* 디렉토리 추출
            result_prefix=""
            if [[ "$include_file" =~ (result\.[^/]+)/ ]]; then
                result_prefix="${BASH_REMATCH[1]}/"
                echo "Detected result prefix: $result_prefix" >&2
            fi

            # git 매핑 정보를 임시 파일로 전달
            GIT_MAP_FILE=$(mktemp)
            for key in "${!git_basename_map[@]}"; do
                echo "$key=${git_basename_map[$key]}" >> "$GIT_MAP_FILE"
            done

            # project 태그 처리와 동시에 심볼릭 링크 생성
            # 임시 manifest 파일 생성
            TEMP_MANIFEST=$(mktemp)

            awk -v prefix="$PREFIX_GITNAME" -v workdir="$WORK_DIR" -v mapfile="$GIT_MAP_FILE" -v result_prefix="$result_prefix" '
                BEGIN {
                    # git 매핑 정보 로드
                    while ((getline < mapfile) > 0) {
                        split($0, arr, "=")
                        git_map[arr[1]] = arr[2]
                    }
                    close(mapfile)

                    # prefix가 있으면 뒤에 / 추가
                    prefix_sep = (prefix != "") ? prefix "/" : ""
                }
                /<project/ {
                    # upstream, dest-branch, remote 속성 제거
                    gsub(/ upstream="[^"]*"/, "")
                    gsub(/ dest-branch="[^"]*"/, "")
                    gsub(/ remote="[^"]*"/, "")

                    # project name에 PREFIX 추가
                    if (match($0, /name="([^"]+)"/, name_arr)) {
                        name = name_arr[1]
                        # PREFIX_GITNAME이 있고, 이미 prefix로 시작하지 않으면 추가
                        if (prefix != "") {
                            name_lower = tolower(name)
                            prefix_lower = tolower(prefix)
                            if (index(name_lower, "qct/") != 1 && index(name, prefix_sep) != 1) {
                                gsub(/name="[^"]*"/, "name=\"" prefix_sep name "\"")
                            }
                        }
                    }

                    # path 속성 처리
                    if (match($0, /path="([^"]+)"/, path_arr)) {
                        original_path = path_arr[1]
                        # basename 추출 (마지막 / 이후)
                        n = split(original_path, parts, "/")
                        basename = parts[n]

                        # basename으로 실제 git 경로 찾기 (result.1의 split 프로젝트용)
                        if (basename in git_map) {
                            real_path = git_map[basename]
                            gsub(/path="[^"]*"/, "path=\"" real_path "\"")
                        }
                        # result_prefix가 있으면 경로 앞에 추가 (result.2, result.3 프로젝트용)
                        else if (result_prefix != "" && index(original_path, result_prefix) != 1) {
                            gsub(/path="[^"]*"/, "path=\"" result_prefix original_path "\"")
                        }
                    }
                    # path 속성이 없으면 name을 path로 사용 (repo 기본 동작)
                    else if (match($0, /name="([^"]+)"/, name_arr)) {
                        name_value = name_arr[1]
                        # PREFIX가 있는 경우 제거하여 실제 경로 추출
                        if (prefix != "" && index(name_value, prefix_sep) == 1) {
                            # prefix와 / 를 제거한 나머지 부분
                            path_from_name = substr(name_value, length(prefix_sep) + 1)
                        } else {
                            path_from_name = name_value
                        }

                        # result_prefix 추가
                        if (result_prefix != "") {
                            path_from_name = result_prefix path_from_name
                        }

                        # revision 속성 앞에 path 삽입
                        gsub(/ revision=/, " path=\"" path_from_name "\" revision=")
                    }

                    in_project = 1
                    print
                    # 한줄짜리 project 태그 처리
                    if (/\/>/) in_project = 0
                    next
                }
                in_project {
                    print
                    if (/<\/project>/) in_project = 0
                    next
                }
            ' "$include_file" > "$TEMP_MANIFEST"

            # manifest에 추가하고 동시에 심볼릭 링크 생성
            while IFS= read -r project_line; do
                echo "$project_line" >> "$OUTPUT_MANIFEST"

                # project path 추출하여 심볼릭 링크 생성
                if [[ "$project_line" =~ \<project.*path=\"([^\"]+)\" ]]; then
                    project_path="${BASH_REMATCH[1]}"

                    # 대상 디렉토리가 이미 존재하면 스킵
                    if [ -e "$project_path" ]; then
                        ((skipped_count++))
                        continue
                    fi

                    # result.*/ 디렉토리에서 해당 경로 찾기
                    source_found=false
                    for result_dir in result.*; do
                        [ ! -d "$result_dir" ] && continue

                        source_path="$result_dir/$project_path"
                        if [ -d "$source_path" ] || [ -L "$source_path" ]; then
                            # 실제 소스가 있을 때만 부모 디렉토리 생성
                            mkdir -p "$(dirname "$project_path")"

                            # 심볼릭 링크 생성 (절대 경로 사용)
                            if ln -sf "$(cd "$result_dir" && pwd)/$project_path" "$project_path" 2>/dev/null; then
                                source_found=true
                                ((linked_count++))

                                # git 저장소인 경우 .repo/projects/에 등록
                                if [ -d "$source_path/.git" ]; then
                                    project_git_dir=".repo/projects/$project_path.git"
                                    mkdir -p "$(dirname "$project_git_dir")"

                                    # .git을 .repo/projects/로 복사
                                    if [ ! -e "$project_git_dir" ]; then
                                        if [ -d "$source_path/.git" ]; then
                                            cp -r "$source_path/.git" "$project_git_dir" 2>/dev/null || true
                                        fi
                                    fi
                                fi

                                break
                            fi
                        fi
                    done

                    # 소스를 찾지 못했을 때 경고만 출력 (빈 디렉토리 생성 안 함)
                    if [ "$source_found" = false ]; then
                        echo "Warning: Source not found for $project_path" >&2
                        ((missing_count++))
                    fi
                fi
            done < "$TEMP_MANIFEST"

            # 임시 파일 삭제
            rm -f "$GIT_MAP_FILE" "$TEMP_MANIFEST"
        fi
    fi
done < "$INCLUDE_MANIFEST"

# manifest 닫기
echo "" >> "$OUTPUT_MANIFEST"
echo "</manifest>" >> "$OUTPUT_MANIFEST"

# 4단계: repo 구조 수동 생성 (repo init 없이)
echo "" >&2
echo "Setting up repo structure..." >&2

cd "$WORK_DIR" || exit 1

# repo tool 복사 (시스템에 설치된 repo 사용)
if [ ! -d ".repo/repo" ]; then
    mkdir -p .repo/repo
    # repo 스크립트의 실제 위치 찾기
    REPO_PATH=$(which repo)
    if [ -n "$REPO_PATH" ]; then
        # repo가 가리키는 실제 repo tool 디렉토리 복사
        REPO_SRC=$(dirname $(readlink -f "$REPO_PATH"))/../.repo/repo
        if [ -d "$REPO_SRC" ]; then
            cp -r "$REPO_SRC"/* .repo/repo/ 2>/dev/null || true
        fi
    fi
fi

# manifests를 git 저장소로 초기화
cd "$MANIFEST_DIR" || exit 1
if [ ! -d ".git" ]; then
    git init -q
    git add default.xml
    git commit -q -m "Initial manifest"
    echo "Git repository created in manifests/" >&2
fi

# .repo/manifest.xml 심볼릭 링크 생성
cd "$REPO_DIR" || exit 1
ln -sf manifests/default.xml manifest.xml 2>/dev/null || true

# 필요한 디렉토리 구조 생성
mkdir -p projects project-objects

# 5단계: 소스 연결은 manifest 생성 시 이미 완료됨 (위의 통합 루프에서 처리)
echo "" >&2
echo "Source linking completed during manifest generation." >&2

# 결과 출력
cd "$WORK_DIR" || exit 1
echo "" >&2
echo "===================================" >&2
echo "Repo initialization completed!" >&2
echo "Repo directory: $REPO_DIR" >&2
echo "Manifest file: $OUTPUT_MANIFEST" >&2
echo "Total lines: $(wc -l < "$OUTPUT_MANIFEST")" >&2
echo "-----------------------------------" >&2
echo "Linked projects: $linked_count" >&2
echo "Skipped (exists): $skipped_count" >&2
echo "Missing sources: $missing_count" >&2
echo "===================================" >&2
echo "" >&2
echo "Directory structure created. Manifest available at:" >&2
echo "  $OUTPUT_MANIFEST" >&2
echo "" >&2
echo "You can now use:" >&2
echo "  repo list - to see all projects" >&2
echo "  repo info - to see project details" >&2
