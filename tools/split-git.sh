#!/bin/bash -e

## 생성할 manifest
MANI=chipcode.xml

## 스크립트 경로를 맨 앞에서 계산 (pushd 전에)
PATH_SCRIPT=$(dirname $(realpath "$0"))

## common이 있으면 제거하고 PATH_GIT 설정
PATH_GIT=()    #split할 path, common은 별도처리(root dir에 포함)
for item in "$@"; do [[ "$item" != "common" ]] && PATH_GIT+=("$item"); done

printf "\e[1;33m list ============================================================================= \e[0m\n"
echo ${PATH_GIT[@]}
## parameter check - 개수가 0이거나 *를 포함하면 에러
[[ "${PATH_GIT[@]}" =~ "*" ]] && { echo "wildcard * is not allowed"; exit 1; }
if (( "${#PATH_GIT[@]}" == 0 )); then
# 먼저 1) git을 split 하거나 2) remote로 push 하는 기능을 제공한다. (2개 동시에 진행 X)
	cat <<- EOF
	# ex) split
	CMD=down \
	WORK_DIR=/data001/~/sa525m-le-3-1_amss_standard_oem \
	${proFILEdir}/tools/split-git.sh \
	SA525M_aop SA525M_apps ~~

	# ex) push
	# CMD=down|verify|push|mani 중에 선택(down은 소스다운, verify는 push전 remote설정, push는 실제 push, mani는 manifest만 생성)
	CMD=push PUSH_OPT="-o skip-validation --force" \
	WORK_DIR=/data001/~/sa525m-le-3-1_amss_standard_oem \
	REMOTE_NAME=devops REMOTE_ADDR=ssh://vgit.lge.com:29420/qct/sa525m REMOTE_BNCH=refs/heads/release_5.0.9 \
	${proFILEdir}/tools/split-git.sh \
	SA525M_aop SA525M_apps ~~
EOF
fi

## param으로 입력된 git은 독립적인 git(각 dir이름)으로 분리되고, 나머지는 현재 git으로 저장되는 script
## split-get.sh는 .git dir로 copy한후 거기서 실행해야 한다.
if ! command -v git-filter-repo &> /dev/null; then
	echo "Please install by 'sudo apt-get install git-filter-repo'"
	exit 1
fi




PATH_CURRENT="${WORK_DIR%/}" #split을 진행할 dir
[ ! -d "$PATH_CURRENT/.git" ] && { "$0 must be run at .git repository"; exit 1; }

#################################### push logic ####################################
## remote 정보가 있으면 push작업을 진행한다. 이경우 split 작업은 skip한다.
if [ ! "$CMD" = "down" ] && [ -n "${REMOTE_NAME}" ]; then

	# 실행할 명령어를 함수로 정의
	push_to_remote() {
		local dir="$1" cmd="$2"
		set -e
		case $cmd in
 			push)
				pushd "$dir"
				git push $REMOTE_NAME HEAD:${REMOTE_BNCH} ${PUSH_OPT}
				popd
			;;verify|*)
				pushd "$dir" >/dev/null
				##존재하면 삭제하고 다시 등록, 존재하지 않으면 새로등록
				git remote get-url $REMOTE_NAME && { git remote rm $REMOTE_NAME; git remote add $REMOTE_NAME ${REMOTE_ADDR}/${dir}; } || git remote add $REMOTE_NAME ${REMOTE_ADDR}/${dir}
				printf "\e[0;33m check remote is working \e[0m:" ##리모트가 동작하는지 확인
				git ls-remote --exit-code $REMOTE_NAME HEAD > /dev/null && echo "[OKAY]" || echo "[ERR ] not existed - remote"
				printf "\e[0;33m check remote branch is existed \e[0m:" ##브랜치가 존재하는지 확인
				git ls-remote --exit-code $REMOTE_NAME $REMOTE_BNCH > /dev/null && echo "[OKAY]" || echo "[WARN] not existed - remote branch"
				echo "[CMD] git push $REMOTE_NAME HEAD:${REMOTE_BNCH} ${PUSH_OPT}"
				popd >/dev/null
		esac
		set +e
	}

	[ ! -d "${PATH_CURRENT}/.git/filter-repo" ] && { "Please check if this is split finished git :[${PATH_CURRENT}]"; exit 1; }
	cd "${PATH_CURRENT}" #split을 진행할 dir

	# common도 dir로 진입해서 동일하게 작업처리
	count=1
	for item in "common" ${PATH_GIT[@]}; do
		case $CMD in
		mani)   if [[ ! -v url ]]; then
				url=$(echo "$REMOTE_ADDR" | cut -d'/' -f1-3); prefix=$(echo "$REMOTE_ADDR" | cut -d'/' -f4-);
				printf "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest>\n" > ${MANI}
				printf "  <remote name=\"${REMOTE_NAME}\" fetch=\"${url}\" review=\"${url/ssh/http}\"/>\n" >> ${MANI}
				fi
			    printf "  <project name=\"${prefix}/${item}\" path=\"${prefix/qct/nad}/${item}\" revision=\"${REMOTE_BNCH#refs/heads/}\"/>\n" >> ${MANI}
		;;*)
				printf "\e[0;35m [ $((count++)) $CMD $item] ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
				push_to_remote "$item" $CMD
		esac
	done

	# mani 모드일 때 manifest 파일 닫기
	if [ "$CMD" == "mani" ]; then
		printf "\e[0;35m [ mani $(realpath ${MANI})] ~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
		printf "</manifest>\n" >> ${MANI}
		cat ${MANI}
	fi

