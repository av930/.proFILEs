---
description: "Always load common Copilot instructions from mounted profile for every chat request"
applyTo: "**"
---

# GitHub Copilot 커스텀 인스트럭션

## ⚠️ Chat창에 대해한 최우선 필수 지침 (AI 사고 과정 노출)
1. **사고 과정 한글 출력**: 문제를 분석하고 해결책을 찾는 모든 사고(Thinking) 과정과 결과값은 반드시 **한글**로 출력해야 합니다.
2. **숨김(Folding) 방지 및 명시적 출력**: UI에서 사용자가 바로 볼 수 있도록, 답변 메시지 최상단에 항상 일반 텍스트 형태(예: `### 사고 과정`)로 생각과 계획을 펼쳐서(Unfold) 먼저 작성한 후 다른 작업을 진행하십시오.
3. 모든 질문은 copilot-instructions.md 파일이 존재하는 dir에 prompt-오늘날짜.txt 형식으로 기록을 남겨주고, 최소 3일이상 보관해줘. 그 이후에는 삭제해도 좋아.
4. chat창의 보여주는 모든 코드는 무조건 UTF-8 인코딩으로 작성해줘.


## 서버 인증 및 계정 정보

Gerrit, Jenkins, 및 기타 또는 등록된 원격 서버에 대한 인증 정보(계정, HTTP 키/비밀번호, 서버 URL)가 필요한 경우에는
**절대로 정보를 하드코딩하거나 추측하지 말고, 항상 `revvserver show` 명령으로 조회할 것.**

### 인증 정보 조회 방법

터미널에서 아래 명령을 실행하면 등록된 모든 서버와 계정/키 정보를 확인할 수 있다.

`revvserver` 는 `~/.proFILEs/tools/revvserver` 경로에 있는 독립 실행 스크립트이며,
`repp` 가 source 된 상태의 `revv server <subcmd>` 와 동일하게 사용할 수 있다.

```bash
revvserver show              # revv server show 와 동일
revvserver de <server_key>   # revv server de <server_key> 와 동일
revvserver check             # revv server check 와 동일
revvserver gen               # revv server gen 와 동일
revvserver en                # revv server en 와 동일
revvserver edit              # revv server edit 와 동일
revvserver status            # revv server status 와 동일
revvserver help              # revv server help 와 동일
```

### 서버 키 이름(alias)

`~/.key_server.en` 에 등록된 대표 서버 키:

| Tag          | Alias            | 설명                  |
| ------------ | ---------------- | ------------------- |
| `vgit_29420` | `na`, `vgit_na`  | Gerrit NA 지역        |
| `vgit_29430` | `eu`, `vgit_eu`  | Gerrit EU 지역        |
| `vgit_29440` | `as`, `vgit_as`  | Gerrit AS 지역        |
| `lamp_29418` | `review`, `lamp` | lamp.lge.com review |


## Terminal 설정
작업중에 terminal로 직접 실행이 필요하다면 hide시키지 말고 **focus** 해서 보이도록 합니다.
---

## Bash Script 코딩 형식
- 기본적으로 code를 최대한 compact하게 작성해줘.
- 필요없은 로그나 조건문을 최초코드를 제안해줄때는 무조건 제거해줘.

    
### 조건문 작성 규칙
- **권장**: 간단한 `if/fi`조건문은 `&&`와 `||` 연산자 사용
  ```bash
  [ "$str" = "string" ] && echo "matched"
  [ "$str" != "string" ] && echo "not matched" || echo "matched"
  [ "$str" != "string" ] && { echo "not matched"; exit 0; } || { echo "matched"; exit 1; }
  ```

- **권장**: if else구문에서 각 1줄로 표현할수 있는 조건문은 then과 else의 indentation을 동일하게 유지
  ```bash
  if [ "$str" = "string" ];
  then echo "matched"
  else echo "unmatched"
  fi
  ```

