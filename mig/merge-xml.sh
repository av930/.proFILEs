#!/bin/bash -e
# merge-xml.sh - Manifest Path/Remote 주입 스크립트
#
# Purpose:
#   new 소스의 manifest에 ori(구형) 소스의 git name을 path로 강제 주입하여 gen-fin.xml을 생성합니다.
#   이를 통해 new 소스를 ori의 git 저장소 구조에 맞게 remote에 push할 수 있도록 준비합니다.
#
# Features:
#   - Suffix 매칭: ori의 git name이 new의 git name을 suffix로 포함하면 동일 git으로 판별
#   - Prefix 제거: new git name에서 지정한 prefix 문자열을 제거한 후 매칭 수행
#   - 최장 매칭 우선: 복수 매칭 시 가장 긴 ori name 선택
#   - Remote 블록 교체: gen-fin.xml의 remote 정의를 ori의 remote 블록으로 교체
#   - 결과 보고: Matched / Not matched / Duplicated 통계 및 미매칭·중복 목록 출력
#
# Usage:
#   merge-xml.sh <ori.xml> <new.xml> [prefix1 prefix2 ...]
#
# Arguments:
#   ori.xml    - 기존 소스의 manifest (path/remote 구조 기준)
#   new.xml    - 신규 소스의 manifest (project name만 있음)
#   prefix...  - new의 project name에서 제거할 prefix 문자열 목록 (선택)
#
# Output:
#   gen-fin.xml - new.xml 기반에 ori의 path/remote가 주입된 최종 manifest
#
# Example:
#   merge-xml.sh .repo/manifests/default.xml new-manifest.xml
#   merge-xml.sh ori.xml new.xml sa525m-le-3-1_

FILE_ORI="$1"
FILE_NEW="$2"
FILE_FIN="gen-fin.xml"

[[ -z "$FILE_ORI" || -z "$FILE_NEW" ]] && { echo "Error: Usage: $0 <ori.xml> <new.xml> [prefix...]"; exit 1; }
[[ ! -f "$FILE_ORI" || ! -f "$FILE_NEW" ]] && { echo "Error: File not found"; exit 1; }

declare -a remove_prefixes=("${@:3}")

# ori 파일에서 name 로드 (name->used count 매핑) 및 remote 정보 추출
declare -A ori_names
declare -A ori_remotes
while IFS='`' read -r name remote; do
    [[ -z "$name" ]] && continue
    [[ -z "$remote" ]] && { echo "Error: project '$name' has no remote attribute in $FILE_ORI"; exit 1; }
    ori_names["$name"]=0
    ori_remotes["$name"]="$remote"
# ori 파일의 모든 project 요소에서 name과 remote 속성을 백틱으로 구분하여 추출
done < <(xmlstarlet sel -t -m "//project" -v "@name" -o '`' -v "@remote" -n "$FILE_ORI" 2>/dev/null)

# new 파일 복사 및 path 속성 삭제
cp "$FILE_NEW" "$FILE_FIN"
# 모든 project 요소의 path 속성을 삭제 (match된 것만 나중에 추가)
xmlstarlet ed --inplace -d "//project/@path" "$FILE_FIN" 2>/dev/null || true

# 통계
matched=0
not_matched=0

# new 파일의 각 project에 대해서
# 위에서 ori에서 추출한 모든 name과 path를 배열중 name 문자열과 뒷에서부터 비교하여
# ori git name이 new git name을 포함하고 있다면(즉, 같은 git이라면), new path name을 ori git name으로 변경한다.
# 이후 repo forall REPO_PATH 변수를 사용하여 remote에 push하기 위해서...
line_num=0
while IFS='`' read -r new_name; do
    line_num=$((line_num + 1))
    # prefix 제거
    stripped_name="$new_name"
    for prefix in "${remove_prefixes[@]}"; do
        stripped_name="${stripped_name//$prefix/}"
    done
    stripped_name="${stripped_name#/}"
    stripped_name="${stripped_name%/}"

    # ori에서 뒤에서부터 매칭 (가장 긴 suffix)
    found=0
    best_ori_name=""
    best_len=0

    for ori_name in "${!ori_names[@]}"; do
        # ori_name이 stripped_name을 포함하는지 (suffix로)
        if [[ "$ori_name" == *"$stripped_name" ]]; then
            prefix_part="${ori_name%"$stripped_name"}"
            # 경로 구분자 확인: prefix가 없거나 /로 끝나면 유효
            if [[ -z "$prefix_part" || "$prefix_part" == */ ]]; then
                # 가장 긴 매칭 선택
                if [[ ${#ori_name} -gt $best_len ]]; then
                    best_ori_name="$ori_name"
                    best_len=${#ori_name}
                    found=1
                fi
            fi
        fi
    done

    # path 및 remote 추가
    if [[ $found -eq 1 ]]; then
        best_remote="${ori_remotes[$best_ori_name]}"
        # 매칭된 project 요소에 path와 remote 속성을 추가 (값은 ori의 name과 remote)
        sed -i "s|<project name=\"$new_name\"|<project name=\"$new_name\" path=\"$best_ori_name\" remote=\"$best_remote\"|" "$FILE_FIN"
        ori_names["$best_ori_name"]=$((ori_names["$best_ori_name"] + 1))
        matched=$((matched + 1))
    else
        not_matched=$((not_matched + 1))
    fi
# new 파일의 모든 project 요소에서 name 속성을 추출
done < <(xmlstarlet sel -t -m "//project" -v "@name" -n "$FILE_NEW" 2>/dev/null)

# duplicated 개수 계산
duplicated=0
for name in "${!ori_names[@]}"; do
    [[ ${ori_names[$name]} -ge 2 ]] && duplicated=$((duplicated + 1))
done

# 결과 출력
echo "=== Completed ==="
echo "Input: $FILE_NEW, Compare: $FILE_ORI, Output: $FILE_FIN"
echo "Matched: $matched, Not matched: $not_matched, Duplicated: $duplicated"

# FILE_FIN의 <remote> 라인을 ori의 <remote> 라인으로 교체
tmp_file=$(mktemp)
ori_remote_block=$(grep '\s*<remote ' "$FILE_ORI" || true)
sed '/^\s*<remote /d' "$FILE_FIN" > "$tmp_file"
# <manifest> 여는 태그 바로 다음에 ori의 remote 라인 삽입
awk -v remotes="$ori_remote_block" '
    /<manifest>/ { print; print remotes; next }
    { print }
' "$tmp_file" > "$FILE_FIN"
rm -f "$tmp_file"

if [[ $not_matched -gt 0 ]]; then
    echo ""
    echo "=== Not Matched List ==="
    grep -n --color=always '<project' "$FILE_FIN" | grep -v 'path='
fi

if [[ $duplicated -gt 0 ]]; then
    echo ""
    echo "=== Duplicated List ==="
    for name in "${!ori_names[@]}"; do
        if [[ ${ori_names[$name]} -ge 2 ]]; then
            echo "$name: used ${ori_names[$name]} times"
            grep -n --color=always "path=\"$name\"" "$FILE_FIN"
        fi
    done
fi
