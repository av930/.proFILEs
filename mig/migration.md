# Migration Scripts Prompt Document

> **목적**: 이 문서는 migration 디렉토리의 각 Bash 스크립트를 AI 프롬프트를 통해 재생성하거나 수정하기 위한 요구사항 명세서입니다.
> **사용법**: 아래 각 섹션을 AI에게 프롬프트로 제공하면 해당 스크립트를 재생성할 수 있습니다.
> **코드 형식**: 모든 스크립트는 `.proFILEs`의 [`copilot-instructions.md`](../.github/copilot-instructions.md) 에 정의된 **Bash Script 코딩 형식**을 엄격히 준수하여 작성합니다.

---

## 전체 워크플로우 개요

**구형 소스(ori)를 신형 소스(new)로 마이그레이션**하기 위한 전체 workflow 입니다. migration dir아래 사용 script 기술
01. ORI 소스다운(10): migration이 필요한 현재 project 소스(ORI)를 다운받는다.
02. CHIP 소스다운(11): chipset 제조사의 신규 소스(CHIP)를 다운받는다. - down-src.sh 사용
03. CHIP 소스분리(20): 신규 소스(CHIP)중 용량이 큰 1개의 git소스를 여러개의 git으로 분리한다. -split-git.sh (split) 사용
04. 분리된소스 manifest생성(21): 분리된 여러개의 git에 대해서 manifest(xml)를 생성한다. -split-git.sh (mani) 사용
05. 분리된소스 remote등록(22): 분리된 여러개의 git에 대해서 업로드를 위해 remote를 등록한다. -split-git.sh (verify) 사용
06. 분리된소스 upload(23): 분리된 여러개의 git에 대해서 업로드를 진행한다. -split-git.sh (push) 사용
07. CHIP 소스 통합 manifest생성(30): 다운받은 모든소스를 분석후 repo 구동을 위한 manifest(merged-manifest.xml)를 생성한다. merge-mani.sh 사용
08. mirror생성 (31): 생성된 Manifest의 repo로 동작하기 위해 모든 project에 대한 mirror를 만든다.(symbolic link이용) - merge-mirror.sh 사용
09. NEW 소스생성 (32): CHIP소스의 repo version인 신규소스(NEW)를 repo init으로 만든다 (repo구조 확인).
10. remote연결 manifest생성 (40): ORI소스의 repo 구조에 맞게 NEW소스를 push하기 위해 gen-fin.xml만듦. - merge-xml.sh 사용
11. remote및 commit검사 (41): gen-fin.xml을 기준으로 NEW소스를 push하기 위해 모든 git의 remote,branch,commit상태 검사. - check-repo.sh 사용
12. remote push (42):gen-fin.xml을 기준으로 NEW소스를 실제 remote의 지정한 branch로 push - push-repo.sh 사용



### 아래 스크립트들은 이 과정에서 사용되는 script들입니다.
```
[1] down-src.sh       : 소스 다운로드 (git clone / repo sync) - 병렬 실행
[2] split-git.sh      : 단일 git 저장소를 서브디렉토리 기준으로 분리
[3] merge-mani.sh     : 여러 manifest XML을 하나의 통합 manifest로 병합
[4] merge-mirror.sh   : 다운로드된 .git들을 mirror/merged dir에 심볼릭 링크로 통합하여 mirror생성
[5] merge-xml.sh      : new 소스 manifest에 ori git의 path/remote 정보를 주입 → gen-fin.xml 생성
[6] check-repo.sh     : gen-fin.xml 기준으로 각 git의 remote/branch 존재 및 HEAD 비교
[7] push-repo.sh      : check-repo.sh 결과를 기반으로 각 git을 remote에 push
```

---

## 공통 코딩 규칙 (모든 스크립트 적용)

- `#!/bin/bash` shebang 사용, `set -uo pipefail` 또는 `set -e` 적용
- 색상 출력 상수: `[OKAY]` → GREEN(`\033[92m\033[1m`), `[FAIL]` → RED(`\033[91m\033[1m`), `[WARN]` → YELLOW(`\033[93m\033[1m`)
- 파라미터 부족 시 usage를 출력하고 `exit 1`
- 로그/상태 메시지는 영어, 주석은 한글
- `readonly` 상수는 대문자, 일반 변수는 소문자 언더스코어
- 디렉토리/경로 변수는 `PATH_` 또는 `FILE_` 접두사 사용
- 조건문은 `[[ ]]` 사용, `;; ` 앞치기 방식 case 문 사용
- `if/elif/else`가 1줄이면 `then`을 같은 줄에 정렬

