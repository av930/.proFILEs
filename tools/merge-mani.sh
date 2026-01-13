#!/bin/bash
# Merge multiple manifest files into one
# Automatically detects manifest files from down.list and merges them

INPUT_FILE="${1:-down.list}"
OUTPUT_MANIFEST="${2:-merged-manifest.xml}"
INCLUDE_MANIFEST="${INPUT_FILE}.xml"
JOB_DIR="result."

echo "Analyzing: $INPUT_FILE" >&2
echo "Include manifest: $INCLUDE_MANIFEST" >&2
echo "Output manifest: $OUTPUT_MANIFEST" >&2

# 1단계: down.list 파일 분석하여 include manifest 생성
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found" >&2
    exit 1
fi

# include manifest 초기화
echo '<?xml version="1.0" encoding="UTF-8"?>' > "$INCLUDE_MANIFEST"
echo '<manifest>' >> "$INCLUDE_MANIFEST"

# down.list에서 블록별로 manifest xml 파일 추출
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
# down.list.xml 생성완료
printf "\e[0;31m [$INCLUDE_MANIFES created]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"


# 2단계: include manifest를 기반으로 최종 병합
echo "" >&2
echo "Merging manifests from: $INCLUDE_MANIFEST" >&2

# XML 헤더와 manifest 시작
cat > "$OUTPUT_MANIFEST" << 'XMLHEAD'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
XMLHEAD

# 모든 include 파일에서 remote 정의 추출
echo "  <!-- Merged remote definitions -->" >> "$OUTPUT_MANIFEST"
while IFS= read -r line; do
    if [[ "$line" =~ \<include.*name=\"([^\"]+)\" ]]; then
        include_file="${BASH_REMATCH[1]}"
        echo "Processing include: $include_file" >&2

        # remote 태그만 추출 (중복 제거를 위해 sort -u)
        if [ -f "$include_file" ]; then
            grep -E '^ *<remote ' "$include_file" 2>/dev/null
        else
            echo "Warning: Include file not found: $include_file" >&2
        fi
    fi
done < "$INCLUDE_MANIFEST" | sort -u >> "$OUTPUT_MANIFEST"

# xml의 default 값은 첫 번째 include 파일것을 사용
echo "" >> "$OUTPUT_MANIFEST"
echo "  <!-- Default definition -->" >> "$OUTPUT_MANIFEST"
first_include=$(grep '<include' "$INCLUDE_MANIFEST" | head -1 | grep -oP 'name="\K[^"]+')
if [ -n "$first_include" ] && [ -f "$first_include" ]; then
    grep -E '^ *<default ' "$first_include" 2>/dev/null >> "$OUTPUT_MANIFEST" || true
fi

# 각 include 파일의 모든 project list 추가
echo "" >> "$OUTPUT_MANIFEST"
while IFS= read -r line; do
    if [[ "$line" =~ \<include.*name=\"([^\"]+)\" ]]; then
        include_file="${BASH_REMATCH[1]}"

        if [ -f "$include_file" ]; then
            echo "" >> "$OUTPUT_MANIFEST"
            echo "  <!-- ==================== Projects from: $include_file ==================== -->" >> "$OUTPUT_MANIFEST"
            # 첫 번째 <project부터 </manifest> 전까지 모든 라인 추출
            sed -n '/<project/,/<\/manifest>/{/<\/manifest>/d; p}' "$include_file" 2>/dev/null >> "$OUTPUT_MANIFEST" || true
        fi
    fi
done < "$INCLUDE_MANIFEST"

# manifest 닫기
echo "" >> "$OUTPUT_MANIFEST"
echo "</manifest>" >> "$OUTPUT_MANIFEST"

# 결과 출력
echo "" >&2
echo "===================================" >&2
echo "Merge completed!" >&2
echo "Include manifest: $INCLUDE_MANIFEST" >&2
echo "Merged manifest: $OUTPUT_MANIFEST" >&2
echo "Total lines: $(wc -l < "$OUTPUT_MANIFEST")" >&2
echo "===================================" >&2
