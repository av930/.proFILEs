###### revv script template
## usage
# repo forall -evc bash 'revvscript.sh' branch master
# repo forall -evc bash 'revvscript.sh' branchlist \*
# repo forall -evc bash -ex 'revvscript.sh' branchlist \*

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

##revv set cmd
# revv forall setgit .                                  #repo forall을 적용시킬 git을 설정한다. .은 현재 git
# revv forall setgit sample/poky sample/meta-browser    #나열된 2개의 git에만 적용한다.
# revv forall setgit                                    #설정된 git정보를 없앤다. 모든 git에 적용한다.

##revv run cmd
# revv forall branch @branch = repo forall -evc bash 'revvscript.sh' branch @branch
# revv forall branch        master                      # 정확한 이름의 브랜치 존재여부
# revv forall Pbranch       master                      # master branch에 대해 실행명령만 출력, 실제 실행안함
# revv forall Dbranch       master                      # 첫번째 1개 project에 대해 실제 명령을 실행하고, 디버깅정보 출력
# revv forall branch        @branch                     # 현재 branch가 gerrit에 모두 존재하는지 확인(remote 존재여부)
# revv forall branchlist                                # 모든 project에 대해서 모든 브랜치 나열
# revv forall branchlist    '*my*'                      # my가 포함된 branch list up, *는 무시됨.
# revv forall branchlist    mas                         # mas가 들어가는 모든브랜치 나열, branch가 없는 project는 출력안됨
# revv forall branchadd     new master                  # master기준으로 new라는 브랜치 생성, src(master)가 없으면 브랜치 생성안됨
# revv forall branchadd     @branch master              # master기준으로 manifest revision에 기록된 branch를 생성
# revv forall branchaddpre  new_ @branch                # new_<current_branch> 현재 branch에서 new prefix붙인 이름으로 생성
# revv forall branchaddpost _new @branch                # <current_branch>_new 현재 branch에서 new postfix붙인 이름으로 생성
# revv forall branchaddpost _new master                 # master가 존재하는 경우만 master_new가 생성됨
# revv forall branchdel     master                      # master가 존재하는 경우만 해당 branch를 삭제
# revv forall branchdel     @branch                     # 현재 branch 삭제(정확히는 gerrit의 remote branch를 삭제함)
# revv forall branchdelpre  new_ @branch                # 현재 branch기준으로 new_<current_branch> 라는 branch 삭제
# revv forall branchdelpost _new @branch                # <current_branch>_new 삭제하는 명령만 출력
# revv forall project                                   # manifest에 기록된 모든 프로젝트가 존재하는지 확인
# revv forall projectadd    parent_git                  # manifest에 기록된 모든 프로젝트를 추가및 부모설정
# revv forall projectdel                                # manifest에 기록된 모든 프로젝트에 대해 삭제가 가능한 link제공
                                                        # gerrit은 project를 삭제할수 있는 cli cmd는 제공하지 않음.

source ${proFILEdir}/tools/prelibrary > /dev/null