---

## 1. `down-src.sh` — 병렬 소스 다운로드

### 목적
`down.list` 파일에 정의된 `git clone` / `repo init+sync` 명령 블록들을 **최대 3개 동시에** 병렬로 실행하는 다운로드 관리 스크립트.

### CLI 인터페이스
```
down-src.sh <input_file> [mirror_path]
```
- `input_file`: 빈 줄로 구분된 명령 블록이 담긴 파일 (필수)
- `mirror_path`: mirror를 저장할 경로 (선택, 미입력 시 mirror 미사용)

### 입력 파일 형식
- **블록 단위**: 빈 줄로 구분된 명령 묶음 1개 = 작업 1개
- `repo init`과 `repo sync`는 같은 블록 내 여러 줄로 작성 가능
- 블록 파싱은 `awk RS=""` (paragraph mode) 사용, 여러 줄 명령은 ` ; `로 연결

### 기능 요구사항

#### 1-1. 명령어 타입 분석
- `git clone` 포함 → `cmd_type=git_clone`, 작업 디렉토리 `down.git.N`
- `repo init` 포함 → `cmd_type=repo_init`, 작업 디렉토리 `down.repo.N`
- 그 외 → `cmd_type=other`, 작업 디렉토리 `down.xxx.N`

#### 1-2. 재실행(git clone) 감지 및 자동 변환
- 명령에서 `-b <branch>` 추출, URL에서 `.git` 제외 디렉토리명 추출
- 해당 디렉토리에 `.git`이 이미 있으면: `git pull origin <branch>` 명령으로 자동 대체

#### 1-3. Mirror 처리 (MIRROR_PATH 지정 시)
- **git clone + mirror 없음**: mirror 디렉토리에 `git clone --mirror` 실행 후, `--reference <mirror_dir>`로 본 clone 실행
- **git clone + mirror 있음**: `git remote update`로 mirror 갱신 후 `--reference` clone
- **git clone + 재실행**: `git pull`로 대체
- **repo init + mirror 없음**: `<mirror_dir>`에 `repo init --mirror && repo sync` 실행 후, 본 init에 `--reference=<mirror_dir>` 추가
- **repo init + mirror 있음**: 이미 `.repo`가 있으면 mirror skip, `--reference` 옵션만 추가

#### 1-4. `--depth` 옵션 제거
- `git clone` 및 `repo init` 명령에서 `--depth=N` 또는 `--depth N` 형태 모두 제거 (shallow clone 방지)

#### 1-5. Manifest `clone-depth` 속성 제거
- `repo init -m <manifest_file>` 감지 시, `fix_manifest.sh` 스크립트를 작업 디렉토리에 자동 생성
- `fix_manifest.sh`는 `.repo/manifests/<manifest_file>`에서 `clone-depth="N"` 속성을 sed로 제거
- `repo init`과 `repo sync` 사이에 `fix_manifest.sh <manifest_file>` 실행 삽입

#### 1-6. 병렬 실행 및 Throttling
- 각 작업은 백그라운드(`&`)로 실행, PID → 로그파일/JOB_ID 매핑 관리
- `active_jobs >= MAX_JOBS(3)` 도달 시 `wait -n`으로 하나 완료 대기 후 다음 실행
- 로그는 `log/downcmd_N.log`에 저장
- 실행 시 작업별 색상(5색 순환) 적용: `[N.CMD-ORI]`, `[N.CMD-FINAL]`, `[N.RUNNING]` 출력

#### 1-7. 결과 집계
- 모든 작업 완료 후 실패 작업의 로그 내용을 화면에 출력
- 전체 성공 시 `[FINISH]`, 실패 시 `[ERROR]` 출력 후 해당 로그 출력

### 실행 전 처리
- 기존 `down_src.sh` 프로세스가 있으면 자식까지 `pkill -P`로 정리

---

## 2. `split-git.sh` — 단일 Git 저장소 분리

### 목적
하나의 git 저장소(모노레포)를 지정한 서브디렉토리 목록 기준으로 **독립된 git 저장소들로 분리**하거나, 분리 결과를 remote에 push하는 스크립트.

### CLI 인터페이스
```
CMD=<mode> WORK_DIR=<path> [REMOTE_NAME=... REMOTE_ADDR=... REMOTE_BNCH=...] [PUSH_OPT=...] \
split-git.sh <dir1> <dir2> ... <dirN>
```

