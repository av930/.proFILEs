###### revv script template
## usage
# repo forall -evc bash 'revvscript.sh' branch 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog master debug
# repo forall -evc bash 'revvscript.sh' branchlist 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog \* debug
# repo forall -evc bash -ex 'revvscript.sh' branchlist 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog \* debug

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

##revv
# revv forall branch @branch = repo forall -evc bash 'revvscript.sh' 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog branch @branch
# revv forall branch        master                      # 정확한 이름의 브랜치 존재여부
# revv forall Pbranch       master                      # master branch에 대해 실행명령만 출력, 실제 실행안함
# revv forall Dbranch       master                      # 첫번째 1개 project에 대해 실제 명령을 실행하고, 디버깅정보 출력
# revv forall branch        @branch                     # 현재 branch가 gerrit에 모두 존재하는지 확인(remote 존재여부)
# revv forall branchlist                                # 모든 project에 대해서 모든 브랜치 나열
# revv forall branchlist    '*my*'                      # my가 포함된 branch list up, *는 무시됨.
# revv forall branchlist    mas                         # mas가 들어가는 모든브랜치 나열, branch가 없는 project는 출력안됨
# revv forall branchadd     new master                  # master기준으로 new라는 브랜치 생성, src(master)가 없으면 브랜치 생성안됨
# revv forall branchadd     @branch master              # master기준으로 manifest revision에 기록된 branch를 생성
# revv forall branchaddpre  new_ @branch                # new_<current_branch> 현재 branch에서 new prefix붙인 이름으로 생성
# revv forall branchaddpost _new @branch                # <current_branch>_new 현재 branch에서 new postfix붙인 이름으로 생성
# revv forall branchaddpost _new master                 # master가 존재하는 경우만 master_new가 생성됨
# revv forall branchdel     master                      # master가 존재하는 경우만 해당 branch를 삭제
# revv forall branchdel     @branch                     # 현재 branch 삭제(정확히는 gerrit의 remote branch를 삭제함)
# revv forall branchdelpre  new_ @branch                # 현재 branch기준으로 new_<current_branch> 라는 branch 삭제
# revv forall branchdelpost _new @branch                # <current_branch>_new 삭제하는 명령만 출력


###### setting for env
## USER input
cmd=$1
key_http=$2
target=$3
source=$4

## default variable & functions
BAR="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
NCOL='\e[0m'; YELLOW='\e[1;33m'; RED='\e[1;31m'; GREEN='\e[1;32m';
JSON_IDFY=")]}'"
tempf=$(mktemp)
clog()   { printf "${GREEN}$1 ${NCOL} ${@:2}\n" ;}
err()    { printf "${RED} $BASH_SOURCE [ERROR] ${NCOL} ${*}"   ;}
#no need to close by set +x, repo forall is executed in all sub shell

## setting for debugging
## DEBUG=[ false | "printf ${RED}%s${NCOL}\n" ]
DEBUG=false
case ${cmd::1} in
    D) dflag=${cmd::1}; cmd=${cmd:1};  DEBUG="printf ${RED}%s${NCOL}\n" ;;  ## debug print & run
    P) dflag=${cmd::1}; cmd=${cmd:1}                                    ;;  ## only print without run
esac


showRUN(){
    case ${dflag} in
    P) echo "$@"; exit 0;       ;; #show 1st command & exit
    D) set -x; "$@"; exit 1;    ;; #show 1st command & run & exit
    *) "$@"                     ;; #just run
    esac
}



## builtin-variable specific repo
## get remote & url
CURR_remote=${REPO_REMOTE}
CURR_project=${REPO_PROJECT}
CURR_branch=${REPO_RREV}
CURR_path=${REPO_PATH}
CURR_nrepos=${REPO_COUNT}
CURR_upstream=${REPO_UPSTREAM}
CURR_destbranch=${REPO_DEST_BRANCH}

