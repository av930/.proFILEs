#!/usr/bin/env bash
set -euo pipefail

#----------------------------------------------------------------------------------------------------------
# Yocto SRC_URI 한 줄(URI;md5sum=...;sha256sum=...)을 입력받아 다운로드/접근 가능 여부를 확인한다.
# 입력: 멀티라인 문자열 1개, 또는 라인별 인자 여러 개, 또는 '-'(stdin)
# 출력: 라인별 OKAY/FAIL 요약 및 전체 결과 코드(성공 0 / 실패 1)
#----------------------------------------------------------------------------------------------------------

TMP_DIR=""

usage() {
    cat <<-EOF
	usage: $(basename "$0") <URInCHECKSUM... | MULTILINE | ->
	    URInCHECKSUM : One line per entry.
	                  Format: <URI>[;md5sum=<hex>][;sha256sum=<hex>][;...]
	                  Allowed schemes: http, https, ftp, file, git
	    MULTILINE    : A single argument that contains multiple lines (\n separated)
	    -            : Read lines from stdin

	example:
	    URInCHECKSUM=$'https://example.com/a.tar.gz;sha256sum=...\nfile:///tmp/b.zip;md5sum=...'
	    $(basename "$0") "$URInCHECKSUM"

	    $(basename "$0") \
	      'https://example.com/a.patch;md5sum=deadbeef...' \
	      'git://example.com/repo.git'

	    printf '%s\n' 'ftp://example.com/a.bin;sha256sum=...' | $(basename "$0") -

	output:
	    [OKAY] <uri> (md5 OK, sha256 OK)
	    [FAIL] <uri> (download failed)
EOF
    exit 1
}

need_cmd() {
    local cmd_name="$1"
    command -v "$cmd_name" >/dev/null 2>&1 || { echo "[FAIL] missing command: $cmd_name" >&2; exit 1; }
}

trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

