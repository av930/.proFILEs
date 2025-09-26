#!/bin/bash

LOG_FILE="$(dirname "$0")/mcp.log"

# Read request line
IFS= read -r REQ_LINE || { echo "[$(date '+%F %T')] Empty connection" >> "$LOG_FILE"; exit 0; }
set -- $REQ_LINE
METHOD=$1
REQ_PATH=$2

echo "[$(date '+%F %T')] Request: $REQ_LINE" >> "$LOG_FILE"

# Parse headers, especially Content-Length
CONTENT_LENGTH=0
while IFS= read -r line; do
    [[ "$line" == $'\r' || -z "$line" ]] && break
    case "$line" in
        [Cc]ontent-[Ll]ength:*)
            cl=${line#*:}
            CONTENT_LENGTH=${cl//[^0-9]/}
            ;;
    esac
done

echo "[$(date '+%F %T')] Content-Length: $CONTENT_LENGTH" >> "$LOG_FILE"

if [[ "$METHOD" == "GET" && "$REQ_PATH" == "/sse" ]]; then
    # Open SSE stream with proper keepalive
    echo -ne "HTTP/1.1 200 OK\r\n"
    echo -ne "Content-Type: text/event-stream\r\n"
    echo -ne "Cache-Control: no-cache\r\n"
    echo -ne "Connection: keep-alive\r\n"
    echo -ne "\r\n"

    echo "[$(date '+%F %T')] SSE stream opened" >> "$LOG_FILE"

    # Send initial event
    echo -ne "event: ready\n"
    echo -ne "data: {\"status\":\"connected\"}\n\n"

    # Keepalive loop - essential for MCP SSE
    while :; do
        sleep 10 || break
        echo -ne ": keepalive $(date +%s)\n\n" || break
    done

    echo "[$(date '+%F %T')] SSE stream closed" >> "$LOG_FILE"
    exit 0
elif [[ "$METHOD" == "POST" && "$REQ_PATH" == "/sse" ]]; then
    # Read POST body using Content-Length
    body=""
    if (( CONTENT_LENGTH > 0 )); then
        # Try to read exact content length
        if command -v dd >/dev/null 2>&1; then
            body=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
        else
            # Fallback: read character by character
            for ((i=0; i<CONTENT_LENGTH; i++)); do
                IFS= read -r -n1 ch || break
                body+="$ch"
            done
        fi
    else
        # Fallback to line read
        IFS= read -r body || true
    fi

    echo "[$(date '+%F %T')] POST body (len=${#body}): $body" >> "$LOG_FILE"

    # Parse JSON without jq (fallback)
    if command -v jq >/dev/null 2>&1; then
        id=$(echo "$body" | jq -r '.id // null')
        method=$(echo "$body" | jq -r '.method // ""')
    else
        # Simple bash parsing
        id="null"
        method=""

        # Extract id
        if [[ $body == *'"id":'* ]]; then
            tmp=${body#*'"id":'}
            tmp=${tmp# * }  # skip spaces
            if [[ $tmp == '"'* ]]; then
                tmp=${tmp:1}  # remove opening quote
                id='"'${tmp%%'"'*}'"'  # extract until closing quote
            else
                # extract number until comma or }
                id=${tmp%%,*}  # try comma first
                id=${id%%\}*}  # then try }
            fi
        fi

        # Extract method
        if [[ $body == *'"method":'* ]]; then
            tmp=${body#*'"method":'}
            tmp=${tmp# * }  # skip spaces
            if [[ $tmp == '"'* ]]; then
                tmp=${tmp:1}  # remove opening quote
                method=${tmp%%'"'*}  # extract until closing quote
            fi
        fi
    fi

    echo "[$(date '+%F %T')] Parsed - method: $method, id: $id" >> "$LOG_FILE"

    # Generate response based on method
    case "$method" in
        "initialize")
            response='{"jsonrpc":"2.0","result":{"capabilities":{}},"id":'$id'}'
            ;;
        "hello")
            response='{"jsonrpc":"2.0","result":"world","id":'$id'}'
            ;;
        "bye")
            response='{"jsonrpc":"2.0","result":"what??","id":'$id'}'
            ;;
        "shutdown")
            response='{"jsonrpc":"2.0","result":null,"id":'$id'}'
            ;;
        *)
            response='{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":'$id'}'
            ;;
    esac

    echo "[$(date '+%F %T')] Sending response: $response" >> "$LOG_FILE"

    # Send HTTP response
    echo -ne "HTTP/1.1 200 OK\r\n"
    echo -ne "Content-Type: application/json\r\n"
    echo -ne "Cache-Control: no-cache\r\n"
    echo -ne "Content-Length: ${#response}\r\n"
    echo -ne "\r\n"
    echo -ne "$response"
    exit 0
else
    echo -ne "HTTP/1.1 404 Not Found\r\n"
    echo -ne "Content-Type: text/plain\r\n"
    echo -ne "Cache-Control: no-cache\r\n"
    echo -ne "\r\n"
    echo -ne "Not a valid endpoint.\n"
    echo "[$(date '+%F %T')] Invalid request: METHOD=$METHOD PATH=$REQ_PATH" >> "$LOG_FILE"
    exit 0
fi