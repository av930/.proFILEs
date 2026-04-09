#!/bin/bash

# Gerrit Commit read/write 자동화 스크립트
set -euo pipefail

#==================================================================================================================
# Gerrit Commit read/write 스크립트
# 사용법: commit.sh <read|write|wirte|test|help> <url> <item> [json파일 또는 json문자열]
# 예시1: commit.sh write https://vgit.lge.com/na/c/project/+/1306464 message '{"change_id":1306464,"message":"New subject"}'
# 예시2: commit.sh read  https://vgit.lge.com/na/c/project/+/1306464 message
#==================================================================================================================

# 색상 정의
COLOR_GREEN="\033[92m\033[1m"
COLOR_RED="\033[91m\033[1m"
COLOR_YELLOW="\033[93m\033[1m"
COLOR_BLUE="\033[94m\033[1m"
COLOR_RESET="\033[0m"

# 선 그리기
line="---------------------------------------------------------------------------------------------------------------------------------"
bar() { printf "\n\n\e[1;36m%s%s \e[0m\n" "${1:+[$1] }" "${line:(${1:+3} + ${#1})}"; }

# Gerrit 서버 설정
readonly USER="${GERRIT_USER:-vc.integrator}"
readonly VGIT_TOKEN="${TOKEN_VGIT:-}"
readonly LAMP_TOKEN="${TOKEN_LAMP:-}"
readonly TEST_COMMIT_URL="${GERRIT_TEST_COMMIT_URL:-https://vgit.lge.com/na/c/devops/scm/infra/devenv/+/1306464}"
readonly TEST_REVIEWER="${GERRIT_TEST_REVIEWER:-${USER}}"

TEMP_RESPONSE_FILE="$(mktemp)"

cleanup_temp_file() {
    [[ -f "$TEMP_RESPONSE_FILE" ]] && rm -f "$TEMP_RESPONSE_FILE"
}

require_commands() {
    command -v jq >/dev/null 2>&1 || { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} jq command not found"; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} curl command not found"; exit 1; }
}

#==================================================================================================================
# 함수: 인증 정보 결정
#==================================================================================================================
get_auth_info() {
    local gerrit_url="$1"
    local token=""

    case "$gerrit_url" in
        *"lamp.lge.com"*) token="$LAMP_TOKEN"
    ;; *)                 token="$VGIT_TOKEN"
    esac

    [[ -z "$token" ]] && {
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Missing token. Export TOKEN_VGIT or TOKEN_LAMP." >&2
        return 1
    }

    echo "${USER}:${token}"
}

#==================================================================================================================
# 함수: Commit URL에서 API URL 구성
# 입력: http://vgit.lge.com/na/c/project/+/1306464
# 출력: {"change_id":"1306464","api_url":"http://vgit.lge.com/na/a/changes/1306464"}
#==================================================================================================================
parse_commit_url() {
    local commit_url="$1"
    local url_trimmed change_id api_url

    url_trimmed="${commit_url%/}"

    # 이미 API URL이 들어온 경우 그대로 사용
    if [[ "$url_trimmed" == *"/a/changes/"* ]]; then
        change_id="${url_trimmed##*/}"
        [[ -z "$change_id" ]] && { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Invalid API URL: $commit_url" >&2; return 1; }
        echo "{\"change_id\":\"$change_id\",\"api_url\":\"$url_trimmed\"}"
        return 0
    fi

    change_id="${url_trimmed##*/}"
    [[ ! "$change_id" =~ ^[0-9]+$ ]] && {
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} URL에서 change_id를 찾지 못했습니다: $commit_url" >&2
        return 1
    }

    case "$url_trimmed" in
        *"lamp.lge.com"*)    api_url="http://lamp.lge.com/review/a/changes/${change_id}"
    ;; *"vgit.lge.com/na"*) api_url="http://vgit.lge.com/na/a/changes/${change_id}"
    ;; *"vgit.lge.com/as"*) api_url="http://vgit.lge.com/as/a/changes/${change_id}"
    ;; *)
        api_url="${url_trimmed%/+/*}/a/changes/${change_id}"
    esac

    echo "{\"change_id\":\"$change_id\",\"api_url\":\"$api_url\"}"
}

