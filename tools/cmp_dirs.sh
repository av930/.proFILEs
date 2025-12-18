#!/bin/bash
# 사용법: P1=<dir1|file1|str1> P2=<dir2|file2|str2> EXCEPT=<path1;path2> cmp_dir.sh <mode:1|2|3>
# 또는:  EXCEPT=<path1;path2> cmp_dir.sh <dir1|file1|str1> <dir2|file2|str2> <mode:1|2|3>

# 환경변수 우선, 없으면 인자 사용
dir1="${P1:-$1}"; dir2="${P2:-$2}"; except_paths="${EXCEPT:-}"

# PATH1/PATH2가 설정되어 있으면 $1을 mode로 사용
mode="${3:-$1}"  # PATH1/PATH2 사용시 $1이 mode
[[ -n "$P1" && -n "$P2" ]] && mode="$1"

# EXCEPT 경로 처리 (세미콜론으로 구분)
find_exclude=""
if [[ -n "$except_paths" ]]; then
    IFS=';' read -ra PATHS <<< "$except_paths"
    for path in "${PATHS[@]}"; do
        find_exclude+=" -not -path '*/${path}/*' -not -path '*/${path}'"
    done
fi

file1=$(mktemp); file2=$(mktemp)

# dir1이 파일이면 cat, 디렉터리면 find, 문자열 데이터면 직접 사용
if   [[ -f "$dir1" ]] && [[ -f "$dir2" ]]; then
	cat "$dir1" | sort > "$file1"
	cat "$dir2" | sort > "$file2"
elif [[ -d "$dir1" ]] && [[ -d "$dir2" ]]; then
	# EXCEPT 경로를 제외하고 find
	(cd "$dir1" && eval "find . $find_exclude | sort") > "$file1"
	(cd "$dir2" && eval "find . $find_exclude | sort") > "$file2"
elif [[ -n "$dir1" ]] && [[ -n "$dir2" ]]; then
	# 문자열 데이터로 처리 (P1, P2가 명령 결과일 경우)
	sort <<<"$dir1" > "$file1"
	sort <<<"$dir2" > "$file2"
else
    echo "input valid file, dir, or data in both: $dir1"
	rm -f "$file1" "$file2"; exit 1
fi

tmpout=$(mktemp)
case "$mode" in
 	  1) comm -23 "$file1" "$file2" | tee "$tmpout"
	     echo "=========================================="
	     echo "[P1 only item: $(wc -l < "$tmpout")]"
	;;2) comm -13 "$file1" "$file2" | tee "$tmpout"
	     echo "=========================================="
	     echo "[P2 only item: $(wc -l < "$tmpout")]"
	;;3) comm -12 "$file1" "$file2" | tee "$tmpout"
	     echo "=========================================="
	     echo "[common item: $(wc -l < "$tmpout")]"
	;;*) echo "Usage: EXCEPT=<path1;path2> P1=<dir1|file1|str1> P2=<dir2|file2|str2> cmp_dir.sh <mode:1|2|3>"
	     echo "   or: EXCEPT=<path1;path2> cmp_dir.sh <dir1|file1|str1> <dir2|file2|str2> <mode:1|2|3>"
esac
if cmp "$file1" "$file2"; then result=0; else result=1; fi
rm -f "$file1" "$file2" "$tmpout"
exit $result


