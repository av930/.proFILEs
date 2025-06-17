#!/bin/bash -ex
## split-get.sh dir1 dir2 ... dir3
## param으로 입력된 git은 독립적인 git(각 dir이름)으로 분리되고, 나머지는 현재 git으로 저장되는 script
## split-get.sh는 .git dir로 copy한후 거기서 실행해야 한다.
if ! command -v git-filter-repo &> /dev/null; then
    echo "Please install by 'sudo apt-get install git-filter-repo'"
    exit 1
fi

REMOTE_NAME=devops
REMOTE_ADDR=ssh://vgit.lge.com:29999/sample_yocto
REMOTE_BNCH=refs/heads/release_5.0.9
REMOTE_GIT_LEFTOVER=poky

## 현재 path 획득
PATH_CURRENT=$(dirname $(realpath "$0"))
[ ! -d "$PATH_CURRENT" ] && { "$0 must be run at .git directory"; exit 1; }
PATH_GIT=("$@") 
echo ${PATH_GIT[@]}

## parameter check
(( "${#PATH_GIT[@]}" == 0 )) || [[ "${PATH_GIT[@]}" =~ "*" ]]  && { echo "input params git1 git2 ... "; exit 1; }
for item in ${PATH_GIT[@]}; do
  ## 새 디렉터리 생성후 git clone
  rm -rf "tmp_${item}" && mkdir -p "tmp_${item}" && pushd "tmp_${item}" > /dev/null
  git clone ${PATH_CURRENT} .

  ## 현재 dir를 git으로 분리하면서 root path로 만듦
  #git filter-repo --path "$item" --path-rename "$item": --force 
  git filter-repo --subdirectory-filter "$item" --force 

  ## 원격 저장소로 푸시 (선택 사항)
  ## 저장소가 있는지 확인후,remote add, git push
  #curl -su vc.integrator:UUmF3ZYZofW1Jq~~ http://vgit.lge.com/devops_test/a/projects/sample_yocto%2F${item//-/%2d}
  git remote add $REMOTE_NAME ${REMOTE_ADDR}/${item}
  git push $REMOTE_NAME HEAD:${REMOTE_BNCH} -o skip-validation
  # git push origin --all
  # git push origin --tags
  popd
  echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'  
done

## 나머지 남은 현재 dir를 다시 git으로 최종 분리
git filter-repo ${PATH_GIT[@]/#/--path } --invert-paths --force

## 원격 저장소로 푸시(이름지정 필요)
git remote add $REMOTE_NAME ${REMOTE_ADDR}/${REMOTE_GIT_LEFTOVER}
git push $REMOTE_NAME HEAD:${REMOTE_BNCH} -o skip-validation
echo "done"
