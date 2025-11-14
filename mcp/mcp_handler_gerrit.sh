#!/bin/bash

set -ex
# tool 함수정의, client에서 "@bash-mcp tool-jenkins ~~~"로 호출시 tool 이름으로 사용된다.
handle_tools_list() {
    local id="$1"
    jq -n --argjson id "$id" '{
        jsonrpc: "2.0",
        result: { tools: [
                {   name: "tool-jenkins",
                    description: "call jenkins url",
                    inputSchema: {  type: "object",
                                    properties: { name: { type: "string", description: "Optional name" } },
                                    required: []  }
                },
                {   name: "tool-gerrit",
                    description: "call gerrit url",
                    inputSchema: {  type: "object",
                                    properties: { name: { type: "string", description: "Optional name" } },
                                    required: []  }
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
          tool-gerrit)   handle_TGerrit "$id" "$body"
        ;;tool-jenkins)  handle_TGerrit "$id" "$body"
        ;;           *)  handle_TEtc "$id" "$tool_name"
    esac
}

# 공유 유틸리티 함수들 로드
MCP_BASE_DIR="/data001/vc.integrator/.proFILEs/mcp"
source "${MCP_BASE_DIR}/core/mcp_utils.sh"

# tool function 정의
retrigger_jenkins() {
    local ret_jenkins url_jenkins=$1
    local CURL_CALL_TOKEN=1115aa9663a20801980e2ab969028d3b46
    local res_jenkins build_num queue_url queue_info

        # Jenkins job 호출 및 응답 헤더에서 Location 추출 (5초 타임아웃)
    res_jenkins=$(curl -si -u "${USER}:${CURL_CALL_TOKEN}" -d "URL_TRIGGER=${url_jenkins}" -X POST \
        "${JENKINS_URL}/buildWithParameters" --max-time 3 2> /dev/null)

    # Jenkins 응답 상태에 따른 처리
    local status=unknown build_num queue_url queue_info
    [[ $? -eq 124 ]] && status=timeout
    [[ -n $res_jenkins ]] && status=success
    [[ -z $res_jenkins ]] && status=failed

    case $status in
           timeout) ret_jenkins="Jenkins call timeout (>5s) for: $JENKINS_URL"
        ;; success)
            queue_url=$(echo "$res_jenkins" | grep -i "^Location:" | tr -d '\r' | sed 's/[Ll]ocation: //')
            case ${queue_url:+found} in
                found) # Queue에서 build될때까지 대기 (9초: 3초 간격으로 3회 시도)
                    for i in {1..3}; do sleep 3
                        queue_info=$(curl -su "${USER}:${CURL_CALL_TOKEN}" "${queue_url}api/json" 2>/dev/null)
                        if [[ $? -eq 0 && "$queue_info" != *"404"* && "$queue_info" != *"<html>"* ]]; then
                            build_num=$(echo "$queue_info" | jq -r '.executable.number // empty' 2>/dev/null)

                            if [[ -z "$build_num" || "$build_num" == "null" || "$build_num" == "empty" ]]; then continue  #다음시도
                            else ret_jenkins="Jenkins job is re-triggered: $JENKINS_URL/$build_num"; break                     #잘된경우
                            fi
                        fi
                    done

                    # 빌드 번호를 찾지 못한 경우
                    if [[ -z "$build_num" || "$build_num" == "null" || "$build_num" == "empty" ]]; then
                        ret_jenkins="Jenkins call is waiting queued: $(cat $queue_info | jq -r .task.url 2>/dev/null || echo "$queue_url")"
                    fi
                ;; *) ret_jenkins="Jenkins call is not triggered: $JENKINS_URL"
            esac

        ;; failed|*)
            ret_jenkins="Jenkins call is failed: $JENKINS_URL"
    esac
    echo "$ret_jenkins"
}

