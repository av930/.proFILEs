# Yocto 빌드 시간 및 최적화 설정 분석 요구사항 (anaylze_buildtime.md)

## 1. Yocto 빌드 속도 향상을 위한 설정 방법 나열
Yocto 빌드는 방대한 소스 코드를 다운로드하고 컴파일하므로, 시간을 단축하기 위해 다음과 같은 설정이 필수입니다.
- **다중 쓰레드/프로세스 활용**:
  - `BB_NUMBER_THREADS`: BitBake가 동시에 실행할 수 있는 태스크 수 (보통 CPU 코어 수의 1.5배~2배 적용)
  - `PARALLEL_MAKE`: 각 패키지 컴파일 시 Make가 사용할 쓰레드 수 (`-j` 옵션)
  - `SCONS_OVERRIDE_NUM_JOBS`: Scons 빌드 시스템을 사용하는 패키지의 병렬 작업 수
- **소스 다운로드 최적화**:
  - `DL_DIR`: 다운로드한 소스(tarball 등)를 로컬에 저장하여 재사용
  - `PREMIRRORS`, `MIRRORS`: 소스 다운로드 시도 시 인트라넷 또는 가까운 미러 서버부터 탐색
- **빌드 캐시 활용**:
  - `SSTATE_DIR` (Sstate-cache): 이전에 빌드된 결과물(컴파일된 바이너리, 패키지 등)을 재사용하여 빌드 시간 획기적 단축
- **파일 시스템 최적화**:
  - I/O 병목이 발생하므로 소스 및 워크스페이스는 반드시 SSD(또는 NVMe) 장치에 위치시킬 것.

## 2. 서버 사양 검사 및 점수 환산 로직
### A. 현재 서버 사양 로직
- **검사항목**: 전체 CPU 코어 수, CPU 동작 속도(Hz), 총 RAM 크기, SSD(NVMe)/HDD 여부, 디스크(Storage) 전체 용량
- **점수 환산 수식 (가칭 Yocto-Build-Score)**:
  - `점수 = (Core수 * 클럭(GHz) * 10) + (RAM(GB) * 2) + (SSD사용여부 50점 가점)`
  - 100점 이하: 느림 / 100~300: 보통 / 300 이상: 매우 양호

### B. 현재 서버 실시간 여유자원 검사
- **검사항목 및 포맷**:
  - CPU: `idle 코어 수 / 전체 코어 수 (idle / total)`
  - RAM: `사용 가능한 RAM (GB) / 전체 RAM (GB)`
  - Storage: `여유 디스크 용량 / 전체 디스크 용량`

## 3. Yocto 전용 설정 적용 검사
- 추출 대상: 로그에서 아래 키워드를 검색하여 설정값을 표시
  - `BB_NUMBER_THREADS`, `PARALLEL_MAKE` (`-j N`), `SCONS_OVERRIDE_NUM_JOBS`
  - `DL_DIR` 경로 추출 (`?=` 및 `:=` 같은 할당자 지원)
  - `PREMIRRORS`, `MIRRORS` 설정 경로/URL 추출
  - `SSTATE_DIR` 설정 디렉터리 경로 추출

## 4. 소요 시간 표기 (로그 파싱)
해당 Yocto Build Log를 시간순으로 분석하여 아래 항목의 소요시간을 계산 및 표시합니다.
- **A. 전체 빌드 소요 시간**: `Overall Start Time ~ Overall End Time : <시작> ~ <종료> = <총 소요시간>` 형태
- **B. Yocto 각 태스크별 소요 시간**:
  - 대상 태스크: `do_fetch`, `do_unpack`, `do_patch`, `do_configure`, `do_compile`, `do_install`, `do_package`, `do_rootfs`, `do_image`
  - 지정된 `|` 와 `:` 구분자를 사용하여 각 태스크들의 결과 출력을 한 눈에 들어오도록 정렬(Align) 표시.
  - 출력 예시:
    `- do_compile   : 1481 hits | Total duration: 01:18:57 (09:49:17 ~ 11:08:14)`

## 5. 최종 산출물 및 빌드 결과
- **A. 거대 이미지 도출**: 로그에서 추출한 `PATH_SRC`를 최상위 경로로 하여, `find` 명령어를 통해 500MB 이상의 거대 파일 5개를 색인. 파일의 용량, 갱신 일자, 경로를 표시.
- **B. 빌드 결과 요약**: 전체 로그의 꼬리를 분석해 SUCCESS (녹색) / FAILURE (적색) 로 색상을 부여하여 결과 요약.
- **C. 원격 로그 참조 보완**: 입력 대상이 `https://` 일 경우 실패 시 자동으로 `http://`로 다운로드를 재시도하는 Fallback 구현.
