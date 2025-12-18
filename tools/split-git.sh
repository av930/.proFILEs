#!/bin/bash -e
## usage
# 실행하고자 하는 현재 dir로 script를 copy한후 실행해야 한다.
# REMOTE_PUSH=false \
# REMOTE_NAME=devops
# REMOTE_ADDR=ssh://vgit.lge.com:29999/sample_yocto \
# REMOTE_BNCH=refs/heads/release_5.0.9 \
# REMOTE_GIT_LEFTOVER=poky \
# split-get.sh dir1 dir2 ... dir3

## param으로 입력된 git은 독립적인 git(각 dir이름)으로 분리되고, 나머지는 현재 git으로 저장되는 script
## split-get.sh는 .git dir로 copy한후 거기서 실행해야 한다.
if ! command -v git-filter-repo &> /dev/null; then
    echo "Please install by 'sudo apt-get install git-filter-repo'"
    exit 1
fi

## 현재 path 획득
PATH_CURRENT=$(dirname $(realpath "$0"))
[ ! -d "$PATH_CURRENT" ] && { "$0 must be run at .git directory"; exit 1; }

## common이 있으면 제거하고 PATH_GIT 설정
PATH_GIT=()
for item in "$@"; do
    [[ "$item" != "common" ]] && PATH_GIT+=("$item")
done

printf "\e[1;33m list ============================================================================= \e[0m\n"
echo ${PATH_GIT[@]}

## parameter check
(( "${#PATH_GIT[@]}" == 0 )) || [[ "${PATH_GIT[@]}" =~ "*" ]]  && { echo "input params git1 git2 ... "; exit 1; }
for item in ${PATH_GIT[@]}; do

  printf "\e[0;35m [$item]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
  ## tmp 새 디렉터리 생성후 git clone
  rm -rf "tmp_${item}" && mkdir -p "tmp_${item}" && pushd "tmp_${item}" > /dev/null
  git clone ${PATH_CURRENT} .

  ## 현재 dir를 git으로 분리하면서 root path로 만듦
  #git filter-repo --path "$item" --path-rename "$item": --force
  set -x; git filter-repo --subdirectory-filter "$item" --force; set +x

  ## 원격 저장소로 푸시 (선택 사항)
  ## 저장소가 있는지 확인후,remote add, git push
  #curl -su vc.integrator:UUmF3ZYZofW1Jq~~ http://vgit.lge.com/devops_test/a/projects/sample_yocto%2F${item//-/%2d}
  if "${REMOTE_PUSH}" ;then
    set -x
    git remote add $REMOTE_NAME ${REMOTE_ADDR}/${item}
    git push $REMOTE_NAME HEAD:${REMOTE_BNCH} -o skip-validation
    set +x
  # git push origin --all
  # git push origin --tags
  fi
  popd

  ## 작업이 끝난 기존 dir를 대체
  ## tmp_${item}과 ${item}을 .git 제외하고 비교
  [ -f "${PATH_CURRENT}/cmp_dirs.sh" ] || { echo "error: script file is not existed"; exit 1; }
  if EXCEPT=.git P1="tmp_${item}" P2="${item}" ${PATH_CURRENT}/cmp_dirs.sh 1 > /dev/null 2>&1; then
    echo "=== [${item}] same: replace old with new ==="
    rm -rf "${item}"
    mv "tmp_${item}" "${item}"
  else #작업후 dir내용이 다르면, 즉 git에 추가되지 않은 내용이 있었다면
    echo "=== [${item}] diff: overwrite from old to new ==="
    #leftover파일로 만들고
    mv "${item}" "leftover_${item}"
    mv "tmp_${item}" "${item}"

  #기존dir중 남은 내용을 신규 dir ${item} 위에 overwrite
    # shopt -s dotglob
    # rsync -a --update "leftover_${item}/" "${item}/"
    # shopt -u dotglob

    # # 3. git add & commit
    # git add -A
    # git commit -m "split & merge: ${item}"

  fi
done


printf "\e[1;35m [last]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
## 나머지 남은 현재 dir를 다시 git으로 최종 분리
rm -rf "tmp_common" && mkdir -p "tmp_common" && pushd "tmp_common" > /dev/null
git clone ${PATH_CURRENT} .
set -x; git filter-repo ${PATH_GIT[@]/#/--path } --invert-paths --force; set +x


if "${REMOTE_PUSH}" ;then
## 원격 저장소로 푸시(이름지정 필요)
  set -x
  git remote add $REMOTE_NAME ${REMOTE_ADDR}/${REMOTE_GIT_LEFTOVER}
  git push $REMOTE_NAME HEAD:${REMOTE_BNCH} -o skip-validation
  set +x
fi

popd
echo "done"