#==================================================================================================================
# 함수: Gerrit 응답 Prefix 제거 및 JSON 정규화
#==================================================================================================================
normalize_gerrit_json() {
    local raw_body="$1"
    local stripped

    stripped=$(printf '%s' "$raw_body" | sed '1s/^)]}'"'"'//')
    [[ -z "$stripped" ]] && { echo "{}"; return 0; }

    if echo "$stripped" | jq -e . >/dev/null 2>&1; then
        echo "$stripped" | jq .
    else
        # JSON이 아니면 문자열로 감싸서 반환
        jq -cn --arg raw "$stripped" '{raw:$raw}'
    fi
}

#==================================================================================================================
# 함수: 공통 API 호출
#==================================================================================================================
call_gerrit_api() {
    local cmd="$1"
    local label="$2"
    local method="$3"
    local api_url="$4"
    local payload="${5:-}"
    local auth http_code body

    auth=$(get_auth_info "$api_url") || return 1

    if [[ -n "$payload" ]]; then
        http_code=$(curl -sS -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" -su "$auth" -X "$method" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$api_url")
    else
        http_code=$(curl -sS -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" -su "$auth" -X "$method" "$api_url")
    fi

    body=$(cat "$TEMP_RESPONSE_FILE" 2>/dev/null || true)

    if [[ "$http_code" =~ ^2 ]]; then
        if [[ "$cmd" == "read" ]]; then
            normalize_gerrit_json "$body"
        else
            echo -e "${COLOR_GREEN}[OKAY]${COLOR_RESET} $label success (HTTP $http_code)"
            [[ -n "$body" ]] && normalize_gerrit_json "$body"
        fi
        return 0
    fi

    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $label failed (HTTP $http_code)" >&2
    [[ -n "$body" ]] && normalize_gerrit_json "$body" >&2
    return 1
}

#==================================================================================================================
# 함수: 조용한 GET 호출로 Gerrit JSON 획득
#==================================================================================================================
get_gerrit_json() {
    local api_url="$1"
    local auth http_code body

    auth=$(get_auth_info "$api_url") || return 1
    http_code=$(curl -sS -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" -su "$auth" -X GET "$api_url")
    body=$(cat "$TEMP_RESPONSE_FILE" 2>/dev/null || true)

    [[ "$http_code" =~ ^2 ]] || {
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} GET $api_url failed (HTTP $http_code)" >&2
        [[ -n "$body" ]] && normalize_gerrit_json "$body" >&2
        return 1
    }

    normalize_gerrit_json "$body"
}

#==================================================================================================================
# 함수: JSON 입력 로딩
#==================================================================================================================
load_json_input() {
    local input="$1"

    if [[ -f "$input" ]]; then
        cat "$input"
    else
        echo "$input"
    fi
}

#==================================================================================================================
# 함수: Change-Id footer가 포함된 commit message 생성
#==================================================================================================================
build_commit_message() {
    local api_url="$1"
    local requested_message="$2"
    local auth http_code detail_body detail_json change_id_line

    if grep -q '^Change-Id:' <<< "$requested_message"; then
        echo "$requested_message"
        return 0
    fi

    auth=$(get_auth_info "$api_url") || return 1
    http_code=$(curl -sS -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" -su "$auth" -X GET "$api_url/detail")
    detail_body=$(cat "$TEMP_RESPONSE_FILE" 2>/dev/null || true)

    [[ ! "$http_code" =~ ^2 ]] && {
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} message detail read failed (HTTP $http_code)" >&2
        [[ -n "$detail_body" ]] && normalize_gerrit_json "$detail_body" >&2
        return 1
    }

    detail_json=$(normalize_gerrit_json "$detail_body") || return 1
    change_id_line=$(jq -r '.change_id // empty' <<< "$detail_json")

    [[ -z "$change_id_line" || "$change_id_line" == "null" ]] && {
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} change_id 없음" >&2
        return 1
    }

    printf '%s\n\nChange-Id: %s\n' "$requested_message" "$change_id_line"
}

