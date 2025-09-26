#!/bin/bash

LOG="$(dirname "$0")/mcp.log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# jq 필수 체크 - 없으면 에러 종료
command -v jq >/dev/null 2>&1 || {
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"jq not found"},"id":null}'
    log "ERROR: jq not found"
    exit 1
}

# 응답 생성 함수 (jq 항상 사용)
make_response() {
    local result="$1" id="$2" error_code="$3" error_msg="$4"
    if [[ -n $error_code ]]; then
        jq -n --argjson id "$id" --argjson code "$error_code" --arg msg "$error_msg" \
            '{jsonrpc: "2.0", error: {code: $code, message: $msg}, id: $id}'
    else
        jq -n --argjson id "$id" --argjson result "$result" \
            '{jsonrpc: "2.0", result: $result, id: $id}'
    fi
}

# 요청 파싱
IFS= read -r REQ || exit 0
set -- $REQ; METHOD=$1 REQ_PATH=$2
log "Request: $REQ"

## 전체 body의 갯수를 읽는다.
CONTENT_LENGTH=0
while IFS= read -r body; do
    [[ -z "$body" || "$body" == $'\r' ]] && break
    [[ "$body" =~ [Cc]ontent-[Ll]ength:* ]] && CONTENT_LENGTH=${body//[^0-9]/}
done

## HTTP SSE 프로토콜인지 확인한다.
if [[ "$METHOD" == "GET" && "$REQ_PATH" == "/sse" ]]; then
    ## 연결을 알리는 header와 초기 event를 알린다.
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
    printf "event: ready\ndata: {\"status\":\"connected\"}\n\n"

    #keepalive를 10마다 보내면서 대기한다.
    log "SSE opened"
    while :; do sleep 10 && printf ": keepalive $(date +%s)\n\n" || break; done
    log "SSE closed"; exit 0

## HTTP SSE 프로토콜 POST 명령이면
elif [[ "$METHOD" == "POST" && "$REQ_PATH" == "/sse" ]]; then
    # Body 읽기
    body=""
    if (( CONTENT_LENGTH > 0 )); then
        if command -v dd >/dev/null 2>&1; then
            body=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
        else
            # Read byte by byte fallback
            for ((i=0; i<CONTENT_LENGTH; i++)); do
                IFS= read -r -n1 ch || break
                body+="$ch"
            done
        fi
    else
        IFS= read -r body
    fi
    log "Body: $body"

    # JSON parsing하여 method와 id값을 읽어온다.
    method=$(echo "$body" | jq -r '.method // ""')
    id=$(echo "$body" | jq -r '.id // null')
    [[ $(echo "$body" | jq -r '.id | type') == "string" ]] && id="\"$(echo "$body" | jq -r '.id')\""

    # response생성하여 회신한다.
    case "$method" in
          init*) resp=$(jq -n --argjson id "$id" '
                {  jsonrpc: "2.0",
                    result: {
                        capabilities: {
                            prompts: { listChanged: false },
                            resources: { listChanged: false },
                            tools: { listChanged: false }
                        }
                    },
                    id: $id
                }')
        ;; hello)            resp=$(make_response '"world"' "$id")
        ;;  bye )            resp=$(make_response '"what??"' "$id")
        ;; shutdown)         resp=$(make_response 'null' "$id")
        ;;     *)            resp=$(make_response '' "$id" -32601 "Method not found")
    esac

    log "Response: $resp"
    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#resp}\r\n\r\n$resp"
    exit 0
else
    printf "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found\n"
    log "404: $METHOD $REQ_PATH"
fi