- **권장**: if/elif/else 각 분기의 조건과 실행문이 모두 1줄로 표현 가능한 경우, `then`을 조건식과 같은 줄에 놓고 실행문을 `then` 뒤에 작성. 조건식들의 길이가 다를 경우 `then` 키워드를 공백으로 align 맞춤. 주석은 실행문 뒤에 인라인으로 작성하고 가능하면 align 맞춤.
  ```bash
  if   [[ "$local_head" == "$remote_head" ]];                   then head_status="HEAD_SAME"      # local == remote: 이미 동기화됨
  elif git merge-base "$local_head" "$remote_head" 2>/dev/null; then head_status="HEAD_REMOTE"    # local이 remote의 ancestor → remote가 앞서있음
  else head_status="HEAD_UNRELATED"                                                               # 공통 조상 없음 (unrelated histories)
  fi
  ```

- **권장**: if elif else if 구문을 case로 표현할수 있으면, case 구문으로 우선 표현
1. case 구문에서 각 case 경우 두번째 경우부터는 ;;를 앞쪽에 위치
2. 각 경우의 경우1) 경우2)의 )에 문자에 대한 align맞출것
  ```bash
  case $str in
     aaa) echo "aaa"
  ;; bbb) echo "bbb"
  esac
  ```

- **권장**: then/else 블록의 마지막 줄이 단순 `return <값>` 또는 `exit <값>` 만 존재하는 경우, 앞 줄과 `;`로 합치고 `return`/`exit` 키워드를 3 space이상을 띄워서 align 맞춰 작성
  ```bash
  # 변경 전
  then some_command
       return 0
  else other_command
       return 1

  # 변경 후
  then some_command;   return 0
  else other_command;  return 1
  ```
### 반복문 작성 규칙
- for, while 구문이후 do keyword는 같은 line에 넣어줘.
  ```bash
  for item in "${arr[@]}"; do
      echo "$item"
  done

  while [ "$count" -lt 10 ]; do
      count=$((count + 1))
  done
  ```

### Bash 일반 모범 사례
- **변수는 항상 따옴표로 감싸기**: `"$variable"` 또는 `"${variable}"`
  - 예외: 의도적으로 word splitting이 필요한 경우 (매우 드묾)
- 고급 조건문은 `[ ]` 대신 `[[ ]]` 사용
- 명령어 치환은 백틱 대신 `$(command)` 사용
- **개행 문자**:
  - 기본적으로 Linux/Cygwin 방식인 LF(`\n`) 사용
  - Windows CMD/PowerShell에서만 필요 시 CRLF(`\r\n`) 사용

### 스크립트 헤더
- 항상 shebang으로 시작: `#!/bin/bash`
- 엄격한 오류 처리: `set -euo pipefail`
  - `-e`: 명령어 실패 시 즉시 종료
  - `-u`: 미정의 변수 사용 시 오류
  - `-o pipefail`: 파이프라인 중 하나라도 실패하면 전체 실패
- 스크립트 목적을 설명하는 주석을 맨위에 추가
- 주석은 모두 한글로 표기, 코드(로그포함)는 모두 영어로 표기
- 코드 여러줄을 블럭단위로 묶어서 코드의 의도를 주석으로 표기해줘.

### 변수 사용
- 변수 선언 시 `local` 키워드 사용 (함수 내)
- 읽기 전용 변수는 `readonly` 사용
- 상수는 대문자로 작성: `readonly MAX_RETRY=3`
- 일반 변수는 소문자와 언더스코어: `user_name="alice"`
- **변수 참조는 항상 따옴표로 감싸기**: `"$variable"` 또는 `"${variable}"`
  - 따옴표 없이 사용 시 word splitting과 globbing 발생 (위험)
  - 중괄호 `${}`는 변수명 명확화 시 유용: `"${var}_suffix"`, `"${array[0]}"`