### 환경변수
| 변수 | 설명 | 필수 여부 |
|------|------|-----------|
| `CMD` | 동작 모드: `split` \| `verify` \| `push` \| `custom` \| `mani` | 필수 |
| `WORK_DIR` | 분리할 원본 git 저장소 경로 | 필수 |
| `REMOTE_NAME` | remote 이름 | push/verify/mani 시 필수 |
| `REMOTE_ADDR` | remote 기본 URL (prefix) | push/verify 시 필수 |
| `REMOTE_BNCH` | push 대상 branch (예: `refs/heads/master`) | push/verify 시 필수 |
| `PUSH_OPT` | push 추가 옵션 또는 custom 모드 실행 명령 | 선택 |
| `CMD_GO` | `true`이면 go_flag 활성화 (K 접두사 대체) | 선택 |

### 모드별 동작

#### CMD=split (분리 모드)
1. `WORK_DIR` 클론 → `WORK_DIR_split/` 생성
2. `WORK_DIR_split/` 루트 git: 인수 디렉토리들 `--invert-paths`로 제거 (`git filter-repo`)
3. 각 인수 디렉토리: 별도 서브디렉토리 생성 후 클론 → `git filter-repo --subdirectory-filter` 적용
4. 분리 완료 후 `cmp-dirs.sh`로 원본 vs 분리본 비교 검증
5. 성공 시: 분리된 디렉토리 목록을 루트의 `.gitignore`에 자동 추가
6. 실패 시: rsync 수동 명령 안내 후 `exit 1`

#### CMD=verify (remote 등록 + 확인)
- 각 git에 `REMOTE_NAME` 기반 remote를 `REMOTE_ADDR/<dir>` URL로 등록 (기존 있으면 삭제 후 재등록)
- `git ls-remote HEAD`로 remote 접근 가능 여부 확인 → `[OKAY]` / `[ERR ]`
- `git ls-remote REMOTE_BNCH`로 branch 존재 여부 확인 → `[OKAY]` / `[WARN]`

#### CMD=push (push 모드)
- 각 git에서 `git push REMOTE_NAME HEAD:REMOTE_BNCH PUSH_OPT` 실행

#### CMD=custom (임의 명령 실행)
- 각 git 디렉토리를 순회하며 `PUSH_OPT`에 지정된 명령을 `eval`로 실행

#### CMD=mani (manifest 생성)
- `WORK_DIR` basename을 `path` prefix로 사용
- 루트 git + 각 인수 dir을 `<project name="prefix/dir" path="prefix/dir"/>` 형식으로 XML 생성
- `REMOTE_ADDR`가 로컬 경로(`/` 또는 `file://` 시작)이면 `fetch` 를 부모 디렉토리로 설정
- 결과 파일: `../<MANI>` (기본값: `chipcode.xml`)

### go_flag
- `CMD` 앞에 `K` 접두사 또는 `CMD_GO=true` 지정 시: `set +e`로 실패해도 계속 진행
- 기본값: 실패 시 즉시 중단

### 전제 조건
- `git-filter-repo` 설치 필요 (없으면 설치 안내 후 종료)
- split 모드: `WORK_DIR/.git` 존재 필수
- push/verify/mani 모드: `WORK_DIR/.git/filter-repo` 존재 필수 (split 완료 여부 확인)

---

## 3. `merge-mani.sh` — Manifest 파일 통합 병합

### 목적
`down.list`를 분석하여 각 다운로드 작업의 manifest XML 파일들을 **하나의 통합 manifest**로 병합하는 스크립트.

### CLI 인터페이스
```
merge-mani.sh [input_file] [output_manifest]
```
- `input_file`: 기본값 `down.list`
- `output_manifest`: 기본값 `merged-manifest.xml`

### 출력 파일
| 파일 | 설명 |
|------|------|
| `${input_file}.xml` | include manifest (중간 산출물) |
| `merged-manifest.xml` | 최종 병합된 manifest |

### 기능 요구사항

#### 3-1. down.list 분석 및 include manifest 생성
- `down.list`를 줄 단위로 읽으며 `git clone`과 `repo init` 명령 감지
- `git clone` → `down.git.N` (N: git_job_id, 1부터 증가)
- `repo init` → `down.repo.N` (N: repo_job_id, **2부터** 시작)
- `-m <file.xml>` 옵션 있으면 해당 파일, 없으면:
  - `repo init` → `default.xml`
  - `git clone` → `chipcode.xml`
