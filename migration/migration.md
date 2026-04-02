# Migration Scripts Prompt Document

> **목적**: 이 문서는 migration 디렉토리의 각 Bash 스크립트를 AI 프롬프트를 통해 재생성하거나 수정하기 위한 요구사항 명세서입니다.
> **사용법**: 아래 각 섹션을 AI에게 프롬프트로 제공하면 해당 스크립트를 재생성할 수 있습니다.
> **코드 형식**: 모든 스크립트는 `.proFILEs`의 [`copilot-instructions.md`](../.github/copilot-instructions.md) 에 정의된 **Bash Script 코딩 형식**을 엄격히 준수하여 작성합니다.

---

## 전체 워크플로우 개요

**구형 소스(ori)를 신형 소스(new)로 마이그레이션**하기 위한 전체 workflow 입니다. migration dir아래 사용 script 기술
ORI 소스 : 현재 개발진행중인 소스
MIG 소스 : chipset 제조사에서 release 한 migration 원본 소스
CHIP 소스 : migration소스중 git 분리가 필요한 소스
MIRR 소스 : ORI소스와 동일구조로 MIG소스를 mirroring한 소스
NEW 소스 : ORI+MIRR를 merge한 migration이 완료된 소스

10. ORI 소스다운: migration이 필요한 현재 project 소스(ORI)를 다운받는다.
11. MIG 소스다운: chipset 제조사의 신규 소스(MIG)를 다운받는다. - down-srcs.sh 사용
20. CHIP 소스생성: 신규 소스(MIG)중 용량이 큰 1개의 git소스를 여러개의 git으로 분리한다. - split-gits.sh (split) 사용
21. CHIP 소스생성 manifest생성: 분리한 git들에 대해서 manifest(xml)를 생성한다. - split-gits.sh (mani) 사용
22. CHIP 소스생성 remote등록(선택): 분리한 git들에 대해서 업로드를 위해 remote를 등록한다. - split-gits.sh (verify) 사용
23. CHIP 소스생성 upload(선택): 분리한 git들에 대해서 업로드를 진행한다. - split-gits.sh (push) 사용
30. MIRR소스 통합 csv생성(30): 다운받은 소스의 manifest.xml을 이용하여 mirroring을 위한 csv파일을 생성한다.
>> ori소스를 기준으로 repo forall로 git을 돌아다니며 down받은 소스를 찾아 new manifest를 생성한다.
    >> push-repo.sh prepare로 ori와 mapping된 구조로된 MIRR.xml을 완성한다.
       내부적으로 find-matchgit.sh dir1 dir2를 호출하여 return 0이면 manifest에 merge라는 field를 추가하여 auto로 우선기록하고
       return 60이상이면 가상으로 merge해봐서 fastforward,merge,conflict등을 기록하게 한다.
       return 59이하이면 서로 다른 git이고 merge도 불가능한 잘못된 git으로 must,check으로 기록한다.
       merge=auto,ff| auto,merge| auto,conflict| force,merge| force,conflict| force,ours| force,theirs| must,check으로 구분할수 있고,force,ours와 force,theirs는 user가 수동으로 편집할수 있는 값이다.
        >> find-matchgit.sh 으로 dir1(old)과 dir2(new)에 대해서 git history를 비교하여 old가 new에 merge될수 있는지 검사한다.
        >> 이때, git merge가 가능하다면 return 0
        >> 불가능하다면 (git history가 완전히 달라 common ancestor가 없다면) dir1과 dir2의 file list(file name기준으로)를 비교하여 dir1의 모든 파일의 몇%가 dir2에 존재하는지 그값을 return한다.

    >> push-repo.sh verify로 실제 push할수 있는지 remote(remote, branch, commit)를 검증할수 있어야 한다. (기존에 mirriong한 소스가 있는경우도 고려)
    >> push-repo.sh push 로 실제 push하여 mirror를 만들고, tag를 만들어놓는다. 만약 pushing중 error시 이를 처리를 한후 요약정보를 출력해야 한다.

08. 로컬미러 생성 (31): 이제 repo를 사용하여 MIRR소스를 받고, 모든 git이 제대로 받아졌는지 확인한다.
>> merge-repo.sh을 통해 2개의 branch (ORI와 MIRR)를 merge를 진행한다.
    merge-repo.sh prepare로 merge할때 merged-mani.csv에 merge방법을 미리 기술하게한다.
    예를 들어, 특정 git에 대해서는 ORI를 우선으로 한다던지, conflict발생시 MIRROR를 기준으로 한다던지를 설정할수 있어야 한다.
    이를 위해, 조건(mergible, not mergeble, etc)등과 액션(merge theirs, ours, conflict등을 선택해서 merge할수 있도록 한다.)
>> merge-repo.sh merge를 통해 실제로 merged-mani.csv 기술된대로 merge하도록 만든다.
>> compare-repo.sh dir1 dir2을 통해 merge전과 merge후의 대한 차이를 report를 출력한다.
    결과값은 merge후 변경된 git에 대해서 추가된 commit(ff/merge)과 conflict여부, 최대 10개까지 추가된 commit출력, 그리고 완전히 다른 git으로 replace된 git (최근 3개 commit출력) 등을 표시해야 한다.
>> 일단 repo 명령으로 최종 push하게 만든다.




### 아래 스크립트들은 이 과정에서 사용되는 script들입니다.
```
[1] down-srcs.sh      : 소스 다운로드 (git clone / repo sync) - 병렬 실행
[2] split-gits.sh     : 단일 git 저장소를 서브디렉토리 기준으로 분리
[3] push-gits.sh      : merged-mani.csv를 prepare:생성, verify:검증, push:실제반영 한다.
[4] merge-repo.sh     : merged-mani.csv에 prepare:merge방법기술, merge:방법대로 merge하도록 한다.
[5] compare-repo.sh   : dir1 dir2에 git에 대한 내용을 비교한다.
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
- 기존 `down_src.sh` 프로세스가 있으면 자식까지 `pkill -P`로 정리

---

## 2. `split-gits.sh` — 단일 Git 저장소 분리

### 목적
하나의 git 저장소(모노레포)를 지정한 서브디렉토리 목록 기준으로 **독립된 git 저장소들로 분리**하거나, 분리 결과를 remote에 push하는 스크립트.

### CLI 인터페이스
```
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

