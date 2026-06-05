#!/usr/bin/env bash
set -euo pipefail

#----------------------------------------------------------------------------------------------------------
# Yocto SRC_URI 한 줄(URI;md5sum=...;sha256sum=...)을 입력받아 다운로드/접근 가능 여부를 확인한다.
# 입력: 멀티라인 문자열 1개, 또는 라인별 인자 여러 개, 또는 '-'(stdin)
# 출력: 라인별 OKAY/FAIL 요약 및 전체 결과 코드(성공 0 / 실패 1)
#----------------------------------------------------------------------------------------------------------

TMP_DIR=""
LOG_FILE=""

log_raw() {
    local msg="$1"
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$msg" >>"$LOG_FILE"
}

log_blank() {
    [[ -n "${LOG_FILE:-}" ]] && printf '\n' >>"$LOG_FILE"
}

run_logged() {
    local -a cmd=("$@")
    local rc

    [[ -n "${LOG_FILE:-}" ]] || { "${cmd[@]}"; return $?; }

    {
        printf '[CMD]'
        printf ' %q' "${cmd[@]}"
        printf '\n'
    } >>"$LOG_FILE"

    "${cmd[@]}" >>"$LOG_FILE" 2>&1
    rc=$?
    printf '[RC ] %d\n' "$rc" >>"$LOG_FILE"
    return "$rc"
}

record_result() {
    local status="$1" uri="$2" msg="$3"
    log_raw "[$status] $uri ($msg)"
}

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
                log_raw "[INFO] download attempt=$attempt/$max_attempts uri=$uri"
                if run_logged curl -L -f -sS \
                    --connect-timeout "$connect_timeout" \
                    --max-time "$max_time" \
                    -o "$out_file" "$uri"; then
                    return 0
                fi

                [[ "$attempt" -lt "$max_attempts" ]] && { log_raw "[INFO] retry after ${delay}s"; sleep "$delay"; delay=$((delay * 2)); } || true
            done
            return 1
        ;;
        file)
            local src_path
            src_path="${uri#file://}"
            [[ "$src_path" == /* ]] || src_path="/$src_path"
            [[ -f "$src_path" ]] || { log_raw "[ERR ] file not found: $src_path"; return 1; }
            run_logged cp -f "$src_path" "$out_file"
        ;;
        git)
            need_cmd git
            run_logged git ls-remote -q "$uri" HEAD || return 1
            printf '%s' "__GIT_ONLY__" >"$out_file"
        ;;
        *)
            log_raw "[ERR ] unsupported scheme: $uri"
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

print_summary_from_log() {
    local log_path="$1"

    [[ -f "$log_path" ]] || { echo "[FAIL] log not found: $log_path" >&2; return 1; }

    awk -v LOG_PATH="$log_path" '
        function scheme_of(uri,    m, s) {
            if (match(uri, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//)) {
                s = substr(uri, 1, RLENGTH)
                sub(/:\/\//, "", s)
                return s
            }
            return "unknown"
        }

        /^\[OKAY\] / {
            uri = $2
            ok[++ok_n] = $0
            total++
            ok_cnt++
            sch = scheme_of(uri)
            prot_total[sch]++
            prot_ok[sch]++
            next
        }

        /^\[FAIL\] / {
            uri = $2
            fail[++fail_n] = $0
            total++
            fail_cnt++
            sch = scheme_of(uri)
            prot_total[sch]++
            prot_fail[sch]++
            next
        }

        END {
            for (i = 1; i <= ok_n; i++)  printf "OKAY %d: %s\n",  i, ok[i]
            for (i = 1; i <= fail_n; i++) printf "FAIL %d: %s\n", i, fail[i]

            printf "STAT total=%d OKAY=%d FAIL=%d log=%s\n", total+0, ok_cnt+0, fail_cnt+0, LOG_PATH

            n = 0
            for (s in prot_total) prot_list[++n] = s
            for (i = 1; i <= n; i++) {
                for (j = i + 1; j <= n; j++) {
                    if (prot_list[i] > prot_list[j]) {
                        tmp = prot_list[i]; prot_list[i] = prot_list[j]; prot_list[j] = tmp
                    }
                }
            }
            for (i = 1; i <= n; i++) {
                s = prot_list[i]
                printf "STAT protocol=%s total=%d OKAY=%d FAIL=%d\n", s, prot_total[s]+0, prot_ok[s]+0, prot_fail[s]+0
            }
        }
    ' "$log_path"
}

main() {
    local -a entries=()
    local num_total num_ok num_fail
    local build_no_safe

    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

    build_no_safe="${BUILD_NUMBER:-local}"
    LOG_FILE="/tmp/checkStaticSRC_URI-${build_no_safe}.log"
    : >"$LOG_FILE"

    TMP_DIR="$(mktemp -d)"
    trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"' EXIT

    log_raw "[INFO] start time=$(date '+%Y-%m-%d %H:%M:%S')"
    log_raw "[INFO] build_number=${BUILD_NUMBER:-}"
    log_raw "[INFO] log_file=$LOG_FILE"
    log_raw "[INFO] tmp_dir=$TMP_DIR"
    log_blank

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
            record_result FAIL "$uri" "download failed"
            num_fail=$((num_fail + 1))
            continue
        fi

        if [[ "$scheme" == "git" ]]; then
            record_result OKAY "$uri" "git reachable"
            num_ok=$((num_ok + 1))
            continue
        fi

        [[ -s "$out_file" ]] || { record_result FAIL "$uri" "empty file"; num_fail=$((num_fail + 1)); continue; }

        status_msg=""

        if [[ -n "$expected_md5" ]]; then
            actual_md5="$(checksum_md5 "$out_file")"
            log_raw "[INFO] md5sum expected=$expected_md5 actual=$actual_md5 uri=$uri"
            [[ "$actual_md5" == "$expected_md5" ]] && status_msg+="md5 OK" || status_msg+="md5 MISMATCH"
        fi

        if [[ -n "$expected_sha256" ]]; then
            actual_sha256="$(checksum_sha256 "$out_file")"
            log_raw "[INFO] sha256sum expected=$expected_sha256 actual=$actual_sha256 uri=$uri"
            [[ -n "$status_msg" ]] && status_msg+=", "
            [[ "$actual_sha256" == "$expected_sha256" ]] && status_msg+="sha256 OK" || status_msg+="sha256 MISMATCH"
        fi

        if [[ -z "$expected_md5" && -z "$expected_sha256" ]]; then
            record_result OKAY "$uri" "downloaded"
            num_ok=$((num_ok + 1))
            continue
        fi

        if [[ "$status_msg" == *MISMATCH* ]]; then
            record_result FAIL "$uri" "$status_msg"
            [[ -n "$expected_md5" ]] && log_raw "       expected md5: $expected_md5"
            [[ -n "${actual_md5:-}" ]] && log_raw "         actual md5: ${actual_md5:-}"
            [[ -n "$expected_sha256" ]] && log_raw "    expected sha256: $expected_sha256"
            [[ -n "${actual_sha256:-}" ]] && log_raw "      actual sha256: ${actual_sha256:-}"
            num_fail=$((num_fail + 1))
        else
            record_result OKAY "$uri" "$status_msg"
            num_ok=$((num_ok + 1))
        fi

        log_blank
    done

    log_raw "[INFO] end time=$(date '+%Y-%m-%d %H:%M:%S')"
    log_raw "[INFO] total=$num_total ok=$num_ok fail=$num_fail"

    print_summary_from_log "$LOG_FILE"

    [[ "$num_fail" -eq 0 ]] && return 0 || return 1
}

main "$@"