- **디렉토리/경로 변수**: `PATH_` 접두사 사용 (예: `PATH_OUTPUT`, `PATH_SOURCE`, `PATH_BUILD`, `PATH_TEMP`)
- **다른 변수 타입**: 설명적인 접두사 사용 (`FILE_`, `ARG_`, `FLAG_`, `NUM_` 등)

### 함수 작성
- 함수명은 소문자와 언더스코어 사용: `check_file_exists()`
- 함수 시작 부분에 `local` 변수 선언
- local 변수로 선언된 변수가 여러개이고 초기값이 없는 변수는 한줄에 모두 선언해줘.
- 함수 매개변수( $1, $2, ... $@ 등등)가 있는경우 함수 시작부분에서 `local` 변수에 할당해서 사용
- 간단한 주석으로 함수 목적 설명
- 3줄이하의 함수는 1줄로 간단하게 목적만 설명을 한다.
- 3줄이상의 모든 함수의 주석은 아래와 같은 형식으로 추가한다.
```bash
function func_example(){
#----------------------------------------------------------------------------------------------------------
# 함수는 반드시 2줄로 목적을 먼저기술하고 필요시 주의점을 기술한다.
# 입력: 입력 파라미터
# 출력: 출력내용
```
- 함수 종료시 반드시 반환값이  `return` (숫자) 또는 `echo` (문자열) 로 리턴되도록 작성
```bash
# 파일 존재 여부 확인
check_file_exists() {
    local file_path="$1"
    [[ -f "$file_path" ]] && return 0 || return 1
}
```

### 오류 처리
- 중요한 명령어 후 상태 체크: `command || handle_error`
- 파일/디렉토리 존재 여부 확인 후 사용
- 사용자 입력 검증 필수
```bash
[[ -z "$input" ]] && { echo "Error: input required"; exit 1; }
```

### 파일 및 디렉토리 작업
- 파일 테스트 연산자 활용:
  - `-f`: 파일 존재
  - `-d`: 디렉토리 존재
  - `-r`: 읽기 가능
  - `-w`: 쓰기 가능
  - `-x`: 실행 가능
- 임시 파일 생성 시 `mktemp` 사용
- 디렉토리 생성 시 `mkdir -p` 사용 (부모 디렉토리 자동 생성)

### 문자열 처리
- `[[ ]]` 내에서 패턴 매칭 사용
- 문자열 비교: `=` (같음), `!=` (다름)
- 빈 문자열 체크: `-z` (빈 문자열), `-n` (비어있지 않음)
```bash
[[ "$str" =~ ^[0-9]+$ ]] && echo "숫자입니다"
```

### 배열 사용
- 배열 선언: `arr=("item1" "item2" "item3")`
- 배열 접근: `"${arr[0]}"`
- 모든 요소 (각각 분리): `"${arr[@]}"` - for 루프나 함수 인자 전달 시
- 모든 요소 (하나의 문자열): `"${arr[*]}"` - 출력이나 결합 시
- 배열 길이: `"${#arr[@]}"`

### 입출력
- 표준 출력과 표준 에러 분리
  - 정상 메시지: `echo "message"`
  - 에러 메시지: `echo "error" >&2`
- 명령어 출력 저장: `output=$(command)`
- 리다이렉션 적절히 활용: `>`, `>>`, `2>&1`
- **상태 표시 문자**: terminal encoding에 따라 깨질 수 있는 Unicode 기호(✓, ✗, ⚠, ✅,1️⃣) 대신 
색상을 적용한 numbering 문자/숫자(ⓐⓑ..., ①②...)나 4글자 ASCII 문자열 사용
  - `✓` 대신 `[OKAY]` — 녹색 (`\033[92m\033[1m`)
  - `✗` 대신 `[FAIL]` — 빨간색 (`\033[91m\033[1m`)
  - `⚠` 대신 `[WARN]` — 노란색 (`\033[93m\033[1m`)
  - 라벨(`[OKAY]` 등)에만 색상을 적용하고, 이후 메시지는 흰색(`COLOR_RESET`)으로 출력
  ```bash
  COLOR_GREEN="\033[92m\033[1m"
  COLOR_RED="\033[91m\033[1m"
  COLOR_YELLOW="\033[93m\033[1m"
  COLOR_RESET="\033[0m"

  echo -e "${COLOR_GREEN}[OKAY]${COLOR_RESET} 연결 성공"
  echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} 연결 실패"
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} 인증서 경고"
  ```