#==================================================================================================================
# 함수: 테스트 보조 함수
#==================================================================================================================
test_timestamp() {
    date +%Y%m%d%H%M%S
}

test_require_target() {
    [[ -n "$TEST_COMMIT_URL" ]] && return 0
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} GERRIT_TEST_COMMIT_URL is required for test mode" >&2
    return 1
}

test_read_item() {
    local item="$1"
    local commit_url="${2:-$TEST_COMMIT_URL}"
    local read_result

    test_require_target || return 1
    read_result=$(dispatch_item read "$commit_url" "$item" "") || return 1
    echo "$read_result" | jq . >/dev/null 2>&1 || return 1
    echo "$read_result"
}

test_write_item() {
    local item="$1"
    local commit_url="$2"
    local json_data="$3"

    dispatch_item write "$commit_url" "$item" "$json_data"
}

#==================================================================================================================
# 함수: Commit 메시지 read/write/test/help
#==================================================================================================================
gerrit_message() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info change_id gerrit_url message payload full_message
    local before_json before_message after_json new_message restore_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            change_id=$(jq -r '.change_id' <<< "$parsed_info")
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            message=$(jq -r '.message // empty' <<< "$json_data")

            [[ -z "$message" ]] && { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} message 없음"; return 1; }
            full_message=$(build_commit_message "$gerrit_url" "$message") || return 1
            payload=$(jq -cn --arg message "$full_message" '{message:$message}')

            call_gerrit_api "$cmd" "message write" "PUT" "$gerrit_url/message" "$payload"
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "message read" "GET" "$gerrit_url/message" | jq '{message:(.subject // .full_message // null), subject:(.subject // null), full_message:(.full_message // null), footers:(.footers // {})}'
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            before_json=$(test_read_item "message" "$commit_url") || return 1
            before_message=$(jq -r '.message // empty' <<< "$before_json")
            new_message="commit.sh test message $(test_timestamp)"

            test_write_item "message" "$commit_url" "$(jq -cn --arg message "$new_message" '{message:$message}')" || return 1
            after_json=$(test_read_item "message" "$commit_url") || return 1
            [[ "$(jq -r '.message // empty' <<< "$after_json")" == "$new_message" ]] || return 1

            [[ -n "$before_message" && "$before_message" != "$new_message" ]] && {
                restore_json=$(jq -cn --arg message "$before_message" '{message:$message}')
                test_write_item "message" "$commit_url" "$restore_json" || return 1
            }

            echo '{"item":"message","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> message '{\"message\":\"New subject\"}'"
            echo "usage) commit.sh read  <url> message"
        ;;
    esac
}

#==================================================================================================================
# 함수: Topic read/write/test/help
#==================================================================================================================
gerrit_topic() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info gerrit_url topic payload
    local before_json before_topic after_json new_topic restore_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            topic=$(jq -r '.topic // empty' <<< "$json_data")

            if [[ -z "$topic" ]]; then
                call_gerrit_api "$cmd" "topic clear" "DELETE" "$gerrit_url/topic"
            else
                payload=$(jq -cn --arg topic "$topic" '{topic:$topic}')
                call_gerrit_api "$cmd" "topic write" "PUT" "$gerrit_url/topic" "$payload"
            fi
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "topic read" "GET" "$gerrit_url/topic" | jq 'if type=="string" then {topic:.} else {topic:(.topic // null)} end'
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            before_json=$(test_read_item "topic" "$commit_url") || return 1
            before_topic=$(jq -r '.topic // empty' <<< "$before_json")
            new_topic="commit-sh-test-topic-$(test_timestamp)"

            test_write_item "topic" "$commit_url" "$(jq -cn --arg topic "$new_topic" '{topic:$topic}')" || return 1
            after_json=$(test_read_item "topic" "$commit_url") || return 1
            [[ "$(jq -r '.topic // empty' <<< "$after_json")" == "$new_topic" ]] || return 1

            restore_json=$(jq -cn --arg topic "$before_topic" '{topic:$topic}')
            test_write_item "topic" "$commit_url" "$restore_json" || return 1

            echo '{"item":"topic","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> topic '{\"topic\":\"new-topic\"}'"
            echo "usage) commit.sh read  <url> topic"
        ;;
    esac
}