#################################### split logic ####################################
else
	## split dir를 clone하여 split dir생성
	PATH_SPLIT=${PATH_CURRENT}_split
	rm -rf ${PATH_SPLIT} && mkdir -p ${PATH_SPLIT} && pushd ${PATH_SPLIT}

	## 1st phase: root dir에서 common과 root dir를 합쳐 common으로 1개 git으로 구성
	printf "\e[0;35m [split common]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
	git clone ${PATH_CURRENT} .
	set -x; git filter-repo ${PATH_GIT[@]/#/--path } --invert-paths --force; set +x

	## 2nd phase: root dir안에서 common을 제외한 나머지 dir를 각 git으로 구성
	for item in ${PATH_GIT[@]}; do
		printf "\e[0;35m [split $item]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
		## tmp 새 디렉터리 생성후 git clone
		rm -rf "${item}" && mkdir -p "${item}" && pushd "${item}" > /dev/null
		git clone ${PATH_CURRENT} .

		## 현재 dir를 git으로 분리하면서 root path로 만듦
		#git filter-repo --path "$item" --path-rename "$item": --force
		set -x; git filter-repo --subdirectory-filter "$item" --force; set +x
		popd > /dev/null
	done


	## 원본 dir과 split dir을 .git 제외하고 비교하여, 잘못 생성된건 없는지 확인.
	[ -f "${PATH_SCRIPT}/cmp-dirs.sh" ] || { echo "error: script file is not existed"; exit 1; }
	if EXCEPT=".git;${MANI}" P1="${PATH_SPLIT}" P2="${PATH_CURRENT}" ${PATH_SCRIPT}/cmp-dirs.sh 1 ; then
		printf "\e[0;31m [SUCCESS]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
		printf "=== result is same: \n${PATH_CURRENT} and \n${PATH_SPLIT}\n ==="
		echo ""
		#root dir에 .gitignore를 넣어서, 분리된 git이 다시 포함되지 않도록 처리해줘야함. 수동으로 git commit필요
		echo "all dir are split well, Generate .gitignore on root, You need to commit .gitignore"
		printf "%s\n" ${PATH_GIT[@]}  >> .gitignore
		echo "Now you need to push it to remote"
		exit 0
	else #작업후 in/out dir 내용이 다르면
		printf "\e[0;31m [NEED to CHECK]~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ \e[0m\n"
		printf "=== result is differ: \n${PATH_CURRENT} and \n${PATH_SPLIT} ===\n"
		echo "You may need to overwrite: \$rsync -a --update --exclude='.git/' ${PATH_CURRENT} ${PATH_SPLIT}"
		exit 1
	fi

fi