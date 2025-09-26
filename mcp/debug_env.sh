#!/bin/bash
echo "=== Environment Debug ==="
echo "PATH: $PATH"
echo "PWD: $PWD"
echo "USER: $USER"
echo "SHELL: $SHELL"
echo "=== Command Check ==="
echo "date: $(which date 2>/dev/null || echo 'NOT FOUND')"
echo "head: $(which head 2>/dev/null || echo 'NOT FOUND')"
echo "dd: $(which dd 2>/dev/null || echo 'NOT FOUND')"
echo "sleep: $(which sleep 2>/dev/null || echo 'NOT FOUND')"
echo "=== Direct Test ==="
if command -v date >/dev/null 2>&1; then
    echo "date works: $(date)"
else
    echo "date command not found"
fi
echo "========================"