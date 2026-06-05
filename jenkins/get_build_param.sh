#!/usr/bin/env bash
set -euo pipefail

#----------------------------------------------------------------------------------------------------------
# Jenkins 특정 빌드의 파라미터 값을 조회하여 그대로 출력한다(멀티라인 지원).
# 입력: build URL 또는 parameters URL, 파라미터 이름
# 출력: 해당 파라미터 value (stdout)
#----------------------------------------------------------------------------------------------------------

usage() {
    cat <<-EOF
    usage: $(basename "$0") [-a USER:TOKEN] [-k] <build_or_parameters_url> <param_name>
	    build_or_parameters_url : 예) http://vjenkins.lge.com/jenkins03/job/.../5/
	                             예) http://vjenkins.lge.com/jenkins03/job/.../5/parameters/
	    param_name              : 예) PARAM1
    options:
        -a USER:TOKEN           : Jenkins basic auth (또는 API token). (env: JENKINS_AUTH)
        -k                      : TLS 검증 비활성화(curl -k). 필요 시에만 사용.

	example:
        PARAM1=$($(basename "$0") 'http://vjenkins.lge.com/jenkins03/job/_SFolder_CommonUtility/job/checkStaticSRC_URI/5/parameters/' PARAM1)

	    # curl로 다음 빌드에 멀티라인 파라미터 전달(권장: file 방식)
	    tmp=$(mktemp)
	    $(basename "$0") 'http://.../5/parameters/' PARAM1 >"$tmp"
        curl -X POST 'http://.../buildWithParameters' --data-urlencode "PARAM1@$tmp"
EOF
    exit 1
}

need_cmd() {
    local cmd_name="$1"
    command -v "$cmd_name" >/dev/null 2>&1 || { echo "[FAIL] missing command: $cmd_name" >&2; exit 1; }
}

normalize_build_url() {
    local url="$1"

    url="${url%$'\r'}"
    url="${url%%\?*}"

    case "$url" in
        */parameters/) url="${url%parameters/}" ;;
    esac

    [[ "$url" == */ ]] || url+="/"
    printf '%s' "$url"
}

build_api_url() {
    local build_url="$1"
    printf '%sapi/json?tree=actions[parameters[name,value]]' "$build_url"
}

extract_param_value_from_json() {
    local param_name="$1"

    need_cmd python3

    python3 - "$param_name" <<'PY'
import json
import sys

param = sys.argv[1]

data = json.load(sys.stdin)
for action in data.get("actions", []) or []:
    params = action.get("parameters") if isinstance(action, dict) else None
    if not params:
        continue
    for p in params:
        if not isinstance(p, dict):
            continue
        if p.get("name") != param:
            continue
        v = p.get("value")
        if v is None:
            sys.exit(2)
        if isinstance(v, bool):
            sys.stdout.write("true\n" if v else "false\n")
        else:
            sys.stdout.write(str(v))
            if not str(v).endswith("\n"):
                sys.stdout.write("\n")
        sys.exit(0)

sys.exit(3)
PY
}

main() {
    local auth="${JENKINS_AUTH:-}"
    local curl_k=""
    local build_or_params_url="${1:-}"
    local param_name="${2:-}"
    local build_url api_url

    while getopts ":a:kh" opt; do
        case "$opt" in
            a) auth="$OPTARG" ;;
            k) curl_k="-k" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
    shift $((OPTIND - 1))

    build_or_params_url="${1:-}"
    param_name="${2:-}"

    [[ -n "$build_or_params_url" && -n "$param_name" ]] || usage

    need_cmd curl

    build_url="$(normalize_build_url "$build_or_params_url")"
    api_url="$(build_api_url "$build_url")"

    if [[ -n "$auth" ]]; then
        curl $curl_k -f -sS -u "$auth" "$api_url" | extract_param_value_from_json "$param_name"
    else
        curl $curl_k -f -sS "$api_url" | extract_param_value_from_json "$param_name"
    fi
}

main "$@"
