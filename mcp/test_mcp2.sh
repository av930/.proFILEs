#!/bin/bash

# MCP Server Automated Test Suite
# Tests both hello and retrigger handlers with expected result comparison

# Note: Removed 'set -e' to prevent script from exiting on individual test failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
HELLO_PORT=8001
RETRIGGER_PORT=8002
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Utility functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
}

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
    ((TEST_COUNT++))
}

# Check if server is running
check_server() {
    local port=$1
    local response
    # Use POST request with timeout to avoid hanging on SSE connection
    response=$(timeout 3 curl -s --connect-timeout 2 --max-time 3 -X POST "http://localhost:$port/sse" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"tools/list","id":"health-check"}' 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log_fail "Server not responding on port $port"
        echo "Please start the MCP server first: cd core && ./mcp_server.sh"
        echo "Debug: Trying to connect to localhost:$port"
        exit 1
    fi

    # Check if response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_fail "Server on port $port returned invalid JSON"
        echo "Response: $response"
        exit 1
    fi
}

# Execute test and compare result
run_test() {
    local test_name="$1"
    local port="$2"
    local request="$3"
    local expected_pattern="$4"
    local check_type="${5:-contains}" # contains, equals, regex

    log_test "$test_name"

    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 -X POST "http://localhost:$port/sse" \
        -H "Content-Type: application/json" \
        -d "$request" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log_fail "$test_name - Connection failed"
        return 1
    fi

    # Parse JSON response
    if ! echo "$response" | jq -c . >/dev/null 2>&1; then
        log_fail "$test_name - Invalid JSON response"
        echo "  Raw response: $response"
        return 1
    fi

    response=$(echo "$response" | jq -c .)

    local result=false
    case "$check_type" in
        "contains")
            if echo "$response" | grep -q "$expected_pattern"; then
                result=true
            fi
            ;;
        "equals")
            if [ "$response" = "$expected_pattern" ]; then
                result=true
            fi
            ;;
        "regex")
            if echo "$response" | grep -qE "$expected_pattern"; then
                result=true
            fi
            ;;
        "jq")
            # expected_pattern is a jq query that should return true
            if echo "$response" | jq -e "$expected_pattern" >/dev/null 2>&1; then
                result=true
            fi
            ;;
    esac

    if [ "$result" = true ]; then
        log_success "$test_name"
        if [ "${VERBOSE:-}" = "1" ]; then
            echo "  Response: $response"
        fi
    else
        log_fail "$test_name"
        echo "  Expected: $expected_pattern"
        echo "  Got: $response"
    fi
}

# Main test execution
main() {
    echo "=================================="
    echo "MCP Server Test Suite"
    echo "=================================="

    # Check if servers are running
    log_info "Checking server status..."
    check_server $HELLO_PORT
    check_server $RETRIGGER_PORT
    log_info "Both servers are running"

    echo
    echo "=== Hello Handler Tests (Port $HELLO_PORT) ==="

    # Test 1: Hello handler tools list
    run_test "Hello - Tools List" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"tools/list","id":1}' \
        '.result.tools | length == 2 and .[0].name == "tool-hello" and .[1].name == "tool-bye"' \
        "jq"

    # Test 2: Hello with name parameter
    run_test "Hello - With Name" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-hello","arguments":{"name":"World"}},"id":2}' \
        '.result.content[0].text == "Hello, World"' \
        "jq"

    # Test 3: Hello without name parameter
    run_test "Hello - Without Name" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-hello"},"id":3}' \
        '.result.content[0].text == "Hello"' \
        "jq"

    # Test 4: Bye tool
    run_test "Hello - Bye Tool" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-bye"},"id":4}' \
        '.result.content[0].text == "what??"' \
        "jq"

    echo
    echo "=== Retrigger Handler Tests (Port $RETRIGGER_PORT) ==="

    # Test 5: Retrigger handler tools list
    run_test "Retrigger - Tools List" $RETRIGGER_PORT \
        '{"jsonrpc":"2.0","method":"tools/list","id":5}' \
        '.result.tools | length == 2 and .[0].name == "tool-jenkins" and .[1].name == "tool-gerrit"' \
        "jq"

    # Test 6: Jenkins without parameter
    run_test "Jenkins - No Parameter" $RETRIGGER_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-jenkins"},"id":6}' \
        '.result.content[0].text == "Please input Jenkins url"' \
        "jq"

    # Test 7: Jenkins with URL parameter
    run_test "Jenkins - With URL" $RETRIGGER_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-jenkins","arguments":{"name":"http://test.example.com"}},"id":7}' \
        '.result.content[0].text | test("Jenkins job is (re-triggered|waiting queued|failed)")' \
        "jq"

    # Test 8: Gerrit tool
    run_test "Gerrit - Tool Call" $RETRIGGER_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-gerrit","arguments":{"name":"Test User"}},"id":8}' \
        '.result.content[0].text == "Hello"' \
        "jq"

    echo
    echo "=== Error Handling Tests ==="

    # Test 9: Unknown method
    run_test "Error - Unknown Method" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"unknown/method","id":9}' \
        '.error.code == -32601 and (.error.message | contains("Method not found"))' \
        "jq"

    # Test 10: Unknown tool
    run_test "Error - Unknown Tool" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"unknown-tool"},"id":10}' \
        '.error.code == -32602 and (.error.message | contains("Unknown tool"))' \
        "jq"

    echo
    echo "=== Response Format Tests ==="

    # Test 11: JSON-RPC 2.0 format validation
    run_test "Format - JSON-RPC 2.0" $HELLO_PORT \
        '{"jsonrpc":"2.0","method":"tools/list","id":"test-string-id"}' \
        '.jsonrpc == "2.0" and .id == "test-string-id"' \
        "jq"

    # Test 12: Content type validation
    run_test "Format - Content Type" $RETRIGGER_PORT \
        '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"tool-gerrit"},"id":12}' \
        '.result.content[0].type == "text"' \
        "jq"

    echo
    echo "=================================="
    echo "Test Results Summary"
    echo "=================================="
    echo "Total Tests: $TEST_COUNT"
    echo -e "Passed: ${GREEN}$PASS_COUNT${NC}"
    echo -e "Failed: ${RED}$FAIL_COUNT${NC}"

    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "${GREEN}All tests passed! ✅${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed! ❌${NC}"
        exit 1
    fi
}

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose    Show detailed response output"
    echo "  -h, --help       Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  VERBOSE=1        Enable verbose output"
    echo ""
    echo "Examples:"
    echo "  $0               Run all tests"
    echo "  $0 -v            Run tests with verbose output"
    echo "  VERBOSE=1 $0     Run tests with verbose output"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main