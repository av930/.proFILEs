#!/bin/bash
# Exit on error disabled for compatibility with certain commands
# set -e

#------------------------------------------------------------------------------
# JIRA Field search & Update Script
# Usage:
#   Search:  ./jira_update_field.sh <PROJECT> <FIELD> search <VALUE>
#   Modify: ./jira_update_field.sh <PROJECT> <FIELD> modify <NEW_VALUE>
#------------------------------------------------------------------------------

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# Config
JIRA_API_URL="${JIRA_URL:-http://jira.lge.com/issue}"
JIRA_BROWSE_URL="${JIRA_API_URL}/browse"
PROJECT_KEY="${1}"; FIELD_NAME="${2}"; MODE="${3}"; VALUE="${4}"


#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------
error_exit() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

show_usage() {
    cat <<EOF
Usage:
  Search:  $0 <PROJECT> <FIELD> search <VALUE>
  Modify: $0 <PROJECT> <FIELD> modify <NEW_VALUE>

Examples:
  $0 SCINFRADEV 'Component/s' search HONDA_TSU_25.5MY
  $0 SCINFRADEV 'Component/s' modify H_25.5MY
EOF
    exit 1
}

get_credentials() {
    [ -z "$JIRA_USER" ] && error_exit "JIRA Username is missing"
    [ -z "$JIRA_KEY" ] && error_exit "JIRA Password is missing"
}

test_auth() {
    local http_code=$(curl -s -L -w "%{http_code}" -o /dev/null -u "$JIRA_USER:$JIRA_KEY" "$JIRA_API_URL/rest/api/2/myself")
    [ "$http_code" != "200" ] && error_exit "Authentication failed (HTTP $http_code)"
    echo -e "${GREEN}✓ Authenticated as $JIRA_USER${NC}"
}

normalize_field() {
    local normalized=$(echo "$FIELD_NAME" | tr '[:upper:]' '[:lower:]' | tr -d ' /')
    case "$normalized" in
        component|components) FIELD_TYPE="component"; FIELD_KEY="components";;
        label|labels) FIELD_TYPE="array"; FIELD_KEY="labels";;
        customfield_*) FIELD_TYPE="custom"; FIELD_KEY="$FIELD_NAME";;
        *) FIELD_TYPE="string"; FIELD_KEY="$FIELD_NAME";;
    esac
}

get_component_id() {
    local comp_name="$1"
    curl -s -L -u "$JIRA_USER:$JIRA_KEY" "$JIRA_API_URL/rest/api/2/project/$PROJECT_KEY/components" | \
        jq -r ".[] | select(.name==\"$comp_name\") | .id" | head -1
}

create_component() {
    local comp_name="$1"
    curl -s -L -u "$JIRA_USER:$JIRA_KEY" -X POST -H "Content-Type: application/json" \
        -d "{\"name\":\"$comp_name\",\"project\":\"$PROJECT_KEY\"}" "$JIRA_API_URL/rest/api/2/component" | \
        jq -r '.id // ""'
}

#------------------------------------------------------------------------------
# Search Mode
#------------------------------------------------------------------------------
search_issues() {
    local OUTPUT_FILE="${PROJECT_KEY}.search"
    local jql value_id

    if [ "$FIELD_TYPE" = "component" ]; then
        # 쉼표로 구분된 여러 컴포넌트 처리
        IFS=',' read -ra COMPONENTS <<< "$VALUE"
        local jql_parts=()

        for comp in "${COMPONENTS[@]}"; do
            # 앞뒤 공백 제거
            comp=$(echo "$comp" | xargs)
            value_id=$(get_component_id "$comp")
            [ -z "$value_id" ] && error_exit "Component '$comp' not found"
            echo -e "${GREEN}✓ Component '$comp' (ID: $value_id)${NC}"
            jql_parts+=("component = $value_id")
        done

        # JQL 조합 (AND로 연결)
        local jql_combined=$(printf " AND %s" "${jql_parts[@]}")
        jql_combined=${jql_combined:5}  # 앞의 " AND " 제거
        jql="project = $PROJECT_KEY AND $jql_combined"
    else
        jql="project = $PROJECT_KEY AND $FIELD_KEY ~ \"$VALUE\""
    fi

    echo -e "${CYAN}JQL: $jql${NC}"
    local jql_enc=$(echo -n "$jql" | jq -sRr @uri)

    local response=$(curl -s -L -u "$JIRA_USER:$JIRA_KEY" "$JIRA_API_URL/rest/api/2/search?jql=$jql_enc&maxResults=1000&fields=key,$FIELD_KEY,summary")

    local count=$(echo "$response" | jq -r '.total // 0')
    local result="TOTAL:$count"

    if [ "$FIELD_TYPE" = "component" ]; then
        result+=$'\n'$(echo "$response" | jq -r ".issues[] | .key + \"|\" + \"$JIRA_BROWSE_URL/\" + .key + \"|\" + (.fields.summary[:60] // \"\") + \"|\" + ([.fields.$FIELD_KEY[]?.name] | join(\",\"))" || true)
    else
        result+=$'\n'$(echo "$response" | jq -r ".issues[] | .key + \"|\" + \"$JIRA_BROWSE_URL/\" + .key + \"|\" + (.fields.summary[:60] // \"\") + \"|\" + (.fields.$FIELD_KEY // \"N/A\" | tostring)" || true)
    fi

    local count=$(echo "$result" | grep "^TOTAL:" | cut -d':' -f2)
    local issues=$(echo "$result" | grep -v "^TOTAL:" || true)

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}No issues found${NC}"
        rm -f "$OUTPUT_FILE"
        return
    fi

    echo -e "${GREEN}Found $count issue(s):${NC}"
    > "$OUTPUT_FILE"
    echo "$issues" | while IFS='|' read -r key url summary field_val; do
        echo "$url" >> "$OUTPUT_FILE"
        printf "  %-12s %s\n" "$key" "$summary"
    done
    echo -e "${GREEN}✓ Saved to $OUTPUT_FILE${NC}"
}

