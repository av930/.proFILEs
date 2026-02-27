# GitHub Copilot 커스텀 인스트럭션

## 인증 정보

사내시스템 인증이 필요할때는 source repp; revv server show 명령을 실행후 그 결과값을 가지고 account와 api-key를 획득하여 사용
이때 반드시 사용자에게 가져오겠다고 물어보고 진행

인증정보는 script안에 코드로 넣지 말고, 필요하다면 전역변수로 받아서 처리하도록 함.

---

## Bash Script 코딩 형식

### 조건문 작성 규칙
- **권장**: 간단한 조건문은 `&&`와 `||` 연산자 사용
  ```bash
  [ "$str" = "string" ] && echo "matched"
  [ "$str" != "string" ] && echo "not matched" || echo "matched"
  ```

- **권장**: if else구문에서 각 1줄로 표현할수 있는 조건문은 then과 else의 indentation을 동일하게 유지
  ```bash
  if [ "$str" = "string" ];
  then echo "matched"
  else echo "unmatched"
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

### Bash 일반 모범 사례
- **변수는 항상 따옴표로 감싸기**: `"$variable"` 또는 `"${variable}"`
  - 예외: 의도적으로 word splitting이 필요한 경우 (매우 드묾)
- 고급 조건문은 `[ ]` 대신 `[[ ]]` 사용
- 명령어 치환은 백틱 대신 `$(command)` 사용

### 스크립트 헤더
- 항상 shebang으로 시작: `#!/bin/bash`
- 엄격한 오류 처리: `set -euo pipefail`
  - `-e`: 명령어 실패 시 즉시 종료
  - `-u`: 미정의 변수 사용 시 오류
  - `-o pipefail`: 파이프라인 중 하나라도 실패하면 전체 실패
- 스크립트 목적을 설명하는 주석 추가

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
- 함수 매개변수( $1, $2, ... $@ 등등)가 있는경우 함수 시작부분에서 `local` 변수에 할당해서 사용
- 간단한 주석으로 함수 목적 설명
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

### 성능 최적화
- 불필요한 파이프 체인 지양
- `cat file | grep pattern` 대신 `grep pattern file` 사용
- 부분 문자열 추출 시 외부 명령 대신 내장 기능 사용: `"${var:start:length}"`
- 여러줄의 echo 대신 printf "multi-line" 구문을 사용을 먼저 검토

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
- 복잡한 로직에는 설명 주석 추가
- 함수 파라미터 설명
- TODO, FIXME 마커 사용

### 보안
- 사용자 입력 검증 및 이스케이프
- 비밀번호/토큰을 스크립트에 하드코딩 금지
- 파일 권한 주의: 중요 파일은 `chmod 600`

---

*이 인스트럭션은 이 워크스페이스의 모든 AI 기반 코드 생성에 적용됩니다.*
