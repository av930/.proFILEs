#### revv script template
## usage
# repo forall -evc bash 'revvscript.sh' branch 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog master debug
# repo forall -evc bash 'revvscript.sh' branchlist 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog \* debug 
# revv

## repo forall . -c bash 'cmd.sh'                                    # for current git only SHELL variable is available
## repo forall mustang/tm/src honda/linux/build_tsu -c bash 'cmd.sh' # for serveral project
## repo forall $(cat fromfilelist.txt)  -c 'cmd.sh'                  # for serveral project from file
## repo forall -r poky/* -c bash 'cmd.sh'                            # for git projects matched regexp
## repo forall -i poky/* -c bash 'cmd.sh'                            # for git projects not matched regexp
## repo forall -g hlos -c bash 'cmd.sh'                              # for git projects included in specific group
: ' ##options && variable
option -j:jobs, -e:stop if error happen, --ignore-missing:?, --interactive:?
       -p:print gitproject, -v:verbose, -q:only show errors

repo variables $REPO__$VARIABLE, ${REPO_I} ${REPO_COUNT}
        ${REPO_LREV}, ${REPO_REMOTE}, ${REPO_RREV}, ${REPO_PROJECT}, ${REPO_PATH}, ${REPO_INNERPATH}
'

## USER input or define variable
cmd=$1
key=$2
target_branch=${3/\*/}
base_branch=$4
dflag="${@: -1}"
tempf=$(mktemp)


## for degbugging
## DEBUG=[ false | "printf ${RED}%s${NCOL}\n" ]
DEBUG=false
if [ ${dflag} = "debug" ]; then DEBUG="printf ${RED}%s${NCOL}\n"; fi

#no need to close by set +x, repo forall is executed in all sub shell
showRUN(){ [ "${DEBUG}" = "false" ] || set -x; "$@" ; } 
clog()   { printf "${GREEN}$1 ${NCOL} ${@:2}"  ;}

## default variable & functions
NCOL='\e[0m'; YELLOW='\e[1;33m'; RED='\e[1;31m'; GREEN='\e[1;32m';
BAR="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
JSON_IDFY=")]}'"

#### main body 
## title for git project
printf "${BAR}\n${YELLOW}%-10.10b${NCOL} %-12.12b | %-84.84b | %s\n" \
       "[${REPO_I}/${REPO_COUNT}]" "remote:${REPO_REMOTE}" "project:${REPO_PROJECT}" #"branch:${REPO_RREV}" 
       

## preprocess
case ${REPO_REMOTE} in
     __found_error) $DEBUG "case1: error"  && exit 1 
    ;; __skip_case) $DEBUG "case2: skip" && exit 0
    ;;      devops) $DEBUG "case3: preprocess" 
                    url=http://vgit.lge.com/${REPO_REMOTE}_test
esac;

case $cmd in
         branch|branchadd|branchdel) :
    ;;                   branchlist) target_branch="?m=${target_branch}"
    ;;    branchaddpre|branchaddpre) target_branch="${target_branch}${REPO_RREV}"
    ;;  branchaddpost|branchdelpost) target_branch="${REPO_RREV}${target_branch}"
esac
$DEBUG "target_branch: ${target_branch}" 

run_command="curl -s -u $REPO__$USER:${key} ${url}/a/projects/${REPO_PROJECT//'/'/'%2F'}/branches/${target_branch} -o ${tempf}"
## main handler by git branch
case ${REPO_RREV} in
    __branch_A                                      |\
    __select_source                                 ) $DEBUG "caseA: ${REPO_RREV}" 
    
    ;;  
    __branch_B                                      |\
    __select_merge                                  ) $DEBUG "caseB: ${REPO_RREV}" 
        
    ;;  
    __select_other | *                              ) $DEBUG "caseC: ${REPO_RREV}" 
        case $cmd in
                  branch|branchlist) 
                    showRUN ${run_command} 
        ;;     branchadd|branchaddpre|branchaddpost) 
                    showRUN ${run_command} -X PUT -H "Content-Type: application/json" --data "{"revision": "${REPO_RREV}"}" 
        ;;     branchdel|branchdelpre|branchdelpost) 
                    showRUN ${run_command} -X DELETE
        ;;  debug|* ) 
            $DEBUG "positional params: [$0][$1][$2][$3][${@:4}}]"
            $DEBUG "variable check   : [$target_branch][$url][$2][$3][${@:4}}]"
        esac
        if [ "$(cat ${tempf} | head -1)" = "${JSON_IDFY}" ]; then 
            if [ "$(cat ${tempf} | sed -n '2p')" = "[]" ]; then clog "executed" "result is nothing"; cat ${tempf} | tail -n +3
            elif [ "$(cat ${tempf} | sed -n '2p')" = "{" ]; then cat "${tempf}" | sed "1d" | jq  -cC ".|{ref,revision}" 
            else cat "${tempf}" | sed '1d'| jq  -cC '.[]|{ref,revision}'
            fi
        elif [ -z "$(cat ${tempf} | head -1)" ]; then clog "warn" "you must check the result by hand !!"
        else cat "${tempf}"
        fi
esac;
#        ;;    branchlist) showRUN curl -s -u $REPO__$USER:${key} ${url}/a/projects/${REPO_PROJECT//'/'/'%2F'}/branches/?m=${target_branch} -o ${tempf}