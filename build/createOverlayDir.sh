#!/usr/bin/env bash
set -euo pipefail

#----------------------------------------------------------------------------------------------------------
# OverlayFS 빌드 작업 디렉터리를 생성/조회/삭제한다.
# original dir를 넣으면 overlayFS로 mount된 새로운 디렉터리(overlay_YYYYMMDD_HHMMSS-N 형식)를 생성하여 경로를 출력한다
# createOverlayDir.sh /path/to/ori /path/to/overlay_
#----------------------------------------------------------------------------------------------------------

usage() {
	cat <<-EOF
usage:
	$(basename "$0") <source_dir> <target_prefix_path>
	$(basename "$0") list
	$(basename "$0") remove <overlay_mount_dir> [overlay_mount_dir ...]
	$(basename "$0") removeall

example:
	$(basename "$0") /data001/vc.integrator/mirror/tsu_26my_release/src_current /data001/vc.integrator/Docker_MountDIR/build_dev/DEV
	$(basename "$0") list
	$(basename "$0") remove /data001/vc.integrator/Docker_MountDIR/build_dev/DEV_06011630-1 /data001/vc.integrator/Docker_MountDIR/build_dev/DEV_06021025-1
	$(basename "$0") removeall
	    ps -o pid,etime,time,cmd -p $(fuser /not-removed/overlay/dir 2>/dev/null)   ## check processes before force kill
	    fuser -km /not-removed/overlay/dir                                          ## force kill all processes using the overlay dir
	    sudo umount /not-removed/overlay/dir                                        ## force unmount if still mounted

output:
	ex) /path/build_dev/DEV_06011630-1
EOF
	exit 1
}

# root 권한이 필요한 명령을 실행한다(root 또는 sudo).
run_as_root() {
	if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
		"$@"
	else
		command -v sudo >/dev/null 2>&1 || { echo "[FAIL] sudo not found: $*" >&2; return 1; }
		sudo "$@"
	fi
}

# 최종 overlay mount 경로 이름을 생성한다 (예: DEV_MMDDHHMM-N).
next_target_dir() {
	local target_prefix="$1"
	local ts seq target

	ts="$(date +%m%d%H%M)"
	seq=1

	while true; do
		target="${target_prefix}_${ts}-${seq}"
		[[ -e "$target" ]] || { printf '%s' "$target"; return 0; }
		seq=$((seq + 1))
	done
}

# 경로 형식이 overlay 생성 규칙( ..._MMDDHHMM-N )인지 확인한다.
is_overlay_name() {
	local name="$1"
	[[ "$name" =~ _[0-9]{8}-[0-9]+$ ]]
}

# overlay mount 및 관련 디렉터리(upper/work/final)를 정리한다.
remove_overlay_dir() {
	local final_dir="$1"
	local parent_dir tmp_root base upper_dir work_dir

	[[ -n "$final_dir" && -d "$final_dir" ]] || { echo "[FAIL] overlay dir not found: $final_dir" >&2; return 1; }
	base="$(basename "$final_dir")"
	is_overlay_name "$base" || { echo "[FAIL] invalid overlay dir name: $final_dir" >&2; return 1; }

	if mountpoint -q "$final_dir"; then
		run_as_root umount "$final_dir" || { echo "[FAIL] umount failed: $final_dir" >&2; return 1; }
	fi

	parent_dir="$(dirname "$final_dir")"
	tmp_root="${parent_dir}/tmp"
	upper_dir="${tmp_root}/${base}_upper"
	work_dir="${tmp_root}/${base}_work"

	run_as_root rm -rf "$final_dir" "$upper_dir" "$work_dir" || { echo "[FAIL] remove failed: $final_dir" >&2; return 1; }
	return 0
}

# tmp 하위 upper 디렉터리를 기준으로 3일 초과 overlay를 자동 정리한다.
cleanup_old_overlays() {
	local parent_dir="$1"
	local tmp_root="${parent_dir}/tmp"
	local upper base final_dir

	[[ -d "$tmp_root" ]] || return 0

	while IFS= read -r upper; do
		base="$(basename "$upper")"
		base="${base%_upper}"
		is_overlay_name "$base" || continue
		final_dir="${parent_dir}/${base}"
		remove_overlay_dir "$final_dir" || true
	done < <(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d -name '*_upper' -mtime +3 2>/dev/null)
}

# 현재 경로($PWD) 아래 overlay mount 된 경로를 출력한다.
list_overlay_mounts_under_pwd() {
	local pwd_path="$PWD"
	awk -v pwd_path="$pwd_path" '$3=="overlay"{print $2}' /proc/mounts | while IFS= read -r mnt; do
		case "$mnt" in
			"$pwd_path"|"$pwd_path"/*) printf '%s\n' "$mnt" ;;
		esac
	done
}

# overlayFS 생성/삭제/조회 명령을 처리한다.
main() {
	local cmd="${1:-}"
	local source_dir target_prefix parent_dir tmp_root final_dir upper_dir work_dir mount_opts
	local rc=0 dir

	[[ "${cmd:-}" == "-h" || "${cmd:-}" == "--help" ]] && usage

	if [[ "$cmd" == "remove" ]]; then
		shift
		[[ "$#" -gt 0 ]] || usage
		for dir in "$@"; do
			remove_overlay_dir "$dir" || rc=1
		done
		exit "$rc"
	fi

	if [[ "$cmd" == "removeall" ]]; then
		while IFS= read -r dir; do
			[[ -n "$dir" ]] || continue
			remove_overlay_dir "$dir" || rc=1
		done < <(list_overlay_mounts_under_pwd)
		exit "$rc"
	fi

	if [[ "$cmd" == "list" ]]; then
		list_overlay_mounts_under_pwd
		exit 0
	fi

	source_dir="${1:-}"
	target_prefix="${2:-}"
	[[ -n "$source_dir" && -n "$target_prefix" ]] || usage

	command -v mountpoint >/dev/null 2>&1 || { echo "[FAIL] missing command: mountpoint" >&2; exit 1; }
	[[ -d "$source_dir" ]] || { echo "[FAIL] source dir not found: $source_dir" >&2; exit 1; }

	parent_dir="$(dirname "$target_prefix")"
	tmp_root="${parent_dir}/tmp"
	mkdir -p "$parent_dir" "$tmp_root"

	cleanup_old_overlays "$parent_dir"

	final_dir="$(next_target_dir "$target_prefix")"
	mkdir -p "$final_dir"

	upper_dir="${tmp_root}/$(basename "$final_dir")_upper"
	work_dir="${tmp_root}/$(basename "$final_dir")_work"
	mkdir -p "$upper_dir" "$work_dir"

	mount_opts="lowerdir=${source_dir},upperdir=${upper_dir},workdir=${work_dir}"

	if ! run_as_root mount -t overlay overlay -o "$mount_opts" "$final_dir"; then
		rmdir "$final_dir" 2>/dev/null || true
		rmdir "$upper_dir" 2>/dev/null || true
		rmdir "$work_dir" 2>/dev/null || true
		echo "[FAIL] overlay mount failed: ${final_dir}" >&2
		exit 1
	fi

	printf '%s\n' "$final_dir"
}

main "$@"
