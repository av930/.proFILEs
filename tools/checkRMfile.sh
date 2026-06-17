#!/bin/bash
set -euo pipefail

#----------------------------------------------------------------------------------------------------------
# rm/rm -rf 삭제 실패 원인을 다각도로 진단한후, 대처방법을 알려준다.
# 입력 경로(파일/디렉터리)에 대해 권한, 소유권, 부모 디렉터리, 속성, 마운트, 점유 상태를 점검한다.
#----------------------------------------------------------------------------------------------------------

readonly COLOR_GREEN="\033[92m\033[1m"
readonly COLOR_RED="\033[91m\033[1m"
readonly COLOR_YELLOW="\033[93m\033[1m"
readonly COLOR_BLUE="\033[94m\033[1m"
readonly COLOR_CYAN="\033[96m\033[1m"
readonly COLOR_RESET="\033[0m"

usage() {
    cat <<-EOF
usage: $(basename "$0") <dir|file>

example:
    $(basename "$0") /data001/vc.integrator/Docker_MountDIR/build_dev/__DEV_HONDA26__mount

output:
    [FAIL] parent directory is not writable
    [WARN] immutable flag is set on target
    [WARN] filesystem is read-only
EOF
    exit 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

print_section() {
    local title="$1"
    echo
    echo -e "${COLOR_BLUE}=== ${title} ===${COLOR_RESET}"
}

ok() { echo -e "${COLOR_GREEN}[OKAY]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
cmd() { echo -e "${COLOR_CYAN}$*${COLOR_RESET}"; }

cmd_safe_scope() {
    local action="$1" path="$2"
    cmd "CMD: p=\"$path\"; cwd=\"\$(pwd -P)\"; rp=\"\$(readlink -fm -- \"\$p\")\"; if [[ \"\$rp\" == \"\$cwd\" || \"\$rp\" == \"\$cwd\"/* ]]; then $action; else echo '[WARN] outside current directory, skip execution: $action'; fi"
}

check_command_set() {
    local required optional cmd
    required=(stat id findmnt)
    optional=(namei lsattr getfacl fuser lsof mountpoint)

    for cmd in "${required[@]}"; do
        have_cmd "$cmd" || { fail "missing required command: $cmd"; exit 2; }
    done
    for cmd in "${optional[@]}"; do
        have_cmd "$cmd" || warn "optional command not found: $cmd";
    done
}

print_user_meta() {
    print_section "1. Current User"
    echo "User      : $(id -un) (uid=$(id -u), gid=$(id -g))"
    echo "Groups    : $(id -Gn)"
    ok "current user metadata check completed"
    cmd "CMD: id -un && id -u && id -Gn"
}

print_target_meta() {
    local target="$1"
    print_section "2. Target"
    echo "Input     : $target"
    if [[ -e "$target" || -L "$target" ]]; then
        echo "Resolved  : $(readlink -f "$target" 2>/dev/null || echo "$target")"
        echo "Type      : $(stat -Lc '%F' "$target" 2>/dev/null || echo "unknown")"
        echo "Mode      : $(stat -Lc '%A (%a)' "$target" 2>/dev/null || echo "unknown")"
        echo "Owner     : $(stat -Lc '%U:%G (%u:%g)' "$target" 2>/dev/null || echo "unknown")"
        echo "Inode     : $(stat -Lc '%i' "$target" 2>/dev/null || echo "unknown")"
        ok "target metadata check completed"
        cmd "CMD: rm -rf -- \"$target\""
    else
        fail "target does not exist"
        exit 1
    fi
}

check_ownership_and_hint() {
    local target="$1" target_uid parent_uid
    local current_uid

    print_section "3. Ownership"
    target_uid="$(stat -Lc '%u' "$target" 2>/dev/null || echo -1)"
    parent_uid="$(stat -Lc '%u' "$(dirname "$target")" 2>/dev/null || echo -1)"
    current_uid="$(id -u)"

    echo "Target owner uid : $target_uid"
    echo "Parent owner uid : $parent_uid"
    echo "Current user uid : $current_uid"

    if [[ "$current_uid" -ne 0 && "$current_uid" -ne "$parent_uid" ]]; then
        warn "current user does not own parent directory"
    fi
    if [[ "$current_uid" -ne 0 && "$current_uid" -ne "$target_uid" ]]; then
        warn "current user does not own target"
    fi
    if [[ "$current_uid" -eq 0 ]]; then
        ok "running as root (some checks may still fail on immutable/ro/fs policy)"
    fi
    ok "ownership check completed"
    cmd "CMD: sudo chown -R \"$(id -un):$(id -gn)\" -- \"$target\""
}

check_parent_permissions() {
    local target="$1"
    local parent owner_uid target_uid target_name parent_mode sticky owner_name parent_name

    parent="$(dirname "$target")"
    target_name="$(basename "$target")"

    print_section "4. Parent Directory Permission"
    echo "Parent    : $parent"
    echo "Mode      : $(stat -Lc '%A (%a)' "$parent" 2>/dev/null || echo "unknown")"
    echo "Owner     : $(stat -Lc '%U:%G (%u:%g)' "$parent" 2>/dev/null || echo "unknown")"

    [[ -w "$parent" ]] && ok "parent is writable" || fail "parent is not writable"
    [[ -x "$parent" ]] && ok "parent is searchable (execute bit)" || fail "parent is not searchable (execute bit)"

    owner_uid="$(stat -Lc '%u' "$parent" 2>/dev/null || echo -1)"
    target_uid="$(stat -Lc '%u' "$target" 2>/dev/null || echo -1)"
    parent_mode="$(stat -Lc '%a' "$parent" 2>/dev/null || echo 0)"
    owner_name="$(stat -Lc '%U' "$parent" 2>/dev/null || echo unknown)"
    parent_name="$parent"
    sticky=0

    (( (parent_mode / 1000) % 10 & 1 )) && sticky=1 || true
    if (( sticky == 1 )); then
        if [[ "$(id -u)" -ne 0 && "$(id -u)" -ne "$owner_uid" && "$(id -u)" -ne "$target_uid" ]]; then
            fail "sticky bit is set and current user cannot remove this entry"
            echo "Hint      : owner of parent is $owner_name, target entry is $target_name"
        else
            ok "sticky bit is set but user appears allowed by ownership/root"
        fi
    else
        ok "sticky bit restriction not detected"
    fi

    if have_cmd namei; then
        echo
        echo "Path walk :"
        namei -om "$target" 2>/dev/null || warn "namei failed to inspect path"
    fi

    cmd "CMD: chmod u+rwx -- \"$(dirname "$target")\""
}

check_acl() {
    local target="$1" parent
    parent="$(dirname "$target")"

    print_section "5. ACL"
    if ! have_cmd getfacl; then
        warn "getfacl not available, skip ACL check"
        return 0
    fi

    echo "Target ACL:"
    getfacl -cp "$target" 2>/dev/null || warn "cannot read ACL of target"
    echo
    echo "Parent ACL:"
    getfacl -cp "$parent" 2>/dev/null || warn "cannot read ACL of parent"
    ok "acl check completed"
    cmd "CMD: setfacl -bR -- \"$target\" \"$parent\""
}

check_immutable() {
    local target="$1" parent attrs_t attrs_p
    parent="$(dirname "$target")"

    print_section "6. Immutable/Append-only Attribute"
    if ! have_cmd lsattr; then
        warn "lsattr not available, skip immutable check"
        return 0
    fi

    attrs_t="$(lsattr -d "$target" 2>/dev/null | awk '{print $1}' || true)"
    attrs_p="$(lsattr -d "$parent" 2>/dev/null | awk '{print $1}' || true)"
    echo "Target attr: ${attrs_t:-unknown}"
    echo "Parent attr: ${attrs_p:-unknown}"

    [[ "${attrs_t:-}" == *i* ]] && fail "immutable(i) is set on target"
    [[ "${attrs_t:-}" == *a* ]] && warn "append-only(a) is set on target"
    [[ "${attrs_p:-}" == *i* ]] && fail "immutable(i) is set on parent"
    [[ "${attrs_p:-}" == *a* ]] && warn "append-only(a) is set on parent"
    [[ "${attrs_t:-}${attrs_p:-}" =~ [ia] ]] || ok "no immutable/append-only flag detected"
    cmd "CMD: sudo chattr -Ri -- \"$target\""
}

check_mount_and_fs() {
    local target="$1" mnt_info mnt_target mnt_source mnt_fstype mnt_opts

    print_section "7. Filesystem and Mount"
    mnt_info="$(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS -T "$target" 2>/dev/null || true)"
    if [[ -z "$mnt_info" ]]; then
        warn "cannot resolve mount info with findmnt"
        return 0
    fi

    mnt_target="$(awk '{print $1}' <<<"$mnt_info")"
    mnt_source="$(awk '{print $2}' <<<"$mnt_info")"
    mnt_fstype="$(awk '{print $3}' <<<"$mnt_info")"
    mnt_opts="$(cut -d' ' -f4- <<<"$mnt_info")"

    echo "Mountpoint: $mnt_target"
    echo "Source    : $mnt_source"
    echo "FSType    : $mnt_fstype"
    echo "Options   : $mnt_opts"

    [[ ",$mnt_opts," == *,ro,* ]] && fail "filesystem is mounted read-only" || ok "filesystem is mounted read-write"

    case "$mnt_fstype" in
        nfs|nfs4)
            warn "NFS mount detected (server-side export options/root_squash/permissions can block deletion)"
            ;;
        cifs|smb3|smbfs)
            warn "Samba/CIFS mount detected (share ACL and mount uid/gid mapping can block deletion)"
            ;;
        overlay)
            warn "overlayfs detected (upperdir/workdir state and whiteout behavior can affect deletion)"
            echo "Overlay   : $(findmnt -no OPTIONS -T "$target" 2>/dev/null || echo "unknown")"
            ;;
        fuse.*)
            warn "FUSE filesystem detected (daemon/backend policy may reject unlink/rmdir)"
            ;;
        *)
            ok "no special remote/overlay fs warning by fstype"
            ;;
    esac

    if have_cmd mountpoint && mountpoint -q "$target"; then
        fail "target itself is a mountpoint; unmount is required before removal"
    fi

    cmd "CMD: sudo mount -o remount,rw \"$(findmnt -no TARGET -T "$target" 2>/dev/null || echo '<mountpoint>')\""
}