#==================================================================================================================
# 함수: Reviewer read/write/test/help
#==================================================================================================================
gerrit_reviewers() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info gerrit_url reviewers_json single_reviewer item reviewer_value reviewer_payload
    local read_json
    local result=0

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            reviewers_json=$(jq -c '.reviewers // empty' <<< "$json_data")
            single_reviewer=$(jq -r '.reviewer // empty' <<< "$json_data")

            [[ -z "$reviewers_json" && -z "$single_reviewer" ]] && { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} reviewers/reviewer 없음"; return 1; }

            if [[ -n "$reviewers_json" ]]; then
                while IFS= read -r item; do
                    [[ -z "$item" ]] && continue
                    reviewer_value=$(jq -r 'if type=="object" then .reviewer // empty else . end' <<< "$item")
                    [[ -z "$reviewer_value" || "$reviewer_value" == "null" ]] && continue

                    reviewer_payload=$(jq -cn --arg reviewer "$reviewer_value" '{reviewer:$reviewer}')
                    call_gerrit_api "$cmd" "reviewer write" "POST" "$gerrit_url/reviewers" "$reviewer_payload" || result=1
                done < <(jq -c '.[]' <<< "$reviewers_json")
            else
                reviewer_payload=$(jq -cn --arg reviewer "$single_reviewer" '{reviewer:$reviewer}')
                call_gerrit_api "$cmd" "reviewer write" "POST" "$gerrit_url/reviewers" "$reviewer_payload" || result=1
            fi

            return $result
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "reviewer read" "GET" "$gerrit_url/reviewers"
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            test_write_item "reviewers" "$commit_url" "$(jq -cn --arg reviewer "$TEST_REVIEWER" '{reviewer:$reviewer}')" || true
            read_json=$(test_read_item "reviewers" "$commit_url") || return 1
            echo "$read_json" | jq -e --arg reviewer "$TEST_REVIEWER" 'tostring | contains($reviewer)' >/dev/null 2>&1 || return 1

            echo '{"item":"reviewers","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> reviewers '{\"reviewers\":[{\"reviewer\":\"vc.integrator\"}]}'"
            echo "usage) commit.sh read  <url> reviewers"
        ;;
    esac
}

#==================================================================================================================
# 함수: Label read/write/test/help
#==================================================================================================================
gerrit_labels() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info gerrit_url labels message review_json
    local label_key label_score payload read_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            labels=$(jq -c '.labels // empty' <<< "$json_data")
            message=$(jq -r '.message // "Review completed"' <<< "$json_data")

            [[ -z "$labels" ]] && { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} labels 없음"; return 1; }
            review_json=$(jq -cn --argjson labels "$labels" --arg message "$message" '{labels:$labels,message:$message}')

            call_gerrit_api "$cmd" "labels write" "POST" "$gerrit_url/revisions/current/review" "$review_json"
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "labels read" "GET" "$gerrit_url/detail" | jq '{labels:(.labels // {}), submit_type:(.submit_type // null)}'
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            label_key=$(test_read_item "labels" "$commit_url" | jq -r '(.labels | keys[0]) // empty')
            [[ -z "$label_key" ]] && label_key="Code-Review"
            label_score=0
            payload=$(jq -cn --arg label_key "$label_key" --arg message "commit.sh labels test $(test_timestamp)" --argjson label_score "$label_score" '{labels:{($label_key):$label_score},message:$message}')

            test_write_item "labels" "$commit_url" "$payload" || return 1
            read_json=$(test_read_item "labels" "$commit_url") || return 1
            echo "$read_json" | jq -e '.labels | type == "object"' >/dev/null 2>&1 || return 1

            echo '{"item":"labels","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> labels '{\"labels\":{\"Code-Review\":1},\"message\":\"Looks good\"}'"
            echo "usage) commit.sh read  <url> labels"
        ;;
    esac
}

