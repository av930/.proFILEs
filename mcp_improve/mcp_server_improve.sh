#!/bin/bash

PORT=8002
HANDLER="$(dirname "$0")/mcp_handler_improve.sh"
LOG="$(dirname "$0")/mcp_improve.log"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
log "=== MCP Improved Server Starting on port $PORT ==="

> $LOG
while true; do
    log "Starting socat listener..."
    socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:"$HANDLER" 2>&1 | tee -a "$LOG"

    log "Server stopped, restarting in 2 seconds..."
    sleep 2
done