get_latest_build_status() {
    local gerrit_change_url="$1"
    local gerrit_api_url comment_json comments latest_message

    gerrit_change_url="${gerrit_change_url/https/http}"
    # gerrit change-id 추출 (예: https://vgit.lge.com/na/c/project/+/12345 → 12345)
    local remote change_id
    remote=$(echo "$gerrit_change_url" | grep -oP '(?<=://vgit\.lge\.com/)[^/]+' || { result='not working, check url'; return 1; } )
    change_id=$(echo "$gerrit_change_url" | grep -oE '/[0-9]+$' | tr -d '/')

    # Gerrit REST API URL - HTTP 사용 및 /as 경로 포함, messages API 사용
    gerrit_api_url="http://vgit.lge.com/${remote}/a/changes/$change_id/messages"

    # 인증 추가
    comment_json=$(curl -su vc.integrator:'UUmF3ZYZofW1JqRwEFe4g1tHbs1hLoVuVVKrxpvG0g' "$gerrit_api_url" | sed '1d') # Gerrit REST API는 첫 줄에 )]}'

    # 최신 comment부터 순회하여 첫 번째 빌드 관련 메시지를 찾음
    latest_message=""
    comments=$(echo "$comment_json" | jq -r '.[].message' 2>/dev/null | tac)
    while IFS= read -r comment; do
        if [[ "$comment" == Build\ Successful* ]] || [[ "$comment" == Build\ Started* ]] || [[ "$comment" == Build\ Failed* ]]; then
            latest_message="$comment"
            break
        fi
    done <<< "$comments"

    # lge.com URL 추출 함수
    extract_lge_urls() {
        local message="$1"
        # 전체 메시지에서 FAILURE 패턴의 Jenkins URL 추출
        echo "$comment_json" | jq -r '.[].message' | grep -oE 'http://[^[:space:]]*lge\.com[^[:space:]]*/ : FAILURE' | sed 's/ : FAILURE$//' | head -10
    }

    # 가장 최근 빌드 메시지에 따른 처리
    if [[ "$latest_message" == Build\ Successful* ]]; then
        echo "All Build Success (Success)"
    elif [[ "$latest_message" == Build\ Started* ]]; then
        echo "Wait, build to finish (Running)"
        extract_lge_urls "$latest_message"
    elif [[ "$latest_message" == Build\ Failed* ]]; then
        echo "Build failed (Failed)"
        local jenkins_urls
        jenkins_urls=$(extract_lge_urls "$latest_message")
        echo "DEBUG: Latest failed message: $latest_message"
        echo "DEBUG: Extracted URLs: $jenkins_urls"

        # Build Failed인 경우 자동으로 retrigger 실행
        local result=""
        while IFS= read -r url; do
            if [[ -n "$url" ]]; then
                echo "DEBUG: Calling retrigger_jenkins with URL: $url"
                local retrigger_result
                retrigger_result=$(retrigger_jenkins "$url")
                echo "DEBUG: Retrigger result: $retrigger_result"
                result+="$retrigger_result"$'\n'
            fi
        done <<< "$jenkins_urls"

        if [[ -n "$result" ]]; then
            echo "--- Auto Retrigger Results ---"
            echo "$result"
        else
            echo "DEBUG: No retrigger results - jenkins_urls was empty"
        fi
    else
        echo "Wait, build to start automatically (Waiting)"
    fi
}

handle_TGerrit() {
    local result param id="$1" body="$2"
    JENKINS_URL="http://vjenkins.lge.com/jenkins03/job/Common_retriggerJOB"
    param=$(echo "$body" | jq -r '.params.arguments.name // .params.input.name // empty')
    if [[ -z $param ]]; then
        result="Please input Jenkins url or Gerrit url"
    elif [[ "$param" =~ vjenkins.lge.com ]]; then
        result=$(retrigger_jenkins "$param")
    elif [[ "$param" =~ vgit.lge.com ]] || [[ "$param" =~ lamp.lge.com ]]; then
        result=$(get_latest_build_status "$param")
    else
        result="Unsupported URL format"
    fi
    make_tool_response "$id" "$result"
}

handle_TEtc() {
    local id="$1" result="$2"
    jq -n --argjson id "$id" --arg result "$result" '{jsonrpc:"2.0", error:{code:-32602, message:("Unknown tool: " + $result)}, id:$id}' > "$FILE_RES"
}




# 메인 핸들러 로직 실행
source "$(dirname "$0")/core/mcp_handler.sh"
