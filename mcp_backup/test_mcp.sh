#!/bin/bash
# MCP Server Test Script

SERVER_URL="http://10.159.47.21:8000/sse"



echo "=== MCP 서버 테스트 시작 ==="
echo

echo "1. Initialize 테스트:"
curl -s -X POST "$SERVER_URL" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | jq .
echo

echo "2. Hello 테스트:"
curl -s -X POST "$SERVER_URL" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":2,"method":"hello"}' | jq .
echo

echo "3. Bye 테스트:"
curl -s -X POST "$SERVER_URL" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":3,"method":"bye"}' | jq .
echo

echo "4. Shutdown 테스트:"
curl -s -X POST "$SERVER_URL" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":4,"method":"shutdown"}' | jq .
echo

echo "5. 잘못된 메소드 테스트:"
curl -s -X POST "$SERVER_URL" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":5,"method":"invalid"}' | jq .
echo


timeout 5 curl -v "$SERVER_URL"

echo "=== 테스트 완료 ==="