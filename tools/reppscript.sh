#### repo template
## usage
# repo forall -evcj4 bash -c 'reppscript.sh'

## description
# repo forall . -c bash 'cmd.sh'                                    # for current git only, make SHELL variable valid
# repo forall mustang/tm/src honda/linux/build_tsu -c bash 'cmd.sh' # for serveral project
# repo forall $(cat fromfilelist.txt)  -c 'cmd.sh'                  # for serveral project from file
# repo forall -r poky/* -c bash 'cmd.sh'                            # for git projects matched regexp
# repo forall -i poky/* -c bash 'cmd.sh'                            # for git projects not matched regexp
# repo forall -g hlos -c bash 'cmd.sh'                              # for git projects included in specific group

## options && variable
# option -j:jobs, -e:stop if error happen, --ignore-missing:?, --interactive:?
#        -p:print gitproject, -v:verbose, -q:only show errors

## repo variables
# $REPO__$VARIABLE
# REPO_I, REPO_COUNT
# REPO_REMOTE, REPO_PROJECT
# REPO_PATH, REPO_INNERPATH, REPO_OUTERPATH
# REPO_LREV, REPO_RREV, REPO_DEST_BRANCH, REPO_UPSTREAM
'

## HEADING 
BAR="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
YELLOW='\e[1;33m'; NCOL='\e[0m';
#err()    { printf "${RED}ERROR: ${NCOL} %b\\n"   ;}
#dlog()   { printf "\n${BAR}\n%b\\n" "${YELLOW}$1 ${NCOL} ${@:2}" ;}
printf "${BAR}\n${YELLOW}%-10.10b${NCOL} %-12.12b|%-26.26b|%-76.76b\n" \
       "[${REPO_I}/${REPO_COUNT}]" "${REPO_REMOTE}" "${REPO_RREV}" "${REPO_PROJECT}"
       

TARGET=${REPO_RREV}_precs1_migration_220214


## exception handler by git project
case ${REPO_PROJECT} in
    vendor/manifest                                 |\
    __found_error                                   ) echo "this case must never happen" && exit 1 
    
    ;;  
    vendor/qct/sa515m/sa515m_wlan_rome/cnss_proc    |\
    __skip_project                                  ) echo "skip projcet" && exit 0
    
    ;;  
    mustang/tm/src                                  |\
    honda/linux/build_tsu                           |\
    __except_project                                ) echo "exception handler" 
        echo git fetch ${REPO_REMOTE} ${TARGET}
        echo git checkout ${REPO_REMOTE}/${TARGET}
        exit 0    
esac;
## goto main


## main handler by git branch
case ${REPO_RREV} in
    __select_source                                 ) echo "select source branch ${REPO_RREV}, stay here" 
    
    ;;  
    tsu_25.5my_release                              |\
    __select_target                                 ) echo "select target branch ${REPO_RREV}, checkout" 
        echo git fetch ${REPO_REMOTE} ${TARGET}
        echo git checkout ${REPO_REMOTE}/${TARGET}
        
    ;;  
    tiger_desktop_release                           |\
    __select_merge                                  ) echo "select branch merge ${REPO_RREV}, merge" 
        echo git fetch ${REPO_REMOTE} ${TARGET}
        echo git merge --no-edit ${REPO_REMOTE}/${TARGET}
        
    ;;  
    __select_other | *                              ) : echo "done"
esac;
