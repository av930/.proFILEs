#### repo template
## usage
## copy this script to your REPO_PATH
# 1. cp ~/.proFILEs/tools/reposcript.sh ./reposcript.sh
# 2. or repo forall -evcj4 bash -c 'reposcript.sh'

## call like this
# repo forall -evcj4 bash -c 'reposcript.sh'                               # if exit 1, repo forall will be stopped
# repo forall . -ec bash 'reposcript.sh'                                   # for current git only, make SHELL variable valid
# repo forall -evcj4 bash -c 'reposcript.sh ${@:0}' aaa bbb ccc ddd        # passing parameters to reposcript.sh
# repo forall mustang/tm/src honda/linux/build_tsu -c bash 'reposcript.sh' # for serveral project
# repo forall $(cat fromfilelist.txt)  -c 'reposcript.sh'                  # for serveral project from file
# repo forall -r poky/* -c bash 'reposcript.sh'                            # for git projects matched regexp
# repo forall -i poky/* -c bash 'reposcript.sh'                            # for git projects not matched regexp
# repo forall -g hlos -c bash 'reposcript.sh'                              # for git projects included in specific group

## reference options && variable
# option -j:jobs, -e:stop if error happen, -p:print gitproject, -v:verbose, -q:only show errors
#        --ignore-missing:?, --interactive:?

## reference repo variables
# echo ${!REPO_*}
# $REPO__$VARIABLE
# $REPO_I, $REPO_COUNT
# $REPO_REMOTE, $REPO_PROJECT
# $REPO_PATH, $REPO_INNERPATH, $REPO_OUTERPATH
# $REPO_LREV, $REPO_RREV, $REPO_DEST_BRANCH, $REPO_UPSTREAM


BAR="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
RED='\e[1;31m'; YELLOW='\e[1;33m'; NCOL='\e[0m'; GREEN='\e[1;32m'; CYAN='\e[1;36m';
log()   { printf "%b\\n" "${*}"  ;}
err()   { log "${RED}ERROR: ${NCOL} ${*}"   ;}
warn()  { log "${YELLOW}WARN : ${NCOL} ${*}" ;}
info()  { log "${CYAN}INFO : ${NCOL} ${*}" ;}
#log()     { printf "\n${BAR}\n%b\\n" "${YELLOW}$1 ${NCOL} ${@:2}" ;}


## title
printf "${BAR}\n${YELLOW}%-10.10b${NCOL} %-12.12b|%-26.26b|%-80.80b|%b\n" \
       "[${REPO_I}/${REPO_COUNT}]" "${REPO_REMOTE}" "${REPO_RREV}" "${REPO_PROJECT}" "${REPO_PATH}"


## pre-process by git project
case ${REPO_PROJECT} in
    vendor/example/__sample_case                    |\
    vendor/example/case_error                       ) 
        err "error occure & stop repo forall"      && exit 1

    ;;
    vendor/example/__sample_case                    |\
    vendor/example/case_skip                        ) 
        echo "skip projcet & continue repo forall" && exit 0

    ;;
    vendor/example/__sample_case                    |\
    vendor/example/case_prerun                      ) 
        echo "pre-run & continue repo forall"
        #echo git fetch ${REPO_REMOTE} ${REPO_RREV}_precs1_migration_220214
        #echo git checkout ${REPO_REMOTE}/${REPO_RREV}_precs1_migration_220214
       
        exit 0
esac;
#### always processed
## example print info 
err  ${REPO_REMOTE} ${REPO_PROJECT} [$1][$2][$3]
warn ${REPO_REMOTE} ${REPO_PROJECT} $2
info ${REPO_REMOTE} ${REPO_PROJECT} $@


echo ${!REPO_*}

## example git check
#git remote show "ssh://vc.integrator@61.189.53.205:29418/${REPO_PROJECT}" > /dev/null

## example git push
#git push ssh://vc.integrator@61.189.53.205:29418/${REPO_PROJECT} HEAD:refs/heads/cockpit_neusoft_ss_PR230719