split_input_lines() {
    local -a out_lines=()

    if [[ $# -eq 0 ]]; then
        mapfile -t out_lines
    elif [[ $# -eq 1 && "$1" == "-" ]]; then
        mapfile -t out_lines
    elif [[ $# -eq 1 ]]; then
        mapfile -t out_lines <<<"$1"
    else
        out_lines=("$@")
    fi

    printf '%s\n' "${out_lines[@]}"
}

parse_entry() {
    local raw_line="$1"
    local cleaned uri rest part expected_md5 expected_sha256
    local -a parts=()

    cleaned="$(trim_ws "$raw_line")"
    [[ -z "$cleaned" ]] && return 2
    [[ "$cleaned" == \#* ]] && return 2

    IFS=';' read -r -a parts <<<"$cleaned"
    uri="$(trim_ws "${parts[0]}")"

    expected_md5=""
    expected_sha256=""

    for part in "${parts[@]:1}"; do
        part="$(trim_ws "$part")"
        case "$part" in
            md5sum=*)    expected_md5="${part#md5sum=}" ;;
            sha256sum=*) expected_sha256="${part#sha256sum=}" ;;
        esac
    done

    printf '%s\037%s\037%s\n' "$uri" "$expected_md5" "$expected_sha256"
}

scheme_of() {
    local uri="$1"
    case "$uri" in
        http://*)  echo "http" ;;
        https://*) echo "https" ;;
        ftp://*)   echo "ftp" ;;
        file://*)  echo "file" ;;
        git://*)   echo "git" ;;
        *)         echo "" ;;
    esac
}

download_to() {
    local uri="$1" out_file="$2"
    local scheme

    scheme="$(scheme_of "$uri")"
    case "$scheme" in
        http|https|ftp)
            need_cmd curl
            local max_attempts attempt delay connect_timeout max_time
            max_attempts="${CURL_RETRY_MAX:-3}"
            connect_timeout="${CURL_CONNECT_TIMEOUT:-10}"
            max_time="${CURL_MAX_TIME:-120}"
            delay=1

            for ((attempt=1; attempt<=max_attempts; attempt++)); do
                if curl -L -f -sS \
                    --connect-timeout "$connect_timeout" \
                    --max-time "$max_time" \
                    -o "$out_file" "$uri"; then
                    return 0
                fi

                [[ "$attempt" -lt "$max_attempts" ]] && { sleep "$delay"; delay=$((delay * 2)); } || true
            done
            return 1
        ;;
        file)
            local src_path
            src_path="${uri#file://}"
            [[ "$src_path" == /* ]] || src_path="/$src_path"
            [[ -f "$src_path" ]] || { echo "[FAIL] file not found: $src_path" >&2; return 1; }
            cp -f "$src_path" "$out_file"
        ;;
        git)
            need_cmd git
            git ls-remote -q "$uri" HEAD >/dev/null
            printf '%s' "__GIT_ONLY__" >"$out_file"
        ;;
        *)
            echo "[FAIL] unsupported scheme: $uri" >&2
            return 1
        ;;
    esac
}

checksum_md5() {
    local file_path="$1"
    need_cmd md5sum
    md5sum "$file_path" | awk '{print $1}'
}

checksum_sha256() {
    local file_path="$1"
    need_cmd sha256sum
    sha256sum "$file_path" | awk '{print $1}'
}

main() {
    local -a entries=()
    local num_total num_ok num_fail

    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

    TMP_DIR="$(mktemp -d)"
    trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"' EXIT

    mapfile -t entries < <(split_input_lines "$@")
    [[ "${#entries[@]}" -gt 0 ]] || usage

    num_total=0
    num_ok=0
    num_fail=0

    for entry in "${entries[@]}"; do
        local uri expected_md5 expected_sha256
        local scheme file_name out_file
        local actual_md5 actual_sha256
        local status_msg

        if ! IFS=$'\037' read -r uri expected_md5 expected_sha256 < <(parse_entry "$entry"); then
            continue
        fi

        num_total=$((num_total + 1))
        scheme="$(scheme_of "$uri")"

        file_name="$(basename "${uri%%\?*}")"
        [[ -n "$file_name" && "$file_name" != "/" ]] || file_name="download_${num_total}"
        out_file="$TMP_DIR/$file_name"

        if ! download_to "$uri" "$out_file"; then
            echo "[FAIL] $uri (download failed)"
            num_fail=$((num_fail + 1))
            continue
        fi

        if [[ "$scheme" == "git" ]]; then
            echo "[OKAY] $uri (git reachable)"
            num_ok=$((num_ok + 1))
            continue
        fi

        [[ -s "$out_file" ]] || { echo "[FAIL] $uri (empty file)"; num_fail=$((num_fail + 1)); continue; }

        status_msg=""

        if [[ -n "$expected_md5" ]]; then
            actual_md5="$(checksum_md5 "$out_file")"
            [[ "$actual_md5" == "$expected_md5" ]] && status_msg+="md5 OK" || status_msg+="md5 MISMATCH"
        fi

        if [[ -n "$expected_sha256" ]]; then
            actual_sha256="$(checksum_sha256 "$out_file")"
            [[ -n "$status_msg" ]] && status_msg+=", "
            [[ "$actual_sha256" == "$expected_sha256" ]] && status_msg+="sha256 OK" || status_msg+="sha256 MISMATCH"
        fi

        if [[ -z "$expected_md5" && -z "$expected_sha256" ]]; then
            echo "[OKAY] $uri (downloaded)"
            num_ok=$((num_ok + 1))
            continue
        fi

        if [[ "$status_msg" == *MISMATCH* ]]; then
            echo "[FAIL] $uri ($status_msg)"
            [[ -n "$expected_md5" ]] && echo "       expected md5: $expected_md5"
            [[ -n "${actual_md5:-}" ]] && echo "         actual md5: ${actual_md5:-}"
            [[ -n "$expected_sha256" ]] && echo "    expected sha256: $expected_sha256"
            [[ -n "${actual_sha256:-}" ]] && echo "      actual sha256: ${actual_sha256:-}"
            num_fail=$((num_fail + 1))
        else
            echo "[OKAY] $uri ($status_msg)"
            num_ok=$((num_ok + 1))
        fi
    done

    echo "[INFO] total=$num_total ok=$num_ok fail=$num_fail"
    [[ "$num_fail" -eq 0 ]] && return 0 || return 1
}

main "$@"
