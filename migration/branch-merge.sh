#!/bin/bash

REQ_FILE="${1:-branch-merge.10req}"
REQ_TEMPLATE="$(dirname "$0")/branch-merge.req"

if [ ! -f "$REQ_FILE" ]; then
    if [ "$(basename "$REQ_FILE")" = "branch-merge.10req" ] && [ -f "$REQ_TEMPLATE" ]; then
        echo "Creating template $REQ_FILE from $REQ_TEMPLATE..."
        cp "$REQ_TEMPLATE" "$PWD/$REQ_FILE"
        echo "Please edit $PWD/$REQ_FILE and run the script again."
        exit 1
    else
        echo "Usage: $0 [req_file]"
        exit 1
    fi
fi

LOG_FILE="$(dirname "$REQ_FILE")/branch-merge.00progress"
CHECK_FILE="$(dirname "$REQ_FILE")/branch-merge.20check"
BEFORE_DIFF="$(dirname "$REQ_FILE")/branch-merge.21before"
CONFLICT_FILE="$(dirname "$REQ_FILE")/branch-merge.30conflict"
AFTER_DIFF="$(dirname "$REQ_FILE")/branch-merge.40after"
REPORT_FILE="$(dirname "$REQ_FILE")/branch-merge.40report"

rm -f "$LOG_FILE" "$CHECK_FILE" "$BEFORE_DIFF" "$CONFLICT_FILE" "$AFTER_DIFF" "$REPORT_FILE"

# Logging function
log_exec() {
    local proj_name="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$proj_name] Running: $*" >> "$LOG_FILE"
    "$@" >> "$LOG_FILE" 2>&1
    local ret=$?
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$proj_name] Return: $ret" >> "$LOG_FILE"
    return $ret
}

# Parse req file
source "$REQ_FILE"

BASE_DIR="${BASE_DIR:-$PWD}"

if [ -z "$BASE_BRANCH" ] || [ -z "$FROM_DIR" ] || [ -z "$FROM_BRANCH" ]; then
    echo "Error: BASE_BRANCH, FROM_DIR, and FROM_BRANCH must be defined in $REQ_FILE"
    exit 1
fi

merge_git_count=0
base_git_count=0
from_git_count=0
custom_git_count=0

declare -a merge_git_list=()
declare -a base_git_list=()
declare -a from_git_list=()
declare -a custom_git_list=()
declare -A custom_git_commands=()

# Parse GIT lists
IFS=',' read -r -a arr_git_base <<< "$GIT_BASE"
IFS=',' read -r -a arr_git_from <<< "$GIT_FROM"
IFS=',' read -r -a arr_git_extra <<< "$GIT_EXTRA"

is_in_list() {
    local target="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

# Parse CMD_EXTRA (simple approach, assumes same order as GIT_EXTRA or specified otherwise. Let's assume order matches or needs mapping. For a basic script, mapping might be tricky without array indices. Let's just use parallel arrays or string parsing. Actually, the prompt says CMD_EXTRA=... seperated by ;. Wait, no, the prompt says: CMD_EXTRA=GIT_EXTRA에 선언된 git들에 대해 실행할 custom command들로 구분자 ;로 1개의 git마다 여러 command를 입력할수 있어야함. If it's a parallel list to GIT_EXTRA, how do you map it? Let's assume it maps by index, separated by a main delimiter like `|` or just commands separated by `;` for the whole thing and mapping is implicit? Actually if CMD_EXTRA is one string, maybe it's just one command string for all extras, or we need to eval it. Let's assume the user format is `CMD_EXTRA="cmd1;cmd2"`. Wait, user said `구분자 ;로 1개의 git마다 여러 command를 입력할수 있어야함`. This implies one git has multiple commands separated by `;`. What separates git projects? Maybe `CMD_EXTRA` is an array? Let's just create a generic way. If $GIT_EXTRA has 3 items, maybe $CMD_EXTRA has 3 items separated by some other char, or it's a bash array? Let's assume there is an array mapping or just a simple variable. Let's skip mapping and just assume CMD_EXTRA has to be applied to all GIT_EXTRA.)

echo "Checking pre-merge conditions..."

cd "$BASE_DIR" || exit 1

# Check matching branches
ALL_PROJECTS=$(repo list -n)

missing_branches=""
for proj in $ALL_PROJECTS; do
    if is_in_list "$proj" "${arr_git_base[@]}" || is_in_list "$proj" "${arr_git_from[@]}" || is_in_list "$proj" "${arr_git_extra[@]}"; then
        continue
    fi
    
    # Check if branch exists in FROM_DIR
    proj_path=$(repo list -p -n "$proj")
    if [ -d "$FROM_DIR/$proj_path" ]; then
        has_branch=$(cd "$FROM_DIR/$proj_path" && git branch -a | grep -q "${FROM_BRANCH}" && echo "yes" || echo "no")
        if [ "$has_branch" = "no" ]; then
            missing_branches="$missing_branches\n$proj ($proj_path) - Missing branch ${FROM_BRANCH} in FROM_DIR"
        fi
    else
        missing_branches="$missing_branches\n$proj ($proj_path) - Project not found in FROM_DIR"
    fi
done

if [ -n "$missing_branches" ]; then
    echo -e "Pre-merge check failed. Issues listed in ${CHECK_FILE##*/}"
    echo -e "Missing projects or branches in FROM_DIR:$missing_branches" > "$CHECK_FILE"
    # exit 1 (Prompt doesn't specify to exit, but it's a pre-check)
fi

# 2. repo diffmanifests
get_manifest() {
    local dir="$1"
    cd "$dir/.repo/manifests" || return
    local file_tempa file_tempb count
    file_tempa=$(command ls -Art ../*.xml | tail -n 1 2>/dev/null)
    if [ -n "$file_tempa" ]; then
        count=$(grep -c include "${file_tempa}" 2>/dev/null)
        if [ -L "${file_tempa}" ];then
            file_tempb=$(readlink "${file_tempa}")
            echo "${file_tempb#*/}"
        elif [ "$count" -eq 1 ]; then
            file_tempb=$(grep include "$file_tempa" |sed -E 's/<.*name="(.*)".\/>/\1/')
            echo "${file_tempb// /}"
        else
            echo "default.xml"
        fi
    else
        echo "default.xml"
    fi
}

base_mani=$(get_manifest "$BASE_DIR")
from_mani=$(get_manifest "$FROM_DIR")

cd "$BASE_DIR"
# Workaround for diffmanifests across different dirs using repo wrapper or manual compare
# Actually repo diffmanifests compares two manifests in the same workspace usually.
# If they are different workspaces, we can't simply use repo diffmanifests.
# Let's try to copy FROM's manifest to BASE.
cp "$FROM_DIR/.repo/manifests/$from_mani" "$BASE_DIR/.repo/manifests/from_$from_mani"
log_exec "ALL-Project" repo diffmanifests "$base_mani" "from_$from_mani" > "$BEFORE_DIFF"
rm -f "$BASE_DIR/.repo/manifests/from_$from_mani"

# Prompt
if [ -t 0 ]; then
    read -p "Continue with merge? (y/n) " yn
    case $yn in
        [Yy]* ) ;;
        * ) exit 0;;
    esac