t_review=$(repo manifest |grep review| grep ${CURR_remote})
a_remote=( $(echo ${t_review} | sed -E 's#.*name="([^"]*[^"]*)".*#\1#') )
a_review=( $(echo ${t_review} | sed -E 's#.*review="([^"]*[^"]*)".*#\1#') )
#for (( i=0; i < ${#a_remote[@]}; i++ )); do echo ${a_remote[$i]}~${review[$i]};done
for (( i=0; i < ${#a_remote[@]}; i++ )); do
    if [ "${REPO_REMOTE}" = "${a_remote[$i]}" ]; then CURR_url=${a_review[$i]}; break; fi
done




###### main body
#### exception handler
##case handler for remote
case ${CURR_remote} in
     __add_user_case) $DEBUG "case#: user added"            ; exit 1 #watchout not skipping exit code
    ;;   __skip_case) $DEBUG "case2: skip"                  ; exit 0
    ;;             *) $DEBUG "case1: default"
esac;
case ${CURR_project} in
     __add_user_case) $DEBUG "case#: user added"            ; exit 1
#   ;; sample_yocto/meta*) $DEBUG "case2: skip"             ; exit 0
    ;;             *) $DEBUG "case1: default"
esac;

## case branch target & source
case $target in
    *\**)
            target="${target//\*/}"; clog "[warn]" "asterisk * is not permitted in gerrit, so removed"
    ;; @branch)
            target="${CURR_branch}"
esac
case $source in
    @branch) source="${CURR_branch}"
esac

## command
case $cmd in
         branch|branchadd|branchdel) :
    ;;                   branchlist) target="?m=${target}"
    ;;    branchaddpre|branchdelpre) target="${target}${REPO_RREV}"
    ;;  branchaddpost|branchdelpost) target="${REPO_RREV}${target}"
    ;;  *) err "command not recongnized, check uasge"; exit 1

esac



## print HEAD for each git project
printf "${BAR}\n${YELLOW}%-10.10b${NCOL} remote:%-12.12b | project:%-84.84b %s\n" \
       "[${REPO_I}/${REPO_COUNT}]" "${REPO_REMOTE}" "${REPO_PROJECT}" #"| branch:${CURR_branch}"


## debugging value
$DEBUG "CURR_remote:${CURR_remote}| CURR_url:${CURR_url}| CURR_project:${CURR_project}| CURR_path:${CURR_path}"
$DEBUG "CURR_branch:${CURR_branch}| CURR_upstream:${REPO_UPSTREAM}| CURR_destbranch:${REPO_DEST_BRANCH}| CURR_nrepos:${CURR_nrepos}"
$DEBUG "input param: cmd: [$cmd]| target: ${target}| source: ${source}"
$DEBUG "positional params: [$0][$1][$2][$3][${@:4}]"


run_command="curl -s -u $REPO__$USER:${key_http} ${CURR_url}/a/projects/${REPO_PROJECT//'/'/'%2F'}/branches/${target} -o ${tempf}"
## main handler by git branch
case ${CURR_branch} in
    __branch_A                                      |\
    __select_source                                 ) $DEBUG "caseA: "

    ;;
    __branch_B                                      |\
    __select_merge                                  ) $DEBUG "caseB: "

    ;;
    __select_other | *                              ) $DEBUG "caseC: "

        set -o noglob #for preventing globbing parameter *
        case $cmd in
                  branch|branchlist)
                    showRUN ${run_command}
        ;;     branchadd|branchaddpre|branchaddpost)
                    showRUN ${run_command} -X PUT -H "Content-Type: application/json" --data "{"revision": "${source}"}"
        ;;     branchdel|branchdelpre|branchdelpost)
                    showRUN ${run_command} -X DELETE
        ;;     *)
                    err "command not recongnized"
        esac
        set +o noglob

        if [ "$(cat ${tempf} | head -1)" = "${JSON_IDFY}" ]; then
            if [ "$(cat ${tempf} | sed -n '2p')" = "[]" ]; then clog "executed" "result is nothing"; cat ${tempf} | tail -n +3
            elif [ "$(cat ${tempf} | sed -n '2p')" = "{" ]; then cat "${tempf}" | sed "1d" | jq  -cC ".|{ref,revision}"
            else cat "${tempf}" | sed '1d'| jq  -cC '.[]|{ref,revision}'
            fi
        elif [ -z "$(cat ${tempf} | head -1)" ]; then clog "warn" "return success, but you must check the result by hand  !"
        else cat "${tempf}"
        fi
esac;