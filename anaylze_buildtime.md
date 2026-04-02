# Yocto 빌드 시간 및 최적화 설정 분석 요구사항

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
- **검사항목**: 전체 CPU 코어 수, CPU 동작 속도(Hz), 총 RAM 크기, SSD(NVMe)/HDD 여부, 스토리지 크기 추가
- **점수 환산 수식 (가칭 Yocto-Build-Score)**:
  - `점수 = (Core수 * 클럭(GHz) * 10) + (RAM(GB) * 2) + (SSD사용여부 50점 가점)`

### B. 현재 서버 실시간 여유자원 검사
- **검사항목 및 포맷 (`가용량 / 전체용량`)**:
  - CPU: Idle 코어 수 / 전체 CPU 코어 갯수 (`idle / total`)
  - RAM: 가용 메모리 / 전체 RAM 크기 (`Avail GB / Total GB`)
  - Storage: 마운트된 루트 파티션 여유 용량 / 전체 스토리지 크기

## 3. Yocto 전용 설정 적용 검사
- 로그 파싱을 통해 다음 설정값(경로 포함)의 사용 유무 및 값을 추출:
  - `BB_NUMBER_THREADS`, `PARALLEL_MAKE` (`-j` 숫자 등), `SCONS_OVERRIDE_NUM_JOBS`
  - `DL_DIR`, `PREMIRRORS`, `MIRRORS`, `SSTATE_DIR` (다중 URL 및 복잡한 조건문 할당자 `?=`, `:=` 커버)

## 4. 소요 시간 표기 및 시각화 (로그 파싱)
- **전체 빌드 소요 시간**: `Overall Start Time ~ Overall End Time : <시작> ~ <종료> = <총 소요시간>` 형태
- **Yocto 각 태스크별 소요 시간**:
  - 추출 대상: `do_fetch`, `do_unpack`, `do_patch`, `do_configure`, `do_compile`, `do_install`, `do_package`, `do_rootfs`, `do_image`
  - 각 태스크의 hits(호출 횟수) 및 전체 소요 된 시간을 세로로 줄맞춤(Align)하여 표기. 
  - (예: `- do_fetch       : 1531 hits | Total duration: 00:07:47 (09:49:16 ~ 09:57:03)`)

## 5. 결과물 및 요약 보고
- **Build Output 추출**: `PATH_SRC` 경로 하위를 탐색하여 500MB 이상의 거대 파일(주로 이미지) 5개를 찾아 사이즈 및 생성시간 포함 출력.
- **Build Result 색상 표기**: SUCCESS (녹색), FAILURE (빨간색)
- **HTTPS 실패 대처**: `curl` 실패 및 404 시 `http` 형태로 Fallback 적용.
