#### revv script template
## usage
# repo forall -evc bash 'revvscript.sh' branch 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog master debug
# repo forall -evc bash 'revvscript.sh' branchlist 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog \* debug 
# repo forall -evc bash -ex 'revvscript.sh' branchlist 8VJBTc1TpTLNzJRwiHa1pAnnE64SF2gprMa8+iviog \* debug 
# revv

## repo forall . -c bash 'cmd.sh'                                    # for current git only, make SHELL variable valid
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

#### USER input or define variable
cmd=$1
key_http=$2
target=$3
source=$4
dflag="${@: -1}"

## default variable & functions
NCOL='\e[0m'; YELLOW='\e[1;33m'; RED='\e[1;31m'; GREEN='\e[1;32m';
BAR="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
JSON_IDFY=")]}'"
tempf=$(mktemp)
clog()   { printf "${GREEN}$1 ${NCOL} ${@:2}"  ;}
#no need to close by set +x, repo forall is executed in all sub shell
showRUN(){ 
    case ${dflag} in
    printdebug) echo "$@"; exit 1;  ;; #show 1st command & exit    
    debug) set -x; "$@"             ;; #show command & run
        *) "$@"                     ;; #just run
    esac
} 


## setting for debugging
## DEBUG=[ false | "printf ${RED}%s${NCOL}\n" ]
DEBUG=false
if [[ ${dflag} =~ "debug" ]]; then DEBUG="printf ${RED}%s${NCOL}\n"; fi

#target source 
CURR_remote=${REPO_REMOTE}
CURR_project=${REPO_PROJECT} 
CURR_branch=${REPO_RREV}
CURR_path=${REPO_PATH}
CURR_nrepos=${REPO_COUNT}
CURR_url=
## get remote & url 
t_review=$(repo manifest |grep review)
t_remote=( $(echo ${t_review} | sed -E 's#.*name="([^"]*[^"]*)".*#\1#') )
t_review=( $(echo ${t_review} | sed -E 's#.*review="([^"]*[^"]*)".*#\1#') )
#for (( i=0; i < ${#t_remote[@]}; i++ )); do echo ${t_remote[$i]}~${review[$i]};done
case ${CURR_remote} in
     __found_error) $DEBUG "case1: error"  && exit 1 
    ;; __skip_case) $DEBUG "case2: skip" && exit 0
    ;;           *) $DEBUG "case3: all" 
            for (( i=0; i < ${#t_remote[@]}; i++ )); do [ "${REPO_REMOTE}" = "${t_remote[$i]}" ] && CURR_url=${t_review[$i]}; done
esac;

dlog "aaa ${AAA}"

#### preprocessing parameter 
## branch
case $target in
    help) $DEBUG "branch input ${target}"
    ;; *debug*|'')
            clog "[error] you must check parameter"
            echo "revvscript.sh <cmd> <key_http> <branch-name> [<base-branch> <debug option>]"
            echo "revv <cmd> <branch-name> [<base-branch> <debug option>]"
            exit 1; 
    ;; *\**) 
            clog "gerrit cannot process [*], remove it automatically";
            target="${target//\*/}"
    ;; @branch)
            target="${REPO_RREV}"
esac


$DEBUG [ "${target}${source}${target_project}${curr_remote}${curr_path}" ]

case $source in
    @branch) source="${REPO_RREV}" 
esac

## command
case $cmd in
         branch|branchadd|branchdel) :
    ;;                   branchlist) target="?m=${target}"
    ;;    branchaddpre|branchaddpre) target="${target}${REPO_RREV}"
    ;;  branchaddpost|branchdelpost) target="${REPO_RREV}${target}"
esac





#### main body 
## print HEAD for each git project
printf "${BAR}\n${YELLOW}%-10.10b${NCOL} remote:%-12.12b | project:%-84.84b %s\n" \
       "[${REPO_I}/${REPO_COUNT}]" "${REPO_REMOTE}" "${REPO_PROJECT}" #"| branch:${REPO_RREV}" 
       
$DEBUG "url: ${CURR_url} target: ${target}" 

run_command="curl -s -u $REPO__$USER:${key_http} ${CURR_url}/a/projects/${REPO_PROJECT//'/'/'%2F'}/branches/${target} -o ${tempf}"
## main handler by git branch
case ${REPO_RREV} in
    __branch_A                                      |\
    __select_source                                 ) $DEBUG "caseA: ${REPO_RREV}" 
    
    ;;  
    __branch_B                                      |\
    __select_merge                                  ) $DEBUG "caseB: ${REPO_RREV}" 
        
    ;;  
    __select_other | *                              ) $DEBUG "caseC: ${REPO_RREV}" 

        set -o noglob #for preventing globbing parameter *
        case $cmd in
                  branch|branchlist) 
                    showRUN ${run_command} 
        ;;     branchadd|branchaddpre|branchaddpost) 
                    showRUN ${run_command} -X PUT -H "Content-Type: application/json" --data "{"revision": "${source:-${REPO_RREV}}"}" 
        ;;     branchdel|branchdelpre|branchdelpost) 
                    showRUN ${run_command} -X DELETE
        ;;  debug|* ) 
            $DEBUG "positional params: [$0][$1][$2][$3][${@:4}}]"
            $DEBUG "variable check   : [$target][$CURR_url][$2][$3][${@:4}}]"
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