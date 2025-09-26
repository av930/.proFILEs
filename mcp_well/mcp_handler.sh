#!/bin/bash

LOG="$(dirname "$0")/mcp.log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Read request and headers
IFS= read -r REQ || exit 0
set -- $REQ; METHOD=$1 REQ_PATH=$2
log "Request: $REQ"

CONTENT_LENGTH=0
while IFS= read -r H; do
    [[ -z "$H" || "$H" == $'\r' ]] && break
    [[ "$H" =~ [Cc]ontent-[Ll]ength:* ]] && CONTENT_LENGTH=${H//[^0-9]/}
done

if [[ "$METHOD" == "GET" && "$REQ_PATH" == "/sse" ]]; then
    printf "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
    printf "event: ready\ndata: {\"status\":\"connected\"}\n\n"
    log "SSE opened"
    while :; do sleep 10 && printf ": keepalive $(date +%s)\n\n" || break; done
    log "SSE closed"; exit 0
elif [[ "$METHOD" == "POST" && "$REQ_PATH" == "/sse" ]]; then
    # Read body
    body=""
    if (( CONTENT_LENGTH > 0 )); then
        if command -v dd >/dev/null 2>&1; then
            body=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
        else
            # Read byte by byte fallback
            for ((i=0; i<CONTENT_LENGTH; i++)); do
                IFS= read -r -n1 ch || break
                body+="$ch"
            done
        fi
    else
        IFS= read -r body
    fi
    log "Body: $body"

    # Simple JSON parsing
    method="" id=null
    [[ $body =~ \"method\":[[:space:]]*\"([^\"]+)\" ]] && method="${BASH_REMATCH[1]}"
    [[ $body =~ \"id\":[[:space:]]*([0-9]+) ]] && id="${BASH_REMATCH[1]}"
    [[ $body =~ \"id\":[[:space:]]*\"([^\"]+)\" ]] && id="\"${BASH_REMATCH[1]}\""

    # Generate response
    case "$method" in
        initialize) resp='{"jsonrpc":"2.0","result":{"capabilities":{}},"id":'$id'}' ;;
        hello)      resp='{"jsonrpc":"2.0","result":"world","id":'$id'}' ;;
        bye)        resp='{"jsonrpc":"2.0","result":"what??","id":'$id'}' ;;
        shutdown)   resp='{"jsonrpc":"2.0","result":null,"id":'$id'}' ;;
        *)          resp='{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":'$id'}' ;;
    esac

    log "Response: $resp"
    printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${#resp}\r\n\r\n$resp"
    exit 0
else
    printf "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found\n"
    log "404: $METHOD $REQ_PATH"
fi