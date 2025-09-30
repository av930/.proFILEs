#!/bin/bash

# MCP 공유 유틸리티 함수들

# MCP 도구 응답 생성 함수 (모든 핸들러에서 사용 가능)
make_tool_response() {
    local id="$1" content="$2" error_code="$3" error_msg="$4"
    if [[ -n $error_code ]]; then
        jq -n --argjson id "$id" --argjson code "$error_code" --arg msg "$error_msg" \
            '{jsonrpc: "2.0", error: {code: $code, message: $msg}, id: $id}' > "$FILE_RES"
    else
        jq -n --argjson id "$id" --arg content "$content" \
            '{jsonrpc: "2.0", result: {content: [{type: "text", text: $content}]}, id: $id}' > "$FILE_RES"
    fi
}

# MCP 에러 응답 생성 함수
make_tool_error() {
    local id="$1" error_code="${2:-32602}" error_msg="$3"
    make_tool_response "$id" "" "$error_code" "$error_msg"
}