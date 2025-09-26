#!/bin/bash
LOG="$(dirname "$0")/mcp_improve.log"
TEMP_DIR="/tmp/mcp_$$"
response_file="$TEMP_DIR/response.json"
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# jq 필수 체크 - 없으면 에러 종료
command -v jq >/dev/null 2>&1 || {
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"jq not found"},"id":null}'
    exit 1
}

# 응답 파일 생성 함수
make_response() {
    local result="$1" id="$2" error_code="$3" error_msg="$4"
    if [[ -n $error_code ]]; then
        jq -n --argjson id "$id" --argjson code "$error_code" --arg msg "$error_msg" \
            '{jsonrpc: "2.0", error: {code: $code, message: $msg}, id: $id}' > "$response_file"
    else
        jq -n --argjson id "$id" --argjson result "$result" \
            '{jsonrpc: "2.0", result: $result, id: $id}' > "$response_file"
    fi
}

# HTTP 응답 전송 함수
send_response() {
    local size content_file="$1" content_type="${2:-application/json}"
    size=$(wc -c < "$content_file")
    printf "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n" "$content_type" "$size"
    cat "$content_file"
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
        true > "$LOG" # SSE 연결이 열릴 때마다 로그 파일 삭제
        {   printf "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            printf "event: ready\\ndata: {\"status\":\"connected\"}\n\n"
        } | tee "$TEMP_DIR/sse_response"
        log "SSE opened"
        # 15초마다 keepalive 전송 (확장 프로그램이 연결 지속을 인지하도록)
        while sleep 15; do printf ": keepalive %s\n\n" "$(date +%s)" || break; done
        log "SSE closed"
        ;;

    "POST:/sse") ## HTTP SSE 프로토콜 POST 명령이면
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
            initialize|notifications)
                # 표준 initialize 응답: serverInfo 포함 / capabilities 명확화
                jq -n --argjson id "$id" '{
                    jsonrpc: "2.0",
                    result: {
                        serverInfo: { name: "bash-mcp-server", version: "0.1.0" },
                        capabilities: {
                            tools: { listChanged: true },
                            resources: { listChanged: true },
                            prompts: { listChanged: false }
                        }
                    },
                    id: $id
                }' > "$response_file"
            ;; tools/list)
                jq -n --argjson id "$id" '{
                    jsonrpc: "2.0",
                    result: {
                        tools: [
                            {
                                name: "hello-tool",
                                description: "Return a greeting (optionally with a name)",
                                inputSchema: {
                                    type: "object",
                                    properties: { name: { type: "string", description: "Optional name" } },
                                    required: []
                                }
                            },
                            {
                                name: "bye-tool",
                                description: "Return a bye message",
                                inputSchema: { type: "object", properties: {}, required: [] }
                            }
                        ]
                    },
                    id: $id
                }' > "$response_file"
            ;; resources/list)
                jq -n --argjson id "$id" '{
                    jsonrpc: "2.0",
                    result: { resources: [ { uri: "file:///example", name: "Example", description: "Example resource", mimeType: "text/plain" } ] },
                    id: $id
                }' > "$response_file"
            ;; resources/read)
                uri=$(echo "$body" | jq -r '.params.uri // empty')
                if [[ "$uri" == "file:///example" ]]; then
                    jq -n --argjson id "$id" --arg uri "$uri" '{jsonrpc:"2.0", result:{ contents:[ { uri:$uri, mimeType:"text/plain", text:"This is example resource content" } ] }, id:$id}' > "$response_file"
                else
                    jq -n --argjson id "$id" --arg uri "$uri" '{jsonrpc:"2.0", error:{code:-32602, message:("Resource not found: " + $uri)}, id:$id}' > "$response_file"
                fi
            ;; prompts/list)
                jq -n --argjson id "$id" '{
                    jsonrpc: "2.0",
                    result: { prompts: [] },
                    id: $id
                }' > "$response_file"
            ;; shutdown) make_response 'null' "$id" '' ''
            ;; tools/call)
                # VS Code uses .params.name, but also support .params.tool for compatibility
                tool_name=$(echo "$body" | jq -r '.params.name // .params.tool // empty')
                case "$tool_name" in
                    hello-tool)
                        # VS Code uses .params.arguments.name, also support .params.input.name
                        person=$(echo "$body" | jq -r '.params.arguments.name // .params.input.name // empty')
                        [[ -n $person ]] && msg="Hello, $person" || msg="Hello"
                        jq -n --argjson id "$id" --arg msg "$msg" '{jsonrpc:"2.0", result:{content:[{type:"text", text:$msg}]}, id:$id}' > "$response_file"
                        ;;
                    bye-tool)
                        jq -n --argjson id "$id" '{jsonrpc:"2.0", result:{content:[{type:"text", text:"what??"}]}, id:$id}' > "$response_file"
                        ;;
                    *)
                        jq -n --argjson id "$id" --arg tn "$tool_name" '{jsonrpc:"2.0", error:{code:-32602, message:("Unknown tool: " + $tn)}, id:$id}' > "$response_file"
                        ;;
                esac
            ;; *)       make_response '' "$id" -32601 "Method not found" ;;
        esac

        log "Response: $(cat "$response_file")"
        send_response "$response_file"
        ;;

    *)
        echo "Not found" > "$TEMP_DIR/error.txt"
        send_response "$TEMP_DIR/error.txt" "text/plain"
        log "404: $METHOD $REQ_PATH"
        ;;
esac