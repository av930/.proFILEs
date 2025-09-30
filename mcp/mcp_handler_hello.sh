#!/bin/bash

# tool 함수들을 먼저 정의
handle_tools_list() {
    local id="$1"
    jq -n --argjson id "$id" '{
        jsonrpc: "2.0",
        result: { tools: [
                {   name: "tool-hello",
                    description: "Return a greeting (optionally with a name)",
                    inputSchema: {  type: "object",
                                    properties: { name: { type: "string", description: "Optional name" } },
                                    required: []  }
                },
                {   name: "tool-bye",
                    description: "Return a bye message",
                    inputSchema: { type: "object", properties: {}, required: [] }
                }
            ]},
        id: $id
    }' > "$FILE_RES"
}

# tool handler 정의
handle_tools_call() {
    local tool_name id="$1" body="$2"
    tool_name=$(echo "$body" | jq -r '.params.name // .params.tool // empty')

    case "$tool_name" in
          tool-hello)   handle_THello "$id" "$body"
        ;;  tool-bye)   handle_TBye "$id"
        ;;         *)   handle_TEtc "$id" "$tool_name"
    esac
}

# tool function 정의
handle_THello() {
    local result param id="$1" body="$2"
    param=$(echo "$body" | jq -r '.params.arguments.name // .params.input.name // empty')
    [[ -n $param ]] && result="Hello, $param" || result="Hello"
    make_tool_response "$id" "$result"
}

handle_TBye() {
    local id="$1"
    make_tool_response "$id" "what??"
}

handle_TEtc() {
    local id="$1" result="$2"
    jq -n --argjson id "$id" --arg tn "$result" '{jsonrpc:"2.0", error:{code:-32602, message:("Unknown tool: " + $tn)}, id:$id}' > "$FILE_RES"
}


# 공유 유틸리티 함수들 로드
MCP_BASE_DIR="/data001/vc.integrator/.proFILEs/mcp"
source "${MCP_BASE_DIR}/core/mcp_utils.sh"

# 메인 핸들러 로직 실행
source "$(dirname "$0")/core/mcp_handler.sh"