###### revvserver_item function (independent from repp script)
function revvserver_item() {
## ---------------------------------------------------------------------------
## return remote (gerrit server) info as a various type
## format: revvserver_item <remote> <return_type>
## return_type: port|http|sub|domain|subdomain|path|url|key|user|pass|alias|debug
## This function is independent from repp script and loads server info from ~/.key_server.en

    local ret=0 remote=$1 prn _line
    local return_type=$2

    ## 파라미터 개수가 반드시 2개이상이어야 동작
    [ "$remote" = "help" ] && return 0
    [ $# -lt 2 ] && { err "revvserver_item requires 2 params: <remote> <return_type>"; return 1; }

    ## ~/.key_server.en 파일이 없으면 에러
    if ! [ -f $HOME/.key_server.en ]; then
        err "You must create server connection info, use 'revv server gen'" >&2
        return 1
    fi

    ## REVV_SERVER 배열이 없으면 로드
    if [ -z "${REVV_SERVER_LOADED}" ] || [ ${#REVV_SERVER[@]} -eq 0 ]; then
        declare -gA REVV_SERVER  # global associative array
        while IFS='|' read -r key url account pass alias; do
            key=$(echo "$key" | xargs) # 앞뒤 공백 제거
            REVV_SERVER["$key"]="${key}|${url}|${account}|${pass}|${alias}"
        done < <(cat "$HOME/.key_server.en" | openssl enc -base64 -d -aes-256-cbc -nosalt -pbkdf2 -pass pass:garbageKey | awk -F'|' 'p{print} $1 ~ /^REMOTEKEY */ {p=1}')
        REVV_SERVER_LOADED=1
    fi

    ## 입력된 remote 이름을 정리 (URL 형식이면 http로 통일)
    [[ $remote =~ ^https?://[^/]+/[^/]+ ]] && remote="${BASH_REMATCH[0]/https/http}"

    ## REVV_SERVER 배열에서 server 정보 찾기
    ## 1) key 정확히 일치, 2) alias에 포함, 3) url에 포함
    _line=$(printf "%s\n" "${REVV_SERVER[@]}" | sort | awk -v tag="$remote" -F '[[:space:]]*\\|' '
        $1 == tag   {print; exit}   # key exact match
        $5 ~ tag    {print; exit}   # alias contains
        $2 ~ tag    {print; exit}') # url contains

    ## server 정보가 없으면 에러
    [ -z "$_line" ] && { err "server information[$remote] is null"; return 1; }
    local _item=$(echo "$_line" | cut -d'|' -f2)

    case ${return_type} in
            http)    prn=$(echo "${_item%:*}")                                                     # http://vgit.lge.com/na
    ;;       url)    prn=$(echo "${_item#*://}"| awk -F[./:\ ] '{$4="/"$4;gsub(/\/none_.*/,"",$4);print $1"."$2"."$3$4}')  # vgit.lge.com/na
    ;;      user)    prn=$(echo "$_line"  | cut -d'|' -f3)                                         # vc.integrator
    ;;      pass)    prn=$(echo "$_line"  | cut -d'|' -f4)                                         # HTTP password
    ;;         *)    prn='';  ret=1                                                                # error
    esac

    [ -n "$prn" ] && { echo "$prn" | xargs; return 0; } || return 1
}


###### setting for env
## USER input
cmd=$1         #branch, project
target=$2      #branch-name, parent-project-name
source=$3      #base-branch-name

## default variable & functions
linewave="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
NCOL='\e[0m'; YELLOW='\e[1;33m'; RED='\e[1;31m'; GREEN='\e[1;32m';
JSON_IDFY=")]}'"
tempr=/tmp/revv.ret
tempf=$(mktemp)
if [ ! -f "${tempf}" ]; then touch "${tempf}"; fi

clog()   { printf "${GREEN}$1 ${NCOL} ${@:2}\n" ;}
err()    { printf "${RED} $BASH_SOURCE [ERROR] ${NCOL} ${*}"   ;}
#no need to close by set +x, repo forall is executed in all sub shell

## setting for debugging
## DEBUG=[ false | "printf ${RED}%s${NCOL}\n" ]
## type flag and pass to command to cmd
DEBUG=false
case ${cmd::1} in
  P|E|O) tflag=${cmd::1}; cmd=${cmd:1}                                    ;;  ## print on
      D) tflag=${cmd::1}; cmd=${cmd:1};  DEBUG="printf ${RED}%s${NCOL}\n" ;;  ## debug print & run
esac


## stop flag is true, run current cmd and stop all next.
sflag=false
showRUN(){
    case ${tflag} in
    E) "$@";                             ;; #run command, break if error occurred.
    P) echo "$@";                        ;; #show command without running cmd, continue.
    O) sflag=true; echo "$@";            ;; #show only 1st command & break.
    D) sflag=true; set -x; "$@";         ;; #show only 1st command & run & break.
    *) "$@"                              ;; #run command, continue regardless of result.
    esac
}


## builtin-variable specific repo
## get remote & url
CURR_remote=${REPO_REMOTE}
CURR_project=${REPO_PROJECT}
CURR_branch=${REPO_RREV}
CURR_path=${REPO_PATH}
CURR_ntot=${REPO_COUNT}
CURR_n=${REPO_I}
CURR_upstream=${REPO_UPSTREAM}
CURR_destbranch=${REPO_DEST_BRANCH}

t_review=$(repo manifest 2>/dev/null |grep review| grep ${CURR_remote})
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
    ;;   __skip_case) $DEBUG "case2: skip"                  ; exit 0
    ;;             *) $DEBUG "case1: default"
esac;
case ${CURR_branch} in
     __add_user_case) $DEBUG "case#: user added"            ; exit 1
#   ;; sa515m_le2.3_release) $DEBUG "case2: skip"           ; exit 0
    ;;             *) $DEBUG "case1: default"
esac;


## case branch target & source
SEP='~'
case ${cmd}${SEP}${target} in
                  *\**) target="${target//\*/}"; clog "[warn]" "asterisk * is not permitted in gerrit, must check"
    ;; branch*~@branch) target="${CURR_branch}"
          ;; project*~) :
        ;; branchlist~) : ##allow target=null
           ;; branch*~) err "target is null, stop some commands may be not stopped, must check"; exit 1;
esac
case $source in
    @branch) source="${CURR_branch}"
esac