- `repo init`: manifest 경로 = `down.repo.N/.repo/manifests/<file>`
- `git clone`: `down.git.N/` 내에서 `find -maxdepth 2`로 파일 탐색, 없으면 기본 경로 사용
- 최종 `<include name="<경로>"/>` 태그를 `${input_file}.xml`에 기록

#### 3-2. 최종 manifest 병합
- 각 include 파일의 `<remote>` 태그 추출 및 중복 처리:
  - 동일 `name`이 이미 존재하면 `name.1`, `name.2` 형태로 자동 변경
  - 추출된 remote는 `<!-- ... -->` 주석 처리로만 출력 (실제 사용 안함)
- 실제 사용 remote: `devops_test` 하나만 정의 (`fetch="mirror/merged 절대경로"`)
- `<default remote="devops_test" revision="master"/>` 추가
- 각 include 파일의 `<project>` 태그 전부 순서대로 추가
  - `upstream`, `dest-branch`, `remote` 속성은 sed로 제거
  - 각 include 섹션 앞에 `<!-- Projects from: <file> -->` 주석 삽입

#### 3-3. include 파일 검증
- `<include>` 태그에 지정된 파일이 실제 존재하지 않으면 `exit 1`로 종료

---

## 4. `merge-mirror.sh` — Mirror 통합 심볼릭 링크 생성

### 목적
통합 manifest의 모든 project에 대해, 다운로드된 `.git` 디렉토리를 탐색하여 `mirror/merged/` 디렉토리에 **심볼릭 링크**로 일원화하는 스크립트.

### CLI 인터페이스
```
merge-mirror.sh [manifest] [work_dir]
```
- `manifest`: 기본값 `merged-manifest.xml`
- `work_dir`: 기본값 — manifest 경로에서 상위로 traverse하며 `down.list` 있는 디렉토리 자동 탐지

### 환경변수
| 변수 | 기본값 | 설명 |
|------|--------|------|
| `MARKER_FILE` | `down.list` | 작업 디렉토리 탐색 기준 파일 |
| `MIRROR_SUBDIR` | `mirror/merged` | 링크를 생성할 서브 경로 |
| `REPO_OBJECTS_PATH` | `.repo/project-objects` | repo 구조에서 git 오브젝트 경로 |

### 기능 요구사항

#### 4-1. 소스 디렉토리 자동 탐색 (우선순위 순)
1. **split 우선**: `down.git.*/*_split` 패턴 디렉토리 → split 버전 우선 사용
2. **일반 git**: `down.git.*` 디렉토리 (단, `_split` 버전이 있는 경우 제외)
3. **repo 구조**: `down.repo.*/.repo/project-objects` 디렉토리

#### 4-2. 심볼릭 링크 생성 규칙
- manifest의 각 `<project name="...">` 에서 project name 추출
- 링크 대상 경로: `mirror/merged/<project_name>.git`
- 이미 존재하는 링크/경로는 건너뜀 (skip)
- 소스 우선순위로 `.git` 경로 탐색:
  - split: `<parent>/<project_name>/.git`
  - git: `<down.git.N>/<project_name>/.git`
  - repo: `<project-objects>/<project_name>.git`
- 찾지 못한 경우: `WARN: Not found: <name>` 출력

#### 4-3. 결과 요약
- 완료 후 `Created: N, Skipped: N, Not found: N` 출력

---

## 5. `merge-xml.sh` — Manifest Path/Remote 주입

### 목적
**new 소스의 manifest**에 **ori(구형) 소스 manifest의 `path`와 `remote` 정보를 주입**하여 `gen-fin.xml`을 생성하는 스크립트.
이를 통해 new 소스를 ori의 git 저장소 구조에 맞게 push할 수 있도록 준비한다.

### CLI 인터페이스
```
merge-xml.sh <ori.xml> <new.xml> [prefix1 prefix2 ...]
```
- `ori.xml`: 기존 소스의 manifest (path/remote 구조 기준)
- `new.xml`: 신규 소스의 manifest (project name만 있음)
- `prefix...`: new의 project name에서 제거할 prefix 문자열 목록 (선택)

### 출력 파일
- `gen-fin.xml`: new.xml 기반에 ori의 path/remote가 주입된 최종 manifest

### 기능 요구사항

#### 5-1. ori manifest 파싱
- `xmlstarlet sel`로 모든 `//project`의 `@name`, `@remote` 추출
- `name → { used_count, remote }` 구조로 연상 배열 저장
- remote 속성 없는 project → 오류 출력 후 즉시 종료

