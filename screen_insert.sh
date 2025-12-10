#!/bin/bash

# STY는 screen 실행시 생성되는 환경변수, WINDOWS는 현재 창번호 저장함.
[ -z "$STY"    ] && { echo "Error: Not running inside screen session.";   exit 1; }
[ -z "$WINDOW" ] && { echo "Error: WINDOW environment variable not set."; exit 1; }

#다음 window를 현재 window번호에 +1
CURRENT_WINDOW=$WINDOW
TARGET_WINDOW=$((CURRENT_WINDOW + 1))

# 현존하는 windows의 이름을 모두 가져옴
WINDOWS_OUTPUT=$(screen -Q windows)
# Fallback: just create a window
[ -z "$WINDOWS_OUTPUT" ] && { screen -X screen; exit 0; }

# windows번호를 뽑아냄(3개면 1,2,3 으로 구성)
# Using grep -oP to find numbers at start of word followed by screen flags
WINDOW_LIST=$(echo "$WINDOWS_OUTPUT" | grep -oP '(?<=\s|^)\d+(?=[*@!$(-]|\s|$)')

# 예를 들어 신규 target windows를 3번에 생성하기전에, 기존에 있던 3,4,5창을 4,5,6으로 만들어 놓는다.
SORTED_WINDOWS=$(echo "$WINDOW_LIST" | tr ' ' '\n' | sort -rn | uniq)
for win in $SORTED_WINDOWS; do
    if [ "$win" -ge "$TARGET_WINDOW" ]; then
        NEW_WIN=$((win + 1))
        screen -X at "$win" number "$NEW_WIN"
    fi
done

# 신규창을 생성하면 3번이 비워있으므로 screen이 자동으로 3번에 windows를 만들게 된다.
screen -X screen