#------------------------------------------------------------------------------
# Modify Mode
#------------------------------------------------------------------------------
modify_issues() {
    local INPUT_FILE="${PROJECT_KEY}.search"
    local OUTPUT_FILE="${PROJECT_KEY}.modify"

    rm -f "$OUTPUT_FILE" || true
    [ ! -f "$INPUT_FILE" ] && error_exit "File '$INPUT_FILE' not found. Run search first."

    local count=$(wc -l < "$INPUT_FILE")
    echo -e "${CYAN}Will update $count issue(s) to '$VALUE'${NC}"

    local new_id
    if [ "$FIELD_TYPE" = "component" ]; then
        new_id=$(get_component_id "$VALUE")
        if [ -z "$new_id" ]; then
            echo -e "${YELLOW}Creating component '$VALUE'...${NC}"
            new_id=$(create_component "$VALUE")
        fi
        [ -z "$new_id" ] && error_exit "Failed to get/create component"
        echo -e "${GREEN}✓ Component ID: $new_id${NC}"
    fi

    > "$OUTPUT_FILE"
    local success=0 failed=0
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        local key=$(basename "$url")
        local json
        case "$FIELD_TYPE" in
            component) json="{\"fields\":{\"$FIELD_KEY\":[{\"id\":\"$new_id\"}]}}";;
            array) json="{\"fields\":{\"$FIELD_KEY\":[\"$VALUE\"]}}";;
            *) json="{\"fields\":{\"$FIELD_KEY\":\"$VALUE\"}}";;
        esac

        local response=$(mktemp)
        local http_code=$(curl -s -L -w "%{http_code}" -o "$response" -u "$JIRA_USER:$JIRA_KEY" \
            -X PUT -H "Content-Type: application/json" -d "$json" "$JIRA_API_URL/rest/api/2/issue/$key" || echo "000")

        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
            echo -e "  $key ${GREEN}✓${NC}"
            echo "$url" >> "$OUTPUT_FILE"
            success=$((success + 1))
        else
            local error_msg=$(cat "$response" | jq -r '.errors.components // .errorMessages[0] // ""' 2>/dev/null)
            echo -e "  $key ${RED}✗ (HTTP $http_code)${NC}"

            # 권한 관련 에러 메시지 확인
            if [[ "$error_msg" == *"cannot be set"* ]] || [[ "$error_msg" == *"not on the appropriate screen"* ]]; then
                echo -e "    ${YELLOW}⚠ Permission issue: User may lack permission to modify this field (closed issue or screen restriction)${NC}"
            fi
            failed=$((failed + 1))
        fi
        rm -f "$response"
        sleep 0.3
    done < "$INPUT_FILE"

    echo -e "\n${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"

    if [ $failed -gt 0 ]; then
        echo -e "${RED}✗ Error: $failed issue(s) failed to update${NC}" >&2
        echo -e "${YELLOW}  See differences: diff $INPUT_FILE $OUTPUT_FILE${NC}" >&2
        exit 1
    fi
    mv $INPUT_FILE ${INPUT_FILE/.search/.finish}

    echo -e "${GREEN}✓ All issues updated successfully${NC}"
    echo -e "${GREEN}✓ Target is saved to ${INPUT_FILE/.search/.finish}${NC}"
    echo -e "${GREEN}✓ Result is saved to $OUTPUT_FILE${NC}"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
[ -z "$PROJECT_KEY" ] || [ -z "$FIELD_NAME" ] || [ -z "$MODE" ] && show_usage
[ "$MODE" != "search" ] && [ "$MODE" != "modify" ] && error_exit "Mode must be 'search' or 'modify'"
[ "$MODE" = "search" ] && [ -z "$VALUE" ] && error_exit "Value required for search mode"
[ "$MODE" = "modify" ] && [ -z "$VALUE" ] && error_exit "New value required for modify mode"

echo -e "${CYAN}Project: $PROJECT_KEY | Field: $FIELD_NAME | Mode: $MODE${NC}"

get_credentials
test_auth
normalize_field

if [ "$MODE" = "search" ]; then
    search_issues
else
    modify_issues
fi