#==================================================================================================================
# 함수: Comment read/write/test/help
#==================================================================================================================
gerrit_comment() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info gerrit_url message comments review_json
    local test_message read_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            message=$(jq -r '.message // empty' <<< "$json_data")
            comments=$(jq -c '.comments // empty' <<< "$json_data")

            [[ -z "$message" ]] && { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} message 없음"; return 1; }

            if [[ -n "$comments" ]]; then
                review_json=$(jq -cn --arg message "$message" --argjson comments "$comments" '{message:$message,comments:$comments}')
            else
                review_json=$(jq -cn --arg message "$message" '{message:$message}')
            fi

            call_gerrit_api "$cmd" "comment write" "POST" "$gerrit_url/revisions/current/review" "$review_json"
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "comment read" "GET" "$gerrit_url/messages"
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            test_message="commit.sh comment test $(test_timestamp)"
            test_write_item "comment" "$commit_url" "$(jq -cn --arg message "$test_message" '{message:$message}')" || return 1
            read_json=$(test_read_item "comment" "$commit_url") || return 1
            echo "$read_json" | jq -e --arg message "$test_message" 'tostring | contains($message)' >/dev/null 2>&1 || return 1

            echo '{"item":"comment","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> comment '{\"message\":\"review comment\"}'"
            echo "usage) commit.sh read  <url> comment"
        ;;
    esac
}

#==================================================================================================================
# 함수: Private read/write/test/help
#==================================================================================================================
gerrit_private() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info change_id gerrit_url is_private
    local before_json before_flag target_flag after_json restore_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            change_id=$(jq -r '.change_id' <<< "$parsed_info")
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            is_private=$(jq -r 'if .private == false then "false" else "true" end' <<< "$json_data")

            if [[ "$is_private" == "true" ]]; then
                call_gerrit_api "$cmd" "private write" "POST" "$gerrit_url/private" '{"private":true}'
            else
                call_gerrit_api "$cmd" "private write" "DELETE" "$gerrit_url/private"
            fi
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            change_id=$(jq -r '.change_id' <<< "$parsed_info")
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "private read" "GET" "$gerrit_url/detail" | jq -c --arg change_id "$change_id" '{change_id:$change_id, private:(.is_private // .private // false)}' | jq .
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            before_json=$(test_read_item "private" "$commit_url") || return 1
            before_flag=$(jq -r '.private // false' <<< "$before_json")

            if [[ "$before_flag" == "true" ]]; then target_flag=false
            else target_flag=true
            fi

            test_write_item "private" "$commit_url" "$(jq -cn --argjson private "$target_flag" '{private:$private}')" || return 1
            after_json=$(test_read_item "private" "$commit_url") || return 1
            [[ "$(jq -r '.private // false' <<< "$after_json")" == "$target_flag" ]] || return 1

            restore_json=$(jq -cn --argjson private "$before_flag" '{private:$private}')
            test_write_item "private" "$commit_url" "$restore_json" || return 1

            echo '{"item":"private","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> private '{\"private\":true}'"
            echo "usage) commit.sh read  <url> private"
        ;;
    esac
}