check_process_usage() {
    local target="$1" pids lsof_cnt

    print_section "8. Process/Device Busy"

    if have_cmd fuser; then
        echo "fuser -vm output:"
        fuser -vm "$target" 2>/dev/null || true
        echo
        pids="$(fuser "$target" 2>/dev/null || true)"
        [[ -n "${pids// }" ]] && warn "one or more processes are using target" || ok "no direct fuser hit on target"
    else
        warn "fuser not available"
    fi

    if have_cmd lsof; then
        echo
        echo "lsof sample (up to 30 lines):"
        lsof "$target" 2>/dev/null | head -n 30 || true
        if [[ -d "$target" ]]; then
            echo
            echo "lsof +D sample (up to 30 lines, may be slow):"
            lsof +D "$target" 2>/dev/null | head -n 30 || true

            lsof_cnt="$(lsof +D "$target" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || true)"
            [[ "${lsof_cnt:-0}" -gt 0 ]] && warn "processes are using files under target (lsof +D count=${lsof_cnt})" || ok "no process found under target by lsof +D"
        fi
    else
        warn "lsof not available"
    fi

    cmd_safe_scope "fuser -km -- \"\$p\"" "$target"
}

check_subtree_permission_risk() {
    local target="$1" cur_uid non_owner_cnt non_writable_cnt risky_path
    local non_owner_hit non_writable_hit

    print_section "9. Subtree Permission Risk (rm -rf)"
    [[ -d "$target" ]] || { ok "target is not a directory; skip subtree scan"; return 0; }

    cur_uid="$(id -u)"
    non_owner_hit="$(find "$target" -xdev \( -type d -o -type f \) ! -uid "$cur_uid" -print -quit 2>/dev/null || true)"
    non_writable_hit="$(find "$target" -xdev \( -type d -o -type f \) ! -writable -print -quit 2>/dev/null || true)"
    non_owner_cnt="$(find "$target" -xdev \( -type d -o -type f \) ! -uid "$cur_uid" 2>/dev/null | head -n 1000 | wc -l | tr -d ' ' || true)"
    non_writable_cnt="$(find "$target" -xdev \( -type d -o -type f \) ! -writable 2>/dev/null | head -n 1000 | wc -l | tr -d ' ' || true)"

    echo "Non-owner entries (sample<=1000): ${non_owner_cnt}"
    echo "Non-writable entries (sample<=1000): ${non_writable_cnt}"

    [[ -n "$non_owner_hit" ]] && warn "subtree contains entries not owned by current user"
    [[ -n "$non_writable_hit" ]] && warn "subtree contains entries not writable by current user"
    if [[ -z "$non_owner_hit" && -z "$non_writable_hit" ]]; then
        ok "no obvious ownership/write risk found in sampled subtree"
    fi

    if [[ -n "$non_owner_hit" || -n "$non_writable_hit" ]]; then
        echo
        echo "Sample risky paths (up to 20):"
        find "$target" -xdev \( -type d -o -type f \) \( ! -uid "$cur_uid" -o ! -writable \) 2>/dev/null | head -n 20
    fi

    cmd "CMD: find \"$target\" -xdev \\( -type d -o -type f \\) \\( ! -uid \"$(id -u)\" -o ! -writable \\)"
    risky_path="$(find "$target" -xdev \( -type d -o -type f \) \( ! -uid "$cur_uid" -o ! -writable \) 2>/dev/null | head -n 1 || true)"
    if [[ -n "$risky_path" ]]; then
        cmd "CMD: stat -c '%A %a %U:%G %u:%g %n' \"$risky_path\""
        cmd "CMD: sudo chown -R \"$(id -un):$(id -gn)\" -- \"$risky_path\""
    fi
}

