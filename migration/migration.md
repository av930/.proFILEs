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

## 1. `down-srcs.sh` — 병렬 소스 다운로드

### 목적
`down.list` 파일에 정의된 `git clone` / `repo init+sync` 명령 블록들을 **최대 3개 동시에** 병렬로 실행하는 다운로드 관리 스크립트.

### CLI 인터페이스
```bash
down-srcs.sh <input_file> [mirror_path]
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
- 기존 `down_srcs.sh` 프로세스가 있으면 자식까지 `pkill -P`로 정리

---

## 2. `split-gits.sh` — 단일 Git 저장소 분리

### 목적
하나의 git 저장소(모노레포)를 지정한 서브디렉토리 목록 기준으로 **독립된 git 저장소들로 분리**하거나, 분리 결과를 remote에 다루는 매니페스트 및 푸시 스크립트.

### CLI 인터페이스
```bash
CMD=<mode> WORK_DIR=<path> [REMOTE_NAME=... REMOTE_ADDR=... REMOTE_BNCH=...] [PUSH_OPT=...] \
split-gits.sh <dir1> <dir2> ... <dirN>
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

## 3. `push-gits.sh` — 미러링 연동, 검증 및 원격 Push

### 목적
다운받은 소스의 `manifest.xml`을 이용하여 통합 미러링용 리스트(CSV)를 만들고, 루프 구문을 통해 효율적으로 각 컴포넌트의 Remote/Branch 상태 검증 및 최종 Push를 수행하는 스크립트.

### CLI 인터페이스
```bash
push-gits.sh <prepare|verify|push> [옵션]
```

### 기능 요구사항

#### 3-1. `prepare` (CSV 생성 모드)
- 기존에 XML을 통합하던 방식을 폐기하고, 병합용 메타데이터인 `merged-mani.csv`을 생성.
- `manifest.xml`의 각 `project` 요소를 파싱하여 `name`, `path`, `remote` 등의 필수 항목 추출.

#### 3-2. `verify` (검증 모드)
- `merged-mani.csv`를 읽어들여 각 git의 실제 Push가 가능한지 사전 검증.
- 대상 원격지(Remote 주소, Target Branch 유무, Local과 Remote의 Commit 히스토리) 상태 체크.
- 기존에 이미 미러링(Mirroring)된 소스가 존재하는 케이스를 고려(단순 FF-업데이트인지 Conflict가 예측되는지 파악).

#### 3-3. `push` (푸시 및 태깅 모드)
- Bash 순환(loop) 구문을 사용하여 CSV 목록 내의 각 git에 대해 실제 `git push` 진행.
- Push 성공 후 버전을 마킹하기 위한 **Tag 생성 기능**을 포함.
- Push 도중 Error 발생 시 적절히 처리(Resume 등) 후 최종 **성공/실패/로그 등 요약정보(Report) 출력**.

---

## 4. `merge-repo.sh` — ORI와 MIRR 브랜치 병합 처리

### 목적
개발 중인 ORI 소스와 미러링된 MIRR 소스(chipset 코드 등) 2개의 브랜치를 Repo 기반 하에서 정책에 맞게 자동으로 머지(Merge)하는 스크립트.

### CLI 인터페이스
```bash
merge-repo.sh <prepare|merge>
```

### 기능 요구사항

#### 4-1. `prepare` (병합 지침 작성 모드)
- 병합을 바로 수행하지 않고, `merged-mani.csv` 파일에 **각 컴포넌트별 병합 방법론(Action)**을 사전 기술.
- 상태 분석 조건 (`Condition`): `mergible`(병합가능), `not mergeble`(병합불가) 등의 상태값을 검사.
- 취할 액션 (`Action`): 
  - 특정 git은 강제로 **ORI 우선(`ours`)** 으로 반영.
  - Conflict 발생이 예측될 때는 **MIRROR 기준(`theirs`)** 으로 폴백.
  - 혹은 **수동 해결(`conflict`)** 로 표시하고 대기하게 설정.

#### 4-2. `merge` (실제 병합 모드)
- 앞서 지침이 기술된 `merged-mani.csv`를 순회.
- 기술된 Action (`merge theirs`, `merge ours`, 일반 `merge`, `conflict` 등)에 맞게 백그라운드나 순차적으로 `git merge` 명령을 실행.
- 최종적으로 Repo 명령으로 묶어 원격지에 안전하게 최종 반영할 수 있도록 상태를 준비함.

---

## 5. `compare-repo.sh` — 병합 전/후 트리 비교 리포트

### 목적
ORI와 MIRR 소스를 병합하는 전 과정에서, 두 디렉토리 트리(`.git` 환경)의 차이를 명확히 분석하여 결과 리포트를 출력하는 분석 스크립트.

### CLI 인터페이스
```bash
compare-repo.sh <dir1> <dir2>
```

### 기능 요구사항

#### 5-1. 두 디렉토리 간 상태 분석 (`dir1` vs `dir2`)
- Merge 수행 이전 버전의 트리와 Merge 후의 트리를 받아 각 git 별 변경분 추적.

#### 5-2. 변경(Update)이 발생한 git 출력
- **새로운 Commit 추가됨**: Fast-forward 되었는지, 혹은 추가 Merge 커밋이 발생했는지 표시.
- **충돌 상태(Conflict)** 여부 명시.
- 해당 레포지토리 정보 하단에 **추가된 최신 커밋을 최대 10개까지** 요약 출력.

#### 5-3. 완전 대체(Replaced)된 git 출력
- 완전히 다른 git 이력으로 덮어씌워진 경우 명시.
- 대체된 해당 git 저장소의 정보를 식별을 위해 **최근 3개 커밋 내역만** 출력.