#### 5-2. new manifest의 path 속성 초기화
- `new.xml`을 `gen-fin.xml`로 복사 후, `xmlstarlet ed`로 모든 `//project/@path` 삭제

#### 5-3. 후방 suffix 매칭 (뒤에서부터 매칭)
- new의 각 project name에서 prefix 인수 제거 후 `stripped_name` 획득
- ori의 모든 name 중 `name`이 `stripped_name`을 suffix로 포함하는 것 탐색
  - prefix 부분이 없거나 `/`로 끝나는 경우만 유효 (경로 경계 일치)
  - 복수 매칭 시 **가장 긴 ori name** 선택
- 매칭 성공: `gen-fin.xml`에서 해당 project 태그에 `path="<ori_name>" remote="<ori_remote>"` 속성 삽입 (sed 사용)
- 매칭 실패: `not_matched` 카운트 증가

#### 5-4. Remote 블록 교체
- `gen-fin.xml`의 모든 `<remote>` 라인 삭제
- ori.xml의 `<remote>` 블록을 `<manifest>` 여는 태그 바로 다음에 삽입

#### 5-5. 결과 출력
```
=== Completed ===
Input: <new.xml>, Compare: <ori.xml>, Output: gen-fin.xml
Matched: N, Not matched: N, Duplicated: N
```
- `not_matched > 0`: path 속성 없는 project 목록을 `grep --color`로 출력
- `duplicated > 0` (동일 ori name에 2회 이상 매칭): 중복 목록과 라인 번호 출력

---

## 6. `check-repo.sh` — Remote/Branch 존재 여부 검증

### 목적
`gen-fin.xml`을 기준으로 현재 작업 디렉토리의 모든 git에 대해 **remote 등록, remote 서버 접속 가능 여부, branch 존재 여부, HEAD 비교**를 수행하여 push 준비 상태를 확인하는 스크립트.

### CLI 인터페이스
```
check-repo.sh <gen-fin.xml> <branch>
```
- `gen-fin.xml`: merge-xml.sh로 생성된 manifest
- `branch`: 확인할 branch 이름 (`refs/heads/` 자동 prefix 추가)

### 출력 파일
- `check-repo.result`: `STATE|REPO_PATH|REMOTE_URL` 형식의 결과 파일 (항상 신규 생성)

### 기능 요구사항

#### 6-1. gen-fin.xml 파싱
- `xmlstarlet sel`로 `<remote name fetch>` 추출 → `remote_name → fetch_url` 연상 배열
- `xmlstarlet sel`로 `<project name path remote>` 추출 → `tmp_lookup` 파일 생성
  - 형식: `project_name|project_path|remote_name|full_remote_url`
  - `full_remote_url = fetch_url/project_path`

#### 6-2. 각 git 처리 (tmp_lookup 줄 단위 순회)
1. `<workspace>/<REPO_PATH>/.git` 없으면: `NO_REMOTE` 기록 후 다음
2. 기존 remote 전부 삭제 후 추출한 `remote_name/url`로 새로 등록
3. `git ls-remote --exit-code <remote> HEAD` → `remote_status`
4. `git ls-remote --exit-code <remote> refs/heads/<branch>` → `branch_status`

#### 6-3. HEAD 비교 전략 (branch 존재 시만 수행, 네트워크 비용 최소화)
| 순서 | 조건/방법 | 판별 결과 |
|------|-----------|-----------|
| ① | SHA 획득 불가 | `HEAD_DIFFER` |
| ② | `local_head == remote_head` (직접 비교) | `HEAD_SAME` |
| ③ | `git rev-list HEAD \| grep remote_head` (로컬 히스토리 탐색) | `HEAD_LOCAL` (local이 앞) |
| ④ | `git fetch --shallow-since=<local commit date>` 후 `merge-base --is-ancestor` | `HEAD_REMOTE` (remote가 앞) |
| ⑤ | ④ 실패 또는 판별 불가 | `HEAD_DIFFER` |

#### 6-4. 결과 기록 및 출력
- `FILE_RESULT`에 `STATE|REPO_PATH|REMOTE_URL` 기록
- STATE 값: `HEAD_SAME`, `HEAD_REMOTE`, `HEAD_LOCAL`, `HEAD_DIFFER`, `NO_BRANCH`, `NO_REMOTE`
- 결과 파일을 STATE 기준 정렬 후 컬러 출력:
  - `NO_BRANCH`, `HEAD_SAME`: GREEN
  - `HEAD_REMOTE`, `HEAD_LOCAL`: YELLOW
  - `HEAD_DIFFER`, `NO_REMOTE`: RED