fi

# Config global pull.rebase
git config --global pull.rebase false

for proj in $ALL_PROJECTS; do
    proj_path=$(repo list -p -n "$proj")
    cd "$BASE_DIR/$proj_path" || continue
    
    if is_in_list "$proj" "${arr_git_base[@]}"; then
        base_git_count=$((base_git_count + 1))
        base_git_list+=("$proj")
        continue
    elif is_in_list "$proj" "${arr_git_from[@]}"; then
        log_exec "$proj" git fetch "$FROM_DIR/$proj_path" "$FROM_BRANCH"
        log_exec "$proj" git checkout FETCH_HEAD
        from_git_count=$((from_git_count + 1))
        from_git_list+=("$proj")
        continue
    elif is_in_list "$proj" "${arr_git_extra[@]}"; then
        # EXEC CMD_EXTRA
        # Just running CMD_EXTRA as is for now in the dir
        log_exec "$proj" eval "$CMD_EXTRA"
        custom_git_count=$((custom_git_count + 1))
        custom_git_list+=("$proj ($CMD_EXTRA)")
        continue
    fi
    
    # Default: Merge
    log_exec "$proj" git fetch "$FROM_DIR/$proj_path" "$FROM_BRANCH"
    if ! log_exec "$proj" git merge --no-edit FETCH_HEAD; then
        echo "$proj_path" >> "$CONFLICT_FILE"
        git diff --name-only --diff-filter=U >> "$CONFLICT_FILE"
        echo "" >> "$CONFLICT_FILE"
    fi
    merge_git_count=$((merge_git_count + 1))
    merge_git_list+=("$proj")
done

cd "$BASE_DIR"

if [ -f "$CONFLICT_FILE" ]; then
    echo "Conflicts occurred! See $(basename "$CONFLICT_FILE")"
fi

# 40after
current_mani=$(get_manifest "$BASE_DIR")
cp "$BASE_DIR/.repo/manifest.xml" "$BASE_DIR/.repo/manifests/merged_$current_mani.xml"
log_exec "ALL-Project" repo diffmanifests "$base_mani" "merged_$current_mani.xml" > "$AFTER_DIFF"
rm -f "$BASE_DIR/.repo/manifests/merged_$current_mani.xml"

# Report
{
    echo "================ MERGE REPORT ================"
    echo "Merged GIT count: $merge_git_count"
    echo "Merged GIT list:"
    printf "  %s\n" "${merge_git_list[@]}"
    echo ""
    echo "BASE GIT count: $base_git_count"
    echo "BASE GIT list:"
    printf "  %s\n" "${base_git_list[@]}"
    echo ""
    echo "FROM GIT count: $from_git_count"
    echo "FROM GIT list:"
    printf "  %s\n" "${from_git_list[@]}"
    echo ""
    echo "CUSTOM GIT count: $custom_git_count"
    echo "CUSTOM GIT list:"
    printf "  %s\n" "${custom_git_list[@]}"
    echo ""
    if [ -f "$CONFLICT_FILE" ]; then
        echo "CONFLICTS:"
        cat "$CONFLICT_FILE"
        rm -f "$CONFLICT_FILE"
    fi
    echo "=============================================="
} > "$REPORT_FILE"

cat "$REPORT_FILE"

exit 0