#==================================================================================================================
# 함수: WIP read/write/test/help
#==================================================================================================================
gerrit_wip() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info change_id gerrit_url is_wip
    local before_json before_flag target_flag after_json restore_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            is_wip=$(jq -r 'if .wip == false then "false" else "true" end' <<< "$json_data")

            if [[ "$is_wip" == "true" ]]; then
                call_gerrit_api "$cmd" "wip write" "POST" "$gerrit_url/wip"
            else
                call_gerrit_api "$cmd" "wip write" "POST" "$gerrit_url/ready"
            fi
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            change_id=$(jq -r '.change_id' <<< "$parsed_info")
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "wip read" "GET" "$gerrit_url/detail" | jq -c --arg change_id "$change_id" '{change_id:$change_id, wip:(.work_in_progress // false)}' | jq .
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            before_json=$(test_read_item "wip" "$commit_url") || return 1
            before_flag=$(jq -r '.wip // false' <<< "$before_json")

            if [[ "$before_flag" == "true" ]]; then target_flag=false
            else target_flag=true
            fi

            test_write_item "wip" "$commit_url" "$(jq -cn --argjson wip "$target_flag" '{wip:$wip}')" || return 1
            after_json=$(test_read_item "wip" "$commit_url") || return 1
            [[ "$(jq -r '.wip // false' <<< "$after_json")" == "$target_flag" ]] || return 1

            restore_json=$(jq -cn --argjson wip "$before_flag" '{wip:$wip}')
            test_write_item "wip" "$commit_url" "$restore_json" || return 1

            echo '{"item":"wip","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> wip '{\"wip\":true}'"
            echo "usage) commit.sh read  <url> wip"
        ;;
    esac
}

#==================================================================================================================
# 함수: Hashtag read/write/test/help
#==================================================================================================================
gerrit_hashtags() {
    local cmd="$1"
    local commit_url="$2"
    local json_data="${3:-}"
    local parsed_info gerrit_url hashtags payload current_hashtags
    local before_json before_tags_json after_json test_tag updated_tags_json restore_json

    case "$cmd" in
        write)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")
            hashtags=$(jq -c '.hashtags // empty' <<< "$json_data")

            [[ -z "$hashtags" ]] && { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} hashtags 없음"; return 1; }
            current_hashtags=$(get_gerrit_json "$gerrit_url/hashtags") || return 1
            payload=$(jq -cn --argjson current "$current_hashtags" --argjson desired "$hashtags" '{add:($desired - $current),remove:($current - $desired)}')

            call_gerrit_api "$cmd" "hashtags write" "POST" "$gerrit_url/hashtags" "$payload"
        ;;
        read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            call_gerrit_api "$cmd" "hashtags read" "GET" "$gerrit_url/hashtags"
        ;;
        test)
            commit_url="$TEST_COMMIT_URL"
            before_json=$(test_read_item "hashtags" "$commit_url") || return 1
            before_tags_json=$(echo "$before_json" | jq -c 'if type=="array" then . else .hashtags // [] end')
            test_tag="commit-sh-test-$(test_timestamp)"
            updated_tags_json=$(echo "$before_tags_json" | jq -c --arg tag "$test_tag" '. + [$tag] | unique')

            test_write_item "hashtags" "$commit_url" "$(jq -cn --argjson hashtags "$updated_tags_json" '{hashtags:$hashtags}')" || return 1
            after_json=$(test_read_item "hashtags" "$commit_url") || return 1
            echo "$after_json" | jq -e --arg tag "$test_tag" 'if type=="array" then index($tag) != null else (.hashtags // []) | index($tag) != null end' >/dev/null 2>&1 || return 1

            restore_json=$(jq -cn --argjson hashtags "$before_tags_json" '{hashtags:$hashtags}')
            test_write_item "hashtags" "$commit_url" "$restore_json" || return 1

            echo '{"item":"hashtags","test":"ok","mode":"write-read"}'
        ;;
        help|*)
            echo "usage) commit.sh write <url> hashtags '{\"hashtags\":[\"tag1\",\"tag2\"]}'"
            echo "usage) commit.sh read  <url> hashtags"
        ;;
    esac
}