- 출력 포맷: `[STATE라벨] %-100s(remote_url) %-60s(repo_path)`

#### 6-5. 최종 요약
```
=== Summary ===
  GEN_FIN_XML : <절대경로>
  BRANCH_NAME : refs/heads/<branch>
  Total processed : N
    NO_REMOTE   : N  (err, must check gen-fin.xml)
    NO_BRANCH   : N  (need to push)
    HEAD_SAME   : N  (already synced)
    HEAD_REMOTE : N  (remote advanced)
    HEAD_LOCAL  : N  (local advanced)
    HEAD_DIFFER : N  (need full fetch)
```

---

## 7. `push-repo.sh` — Remote Push 수행

### 목적
`check-repo.sh`가 생성한 `check-repo.result`를 기반으로, STATE에 따라 전략적으로 **각 git을 remote에 push**하는 스크립트.

### CLI 인터페이스
```
push-repo.sh <compare-branch> <dest-branch> <force|merge>
```
- `compare-branch`: local 비교 기준 branch (push 소스)
- `dest-branch`: remote에 push할 대상 branch (`refs/heads/` 자동 추가)
- `force|merge`: HEAD_DIFFER 처리 전략 선택

### 전제 조건
- `check-repo.result`가 현재 디렉토리에 존재해야 함
- `NO_REMOTE` 항목이 하나라도 있으면 즉시 abort (`gen-fin.xml` 수정 안내)

### 입력 파일 검증
- `check-repo.result` 존재 여부 확인
- 첫 줄의 column 수가 3인지, STATE 값이 유효한지, path/url이 비어있지 않은지 확인

### push 전략 (STATE별)

| STATE | 처리 방법 | 결과 기록 |
|-------|-----------|-----------|
| `HEAD_LOCAL` | `git push <remote> <compare>:<dest>` 직접 push | `PUSH` |
| `NO_BRANCH` | 신규 branch 생성 push (동일 명령) | `PUSH` |
| `HEAD_SAME` | skip | `SKIP` |
| `HEAD_REMOTE` | skip | `SKIP` |
| `HEAD_DIFFER` + `force` | `git fetch` 후 DIVERGED/UNRELATED 판별 → `git push --force` | `FORCE` |
| `HEAD_DIFFER` + `merge` | `git fetch` 후 임시 branch 생성, DIVERGED → `git merge FETCH_HEAD`, UNRELATED → `git merge --allow-unrelated-histories -s ours` → push | `MERGE` |
| push 실패 | 오류 기록 | `FAIL` |

#### HEAD_DIFFER 상세 처리
- `git fetch <remote> <BRANCH_DEST>` 실행
- `git merge-base <local_head> <fetched_head>` 성공 여부로 DIVERGED / UNRELATED 판별
- merge 모드: 임시 branch `push_tmp_$$` 생성 후 merge 시도 → push → branch 삭제

### 실행 방식
- `repo forall -cj1`: 순차 실행 (병렬 push 금지 - 서버 부하/충돌 방지)
- 내부 스크립트: `/bin/sh` 호환 문제 회피를 위해 `cat << EOF | bash -s` 패턴으로 bash로 명시 실행
- `FILE_CHECK`, `FILE_PUSH`, `BRANCH_COMPARE`, `BRANCH_DEST`, `PUSH_OPTION`은 `export`로 forall에 전달

### 출력 파일
- `push-repo.result`: `RESULT|STATE|TYPE|REPO_PATH|REMOTE_URL` 형식

### 결과 출력 및 요약
- STATE 기준 정렬 후 컬러 라벨 출력:
  - `PUSH`: GREEN, `SKIP`: BLUE, `FORCE:DIVERGED`: YELLOW, `FORCE:UNRELATED`: RED
  - `MERGE:DIVERGED/UNRELATED`: YELLOW, `FAIL`: RED
- 최종 요약: 각 결과 카운트 + 옵션(force/merge)에 따라 다른 요약 형식 출력

```
=== Summary ===
  COMPARE_BRANCH : refs/heads/<compare>
  DEST_BRANCH    : refs/heads/<dest>
  PUSH_OPTION    : force|merge
    PUSH   (normal / new branch) : N
    FORCE/MERGE (DIVERGED)       : N
    FORCE/MERGE (UNRELATED)      : N
    SKIP                         : N
    FAIL                         : N
push log: push-repo.result
```