check_nested_busy_case() {
    local target="$1" busy_hit mounted_hit

    print_section "10. Nested Busy Path (Device or resource busy)"
    [[ -d "$target" ]] || { ok "target is not a directory; skip nested busy check"; return 0; }

    busy_hit=""
    mounted_hit=""

    mounted_hit="$(find "$target" -mindepth 1 -xdev -type d 2>/dev/null | while read -r p; do
        mountpoint -q "$p" && { echo "$p"; break; }
    done)"
    busy_hit="$mounted_hit"

    if [[ -n "$busy_hit" ]]; then
        warn "busy-risk directory detected (nested mountpoint)"
        cmd "CMD: findmnt -R -o TARGET,SOURCE,FSTYPE,OPTIONS -T \"$busy_hit\""
        cmd "CMD: findmnt -R -n -o TARGET -T \"$busy_hit\" | sort -r"
        cmd "CMD: findmnt -R -n -o TARGET -T \"$busy_hit\" | sort -r | while read -r m; do sudo umount \"\$m\"; done"
        cmd "CMD: p=\"$busy_hit\"; cwd=\"\$(pwd -P)\"; rp=\"\$(readlink -fm -- \"\$p\")\"; if [[ \"\$rp\" == \"\$cwd\" || \"\$rp\" == \"\$cwd\"/* ]]; then fuser -km -- \"\$p\" && findmnt -R -n -o TARGET -T \"\$p\" | sort -r | while read -r m; do sudo umount \"\$m\"; done; else echo '[WARN] outside current directory, skip execution: fuser -km -- '\"\$p\"; fi"
        cmd "CMD: findmnt -R -n -o TARGET -T \"$busy_hit\" | sort -r | while read -r m; do sudo umount -l \"\$m\"; done"
        cmd "CMD: mountpoint -q \"$busy_hit\" && echo '[WARN] still mounted' || echo '[OKAY] unmounted'"
        cmd_safe_scope "rm -rf -- \"\$p\"" "$busy_hit"
    fi

    if [[ -n "$mounted_hit" ]]; then
        warn "nested mountpoint detected under target"
        echo "Nested mountpoint: $mounted_hit"
        cmd "CMD: findmnt -R -o TARGET,SOURCE,FSTYPE,OPTIONS -T \"$mounted_hit\""
        cmd "CMD: findmnt -R -n -o TARGET -T \"$mounted_hit\" | sort -r | while read -r m; do sudo umount \"\$m\" 2>/dev/null || sudo umount -l \"\$m\"; done"
    fi

    if [[ -z "$busy_hit" && -z "$mounted_hit" ]]; then
        ok "no nested mountpoint busy-risk detected"
    fi

    cmd "CMD: find \"$target\" -mindepth 1 -type d | while read -r p; do mountpoint -q \"\$p\" && echo \"\$p\"; done"
    cmd_safe_scope "rm -rf -- \"\$p\"" "$target"
}


summary_hint() {
    local target="$1"
    print_section "11. Quick Action Hints"
    cat <<-'EOF'
- Check parent directory write/execute bits first.
- If immutable flag exists, clear with: chattr -i <path> (root).
- If filesystem is read-only, remount as rw or fix backend/mount options.
- For NFS/Samba, verify server export/share ACL and uid/gid mapping.
- If target is mountpoint, unmount first.
- If busy by process, stop process or close cwd/file handles.
- For overlayfs, inspect upperdir/workdir and active overlay mount status.
EOF
    ok "quick action guide is ready"
}

main() {
    local target="${1:-}"
    [[ -n "$target" ]] || usage
    [[ "$target" == "-h" || "$target" == "--help" ]] && usage

    check_command_set
    print_user_meta
    print_target_meta "$target"
    check_ownership_and_hint "$target"
    check_parent_permissions "$target"
    check_acl "$target"
    check_immutable "$target"
    check_mount_and_fs "$target"
    check_process_usage "$target"
    check_subtree_permission_risk "$target"
    check_nested_busy_case "$target"
    summary_hint "$target"
}

main "$@"