#==================================================================================================================
# 함수: Read-only 항목 read/write/test/help
# write는 미지원이고 read만 제공
#==================================================================================================================
gerrit_read_only_item() {
    local cmd="$1"
    local commit_url="$2"
    local item="$3"
    local json_data="${4:-}"
    local parsed_info gerrit_url

    case "$cmd" in
        write)
            echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} '$item' item is read-only in this script. Use read command."
            return 1
        ;;read)
            parsed_info=$(parse_commit_url "$commit_url") || return 1
            gerrit_url=$(jq -r '.api_url' <<< "$parsed_info")

            case "$item" in
                detail) call_gerrit_api "$cmd" "detail read" "GET" "$gerrit_url/detail"
                ;;summary) call_gerrit_api "$cmd" "summary read" "GET" "$gerrit_url/detail" | jq '{change_id:(._number // null), project:(.project // null), branch:(.branch // null), status:(.status // null), subject:(.subject // null), topic:(.topic // null), private:(.is_private // .private // false), wip:(.work_in_progress // false), updated:(.updated // null)}'
                ;;owner) call_gerrit_api "$cmd" "owner read" "GET" "$gerrit_url/detail" | jq '{owner:(.owner // null)}'
                ;;assignee) call_gerrit_api "$cmd" "assignee read" "GET" "$gerrit_url/detail" | jq '{assignee:(.assignee // null)}'
                ;;status) call_gerrit_api "$cmd" "status read" "GET" "$gerrit_url/detail" | jq '{status:(.status // null), private:(.is_private // .private // false), wip:(.work_in_progress // false), submittable:(.submittable // null), mergeable:(.mergeable // null)}'
                ;;submit) call_gerrit_api "$cmd" "submit read" "GET" "$gerrit_url/detail" | jq '{submit_type:(.submit_type // null), submit_records:(.submit_records // []), requirements:(.requirements // []), labels:(.labels // {})}'
                ;;attention) call_gerrit_api "$cmd" "attention read" "GET" "$gerrit_url/detail" | jq '{attention_set:(.attention_set // {})}'
                ;;revision) call_gerrit_api "$cmd" "revision read" "GET" "$gerrit_url/detail?o=CURRENT_REVISION&o=CURRENT_COMMIT" | jq '{current_revision:(.current_revision // null), current_revision_number:(.current_revision_number // null), revision:(if .current_revision and .revisions then .revisions[.current_revision] else null end)}'
                ;;revisions) call_gerrit_api "$cmd" "revisions read" "GET" "$gerrit_url/detail?o=ALL_REVISIONS&o=CURRENT_COMMIT" | jq '{current_revision:(.current_revision // null), current_revision_number:(.current_revision_number // null), revisions:(.revisions // {})}'
                ;;files) call_gerrit_api "$cmd" "files read" "GET" "$gerrit_url/detail?o=CURRENT_REVISION&o=CURRENT_FILES" | jq '{current_revision:(.current_revision // null), files:(if .current_revision and .revisions then (.revisions[.current_revision].files // {}) else {} end)}'
                ;;mergeable) call_gerrit_api "$cmd" "mergeable read" "GET" "$gerrit_url/detail" | jq '{mergeable:(.mergeable // null), submittable:(.submittable // null), status:(.status // null)}'
                ;;*) echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Unsupported read-only item: $item"; return 1
            esac
        ;;test)
            commit_url="$TEST_COMMIT_URL"
            test_read_item "$item" "$commit_url" >/dev/null || return 1
            echo "{\"item\":\"$item\",\"test\":\"ok\",\"mode\":\"read\"}"
        ;;help|*)
            echo "usage) commit.sh read <url> detail|summary|owner|assignee|status|submit|attention|revision|revisions|files|mergeable"
    esac
}

#==================================================================================================================
# 함수: item 라우팅
#==================================================================================================================
dispatch_item() {
    local cmd="$1"
    local commit_url="$2"
    local item="$3"
    local json_data="${4:-}"

    case "$item" in
            message) gerrit_message "$cmd" "$commit_url" "$json_data"
        ;;       topic) gerrit_topic "$cmd" "$commit_url" "$json_data"
        ;;   reviewers) gerrit_reviewers "$cmd" "$commit_url" "$json_data"
        ;;      labels) gerrit_labels "$cmd" "$commit_url" "$json_data"
        ;;     comment) gerrit_comment "$cmd" "$commit_url" "$json_data"
        ;;     private) gerrit_private "$cmd" "$commit_url" "$json_data"
        ;;         wip) gerrit_wip "$cmd" "$commit_url" "$json_data"
        ;;    hashtags) gerrit_hashtags "$cmd" "$commit_url" "$json_data"
        ;;      detail) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;     summary) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;       owner) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;    assignee) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;      status) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;      submit) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;   attention) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;    revision) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;   revisions) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;       files) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
        ;;   mergeable) gerrit_read_only_item "$cmd" "$commit_url" "$item" "$json_data"
    ;;           *) echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Unsupported item: $item"; print_usage; return 1
    esac
}