### 성능 최적화
- 불필요한 파이프 체인 지양
- `cat file | grep pattern` 대신 `grep pattern file` 사용
- 부분 문자열 추출 시 외부 명령 대신 내장 기능 사용: `"${var:start:length}"`

### 스크립트 종료
- 성공: `exit 0`
- 실패: `exit 1` (또는 특정 에러 코드)
- trap 구문 대신 script 시작 시 임시파일 정리 코드를 넣고, 불가능할 때만 trap 사용
```bash
# trap 대신 권장 방식, 함수 시작부분에서 이전 작업의 결과물 삭제
[[ -f "$temp_file" ]] && rm -f "$temp_file"
temp_file=$(mktemp)

# trap이 필요한 경우, exit이나 error등의 exception을 받아서 처리해야 하는 경우만
exit_handler() { analyze "$log_file"; }
trap exit_handler EXIT
```

### 주석 및 문서화
- 코드 3~7줄마다 중간중간 1줄짜리 주석추가하여 코드흐름을 파악할수 있도록할것.
- 함수 파라미터 설명
- TODO, FIXME 마커 사용
- 주석및 문서화작업할때 usage 함수가 없으면 아래와 같은 형식(usage, example, output)으로 함수를 추가할것 
```
usage() {
        cat <<-EOF
		usage: $(basename "$0") <root_dir> [options]
		    root_dir     : Target repo project root directory
		    -t TIMEOUT   : URL access timeout (seconds, default: 10)
		    -h           : Show this help
		example:
		    $(basename "$0") /path/to/source -t 4 
			
		output:
		    OKAY /path/to/file.bb  http://example.com/file.tar.gz			
EOF
        exit 1
}

```

### AI 응답 및 결과 출력 규칙
- 코드 수정 후에는 항상 수정된 내용의 `diff` (변경 사항 부분)를 볼수 있도록 button을 표시해줘.

### 보안
- 사용자 입력 검증 및 이스케이프
- 비밀번호/토큰을 스크립트에 하드코딩 금지
- 파일 권한 주의: 중요 파일은 `chmod 600`


## JSON 포맷팅 규칙

이 설정 워크스페이스의 모든 JSON 파일에 아래 규칙을 적용한다.

1. 파일 인코딩은 UTF-8을 사용한다.
2. 들여쓰기는 공백 4칸을 사용한다.
3. `:` 뒤에는 공백 1칸만 사용한다.
4. 값을 맞추기 위한 추가 공백 정렬은 사용하지 않는다.
5. 객체(object)는 한 줄에 하나의 key-value만 작성한다.
6. 배열(array)은 항목이 2개 이상이면 여러 줄로 작성한다.
7. 줄 끝 공백(trailing whitespace)과 trailing comma를 제거한다.
8. 기능 변경이 필요한 경우가 아니면 key 순서를 유지한다.
9. Windows 경로 등 JSON 이스케이프를 올바르게 유지한다(예: `\\`).
10. 별도 요구가 없는 한 strict JSON을 유지한다(JSONC 주석 금지).



---

*이 인스트럭션은 이 워크스페이스의 모든 AI 기반 코드 생성에 적용됩니다.*

---

## 공용 적용/백업 규칙
- 이 파일(c:/Users/USER/AppData/Roaming/Code/User/prompts/vscode.instructions.md)은 local/remote project와 무관하게 항상 공용으로 사용한다.
- 이 파일이 수정될 때마다 반드시 백업을 아래 경로에 갱신한다.
  - D:/.gradle/OneDrive/_MyProgram/HOME/vscode/copilot-instructions.md