## command
case $cmd in
                    branch|branchadd|branchdel) :
    ;;                              branchlist) target="?m=${target}"
    ;;     branchpre|branchaddpre|branchdelpre) target="${target}${REPO_RREV}"
    ;;  branchpost|branchaddpost|branchdelpost) target="${REPO_RREV}${target}"
    ;;                                project*) :
    ;;                                 access*) :
    ;;                                       *) err "command not recongnized, check usage"; exit 1

esac



## print HEAD for each git project
printf "${linewave}\n${YELLOW}%-10.10b${NCOL} remote:%-12.12b | project:%-84.84b %s\n" \
       "[${REPO_I}/${REPO_COUNT}]" "${REPO_REMOTE}" "${REPO_PROJECT}" #"| branch:${CURR_branch}"


## manifest의 fetch URL이 달라 git project를 제대로 못읽어올경우 error처리
fetch_project=$(git config --get-regexp remote.*.url|cut -d' ' -f2|head -1| sed -E "s#^.*://.*:[0-9]+/(.*?${REPO_PROJECT})\$#\1#")
if [ "${REPO_PROJECT}" = "${fetch_project}" ]; then CURR_project=${REPO_PROJECT};
else CURR_project=${fetch_project}; clog "warn" "project name is not matched, use ${fetch_project}"
fi

$DEBUG "CURR_remote:${CURR_remote}| CURR_url:${CURR_url}| CURR_project:${CURR_project}| CURR_path:${CURR_path}"
$DEBUG "CURR_branch:${CURR_branch}| CURR_upstream:${REPO_UPSTREAM}| CURR_destbranch:${REPO_DEST_BRANCH}| CURR_ntot:${CURR_ntot}"
$DEBUG "input param: cmd: [$cmd]| target: ${target}| source: ${source}"
$DEBUG "positional params: [$0][$1][$2][$3][${@:4}]"

key_http=$(revvserver_item ${CURR_remote} pass)

cmd_branch="curl -su $REPO__$USER:${key_http} ${CURR_url}/a/projects/${CURR_project//'/'/'%2F'}/branches/${target} -o ${tempf}"
cmd_project="curl -su $REPO__$USER:${key_http} ${CURR_url}/a/projects/${CURR_project//'/'/'%2F'} -o ${tempf}"
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
             branch|branchpre|branchpost|branchlist)
                    showRUN ${cmd_branch}
        ;;     branchadd|branchaddpre|branchaddpost)
                    showRUN ${cmd_branch} -X PUT -H "Content-Type: application/json" --data "{"revision": "${source}"}"
        ;;     branchdel|branchdelpre|branchdelpost)
                    showRUN ${cmd_branch} -X DELETE
        ;;     project)
                    showRUN ${cmd_project}
        ;;     projectadd)
                    showRUN ${cmd_project} -X PUT
                    showRUN ${cmd_project}/parent -X PUT -H "Content-Type: application/json" --data "{"parent": "${target}"}"
        ;;     projectdel)
                    echo ${CURR_url}/admin/repos/${CURR_project//'/'/'%2F'},commands; exit 0
        ;;     accessurl)
                    echo ${CURR_url}/admin/repos/${CURR_project//'/'/'%2F'},access;
                    showRUN ${cmd_project}
        ;;     *)
                    err "command not recongnized!"; exit 1
        esac
        set +o noglob

        ## parse result &
        case $cmd in
        branch*)   PRINT_INFO='{ref,revision}';;
        project*|access*)  PRINT_INFO='{name,parent}' ;;
        esac

        if [ "$(cat ${tempf} | head -1)" = "${JSON_IDFY}" ]; then
            cat ${tempf} | sed 1d| jq -rM > ${tempf}_bk; mv ${tempf}_bk ${tempf}

            if [ "$(cat ${tempf} | sed -n '1p')" = "[]" ]; then clog "executed" "result is nothing"; cat ${tempf} | tail -n +3;  RET=FAIL1
            elif [ "$(cat ${tempf} | sed -n '1p')" = "{" ]; then cat "${tempf}" | jq -cC ".|${PRINT_INFO}"; RET=OKAY1
            else cat "${tempf}" | jq  -cC ".[]|${PRINT_INFO}";  RET=OKAY2
            fi
        elif [ -z "$(cat ${tempf})" ]; then clog "warn" "API executed, but return is not JSON, please check." ;  RET=OKAY3
        else cat "${tempf}" ;clog "warn" "API executed, but return is not JSON, please check.";  RET=FAIL2
        fi

        $DEBUG [$CURR_n] [$RET] [$sflag]
        ## handle for Ecmd
        [[ "${RET}" =~ "FAIL" ]] && sflag=true
        #to break forall by sending ERROR

        if "${sflag}"; then err "stopped by stopflag"; exit 1; fi
        #show result summury of each git repository after running a command
        printf "%4.4s: [%4.4s] %s\n" "${RET}" "${CURR_n}" "${CURR_project}" >> ${tempr}
esac;