#!/bin/bash

TEMP_DIR="/tmp/bash-mcp"
F_LOG="$TEMP_DIR/mcp_$$.log"
F_RES="$TEMP_DIR/res_$$.json"

log() { echo "[$(date '+%F %T')] $*" >> "$F_LOG"; }

# 응답 파일 생성 함수
make_response() {
    local result="$1" id="$2" error_code="$3" error_msg="$4"
    if [[ -n $error_code ]];
    then jq -n --argjson id "$id" --argjson code "$error_code" --arg msg "$error_msg" \
         '{jsonrpc: "2.0", error: {code: $code, message: $msg}, id: $id}' > "$F_RES"
    else jq -n --argjson id "$id" --argjson result "$result" \
         '{jsonrpc: "2.0", result: $result, id: $id}' > "$F_RES"
    fi
}

# HTTP 응답 전송 함수
send_response() {
    local size content_file="$1" content_type="${2:-application/json}"
    size=$(wc -c < "$content_file")
    printf "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n" "$content_type" "$size"
    cat "$content_file"
}

# MCP 메서드 처리 함수들
handle_initialize() {
    local id="$1"
    jq -n --argjson id "$id" '{
        jsonrpc: "2.0",
        result: {   serverInfo:   { name : "bash-mcp", version: "0.1.0" },
                    capabilities: { tools: { listChanged: true }        }
               },
        id: $id
    }' > "$F_RES"
}

handle_tools_unknown() {
    local id="$1"
    make_response '' "$id" -32601 "Method not found"
}



################################################ main ################################################
# jq 필수 체크 - 없으면 에러 종료
command -v jq >/dev/null 2>&1 || {
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"jq not found"},"id":null}'
    exit 1
}

# 요청 파싱
read -r REQ || exit 0
set -- $REQ; METHOD=$1 REQ_PATH=$2
log "Request: $REQ"

# 헤더에서 Content-Length 추출
CONTENT_LENGTH=0
while read -r body; do
    [[ -z "$body" || "$body" == $'\r' ]] && break
    [[ "$body" =~ [Cc]ontent-[Ll]ength:* ]] && CONTENT_LENGTH=${body//[^0-9]/}
done

# 라우팅 처리
case "$METHOD:$REQ_PATH" in
    "GET:/sse") ## HTTP SSE 프로토콜인지 확인한다.
        true > "$F_LOG" # SSE 연결이 열릴 때마다 로그 파일 삭제
        {   printf "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            printf "event: ready\\ndata: {\"status\":\"connected\"}\n\n"
        } | tee "$TEMP_DIR/sse_response"
        log "SSE opened"
        # 15초마다 keepalive 전송 (확장 프로그램이 연결 지속을 인지하도록)
        while sleep 15; do printf ": keepalive %s\n\n" "$(date +%s)" || break; done
        log "SSE closed"

    ;; "POST:/sse") ## HTTP SSE 프로토콜 POST 명령이면
        #Body 읽되, 크기가 있으면 크기만큼 없으면 한줄만 읽기.
        if (( CONTENT_LENGTH > 0 )); then
            body=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null || {
                for ((i=0; i<CONTENT_LENGTH; i++)); do
                    read -r -n1 ch || break; echo -n "$ch"
                done
            })
        else
            read -r body
        fi
        log "Body: $body"

        # JSON parsing하여 method와 id값을 읽어온다.
        method=$(echo "$body" | jq -r '.method // ""')
        id=$(echo "$body" | jq -r '.id // null')
        [[ $(echo "$body" | jq -r '.id | type') == "string" ]] && id="\"$(echo "$body" | jq -r '.id')\""

        # response생성하여 회신한다.
        case "$method" in
            initialize|notifications)   handle_initialize       "$id"
            ;; tools/list)              handle_tools_list       "$id"
            ;; tools/call)              handle_tools_call       "$id" "$body"
            ;;          *)              handle_tools_unknown    "$id"
        esac
        log "Response: $(cat "$F_RES")"
        send_response "$F_RES"

    ;; *)
        echo "Not found" > "$TEMP_DIR/error.txt"
        send_response "$TEMP_DIR/error.txt" "text/plain"
        log "404: $METHOD $REQ_PATH"
        ;;
esac