#==================================================================================================================
# 테스트: 부작용 없는 테스트
#==================================================================================================================
run_all_tests() {
    bar "Gerrit Commit read/write Test Suite"

    gerrit_message test "" ""
    gerrit_topic test "" ""
    gerrit_reviewers test "" ""
    gerrit_labels test "" ""
    gerrit_comment test "" ""
    gerrit_private test "" ""
    gerrit_wip test "" ""
    gerrit_hashtags test "" ""
    gerrit_read_only_item test "" "detail" ""
    gerrit_read_only_item test "" "summary" ""
    gerrit_read_only_item test "" "owner" ""
    gerrit_read_only_item test "" "assignee" ""
    gerrit_read_only_item test "" "status" ""
    gerrit_read_only_item test "" "submit" ""
    gerrit_read_only_item test "" "attention" ""
    gerrit_read_only_item test "" "revision" ""
    gerrit_read_only_item test "" "revisions" ""
    gerrit_read_only_item test "" "files" ""
    gerrit_read_only_item test "" "mergeable" ""

    bar "All tests passed"
}

#==================================================================================================================
# 함수: 사용법 출력
#==================================================================================================================
print_usage() {
    cat <<EOF
${COLOR_YELLOW}Usage:${COLOR_RESET}
    $0 <read|write|wirte|test|help> <url> <item> [json_file_or_json]

${COLOR_YELLOW}Command:${COLOR_RESET}
    - read   : Read Gerrit item and return JSON
    - write  : Write Gerrit item using JSON payload
    - wirte  : Alias of write (typo compatibility)
    - test   : Run side-effect free tests
    - help   : Show this help

${COLOR_YELLOW}Item:${COLOR_RESET}
    - message
    - topic
    - reviewers
    - labels
    - comment
    - private
    - wip
    - hashtags
    - detail     (read-only)
    - summary    (read-only)
    - owner      (read-only)
    - assignee   (read-only)
    - status     (read-only)
    - submit     (read-only)
    - attention  (read-only)
    - revision   (read-only)
    - revisions  (read-only)
    - files      (read-only)
    - mergeable  (read-only)

${COLOR_YELLOW}Examples:${COLOR_RESET}
    $0 write https://vgit.lge.com/na/c/project/+/1306464 message '{"change_id":1306464,"message":"New subject"}'
    $0 read  https://vgit.lge.com/na/c/project/+/1306464 message
    $0 read  https://vgit.lge.com/na/c/project/+/1306464 assignee
    $0 read  https://vgit.lge.com/na/c/project/+/1306464 detail
    $0 test
EOF
}

#==================================================================================================================
# 메인 함수
#==================================================================================================================
main() {
    local cmd="${1:-help}"
    local commit_url="${2:-}"
    local item="${3:-}"
    local json_input="${4:-}"

    case "$cmd" in
          help|-h|--help) print_usage;  return 0
    ;;             test) run_all_tests; return 0
    ;;            wirte) cmd="write"
    ;;       read|write) :
    ;;                *) echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} Unsupported command: $cmd"; print_usage; return 1
    esac

    [[ -z "$commit_url" || -z "$item" ]] && {
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} url/item is required"
        print_usage
        return 1
    }

    if [[ "$cmd" == "write" ]]; then
        [[ -z "$json_input" ]] && {
            echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} write mode requires JSON input"
            print_usage
            return 1
        }
        json_input=$(load_json_input "$json_input")
    fi

    dispatch_item "$cmd" "$commit_url" "$item" "$json_input"
}

#==================================================================================================================
# 메인 진입점
#==================================================================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_commands

    main "$@"
    cleanup_temp_file
fi
