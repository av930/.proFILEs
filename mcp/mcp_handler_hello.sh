#!/bin/bash

# tool 함수들을 먼저 정의
handle_tools_list() {
    local id="$1"
    jq -n --argjson id "$id" '{
        jsonrpc: "2.0",
        result: {
            tools: [
                {   name: "hello-tool",
                    description: "Return a greeting (optionally with a name)",
                    inputSchema: {  type: "object",
                                    properties: { name: { type: "string", description: "Optional name" } },
                                    required: []  }
                },
                {   name: "bye-tool",
                    description: "Return a bye message",
                    inputSchema: { type: "object", properties: {}, required: [] }
                }
            ]
        },
        id: $id
    }' > "$F_RES"
}

# tool handler 정의
handle_tools_call() {
    local tool_name id="$1" body="$2"
    tool_name=$(echo "$body" | jq -r '.params.name // .params.tool // empty')

    case "$tool_name" in
          hello-tool)   handle_THello "$id" "$body"
        ;;  bye-tool)   handle_TBye "$id"
        ;;         *)   handle_TEtc "$id" "$tool_name"
    esac
}

# tool function 정의
handle_THello() {
    local msg person id="$1" body="$2"
    person=$(echo "$body" | jq -r '.params.arguments.name // .params.input.name // empty')
    [[ -n $person ]] && msg="Hello, $person" || msg="Hello"
    jq -n --argjson id "$id" --arg msg "$msg" '{jsonrpc:"2.0", result:{content:[{type:"text", text:$msg}]}, id:$id}' > "$F_RES"
}

handle_TBye() {
    local id="$1"
    jq -n --argjson id "$id" '{jsonrpc:"2.0", result:{content:[{type:"text", text:"what??"}]}, id:$id}' > "$F_RES"
}

handle_TEtc() {
    local id="$1" msg="$2"
    jq -n --argjson id "$id" --arg tn "$msg" '{jsonrpc:"2.0", error:{code:-32602, message:("Unknown tool: " + $tn)}, id:$id}' > "$F_RES"
}


# 메인 핸들러 로직 실행
source "$(dirname "$0")/mcp_handler.sh"
