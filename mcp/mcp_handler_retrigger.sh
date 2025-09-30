#!/bin/bash

set -ex
# tool 함수정의, client에서 "@bash-mcp tool-jenkins ~~~"로 호출시 tool 이름으로 사용된다.
handle_tools_list() {
    local id="$1"
    jq -n --argjson id "$id" '{
        jsonrpc: "2.0",
        result: { tools: [
                {   name: "tool-jenkins",
                    description: "Return a greeting (optionally with a name)",
                    inputSchema: {  type: "object",
                                    properties: { name: { type: "string", description: "Optional name" } },
                                    required: []  }
                },
                {   name: "tool-gerrit",
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
          tool-jenkins)   handle_TJenkins "$id" "$body"
        ;; tool-gerrit)   handle_TGerrit "$id"
        ;;           *)   handle_TEtc "$id" "$tool_name"
    esac
}

# 공유 유틸리티 함수들 로드
MCP_BASE_DIR="/data001/vc.integrator/.proFILEs/mcp"
source "${MCP_BASE_DIR}/core/mcp_utils.sh"

# tool function 정의
handle_TJenkins() {
    local result param id="$1" body="$2"
    local CURL_CALL_TOKEN=1115aa9663a20801980e2ab969028d3b46
    local res_jenkins build_num queue_url queue_info
    JENKINS_URL="http://vjenkins.lge.com/jenkins03/job/Common_retriggerJOB"
    param=$(echo "$body" | jq -r '.params.arguments.name // .params.input.name // empty')
    if [[ -z $param ]]; then
        result="Please input Jenkins url"
    else
        # Jenkins job 호출 및 응답 헤더에서 Location 추출 (5초 타임아웃)
        res_jenkins=$(curl -si -u "${USER}:${CURL_CALL_TOKEN}" -d "URL_TRIGGER=${param}" -X POST \
            "${JENKINS_URL}/buildWithParameters" --max-time 3 2> /dev/null)

        # Jenkins 응답 상태에 따른 처리
        local status=unknown build_num queue_url queue_info
        [[ $? -eq 124 ]] && status=timeout
        [[ -n $res_jenkins ]] && status=success
        [[ -z $res_jenkins ]] && status=failed

        case $status in
               timeout) result="Jenkins call timeout (>5s) for: $JENKINS_URL"
            ;; success)
                queue_url=$(echo "$res_jenkins" | grep -i "^Location:" | tr -d '\r' | sed 's/[Ll]ocation: //')
                case ${queue_url:+found} in
                    found) # Queue에서 build될때까지 대기 (9초: 3초 간격으로 3회 시도)
                        for i in {1..3}; do sleep 3
                            queue_info=$(curl -su "${USER}:${CURL_CALL_TOKEN}" "${queue_url}api/json" 2>/dev/null)
                            if [[ $? -eq 0 && "$queue_info" != *"404"* && "$queue_info" != *"<html>"* ]]; then
                                build_num=$(echo "$queue_info" | jq -r '.executable.number // empty' 2>/dev/null)

                                if [[ -z "$build_num" || "$build_num" == "null" || "$build_num" == "empty" ]]; then continue  #다음시도
                                else result="Jenkins job is re-triggered: $JENKINS_URL/$build_num"; break                     #잘된경우
                                fi
                            fi
                        done

                        # 빌드 번호를 찾지 못한 경우
                        if [[ -z "$build_num" || "$build_num" == "null" || "$build_num" == "empty" ]]; then
                            result="Jenkins call is waiting queued: $(cat $queue_info | jq -r .task.url 2>/dev/null || echo "$queue_url")"
                        fi
                    ;; *) result="Jenkins call is not triggered: $JENKINS_URL"
                esac

            ;; failed|*)
                result="Jenkins call is failed: $JENKINS_URL"
        esac
    fi
    make_tool_response "$id" "$result"
}

handle_TGerrit() {
    local result param id="$1" body="$2"
    param=$(echo "$body" | jq -r '.params.arguments.name // .params.input.name // empty')
    [[ -n $param ]] && result="Hello, $param" || result="Hello"
    make_tool_response "$id" "$result"
}

handle_TEtc() {
    local id="$1" result="$2"
    jq -n --argjson id "$id" --arg result "$result" '{jsonrpc:"2.0", error:{code:-32602, message:("Unknown tool: " + $result)}, id:$id}' > "$FILE_RES"
}




# 메인 핸들러 로직 실행
source "$(dirname "$0")/core/mcp_handler.sh"
