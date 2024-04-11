echo #### input value
AD_ID=${AD_ID=vc.integrator}
PROJECT=${PROJECT=honda-tsu-25-5my}
WORKER=${WORKER=honda-25-5my}
CMD_1stBEE=${CMD_1stBEE=$1}
CMD_2ndBEE=${CMD_2ndBEE=$2}
CMD_3rdBEE=${CMD_3rdBEE="testaccount"}

## run from jenkins or cmdline
if [ -n "$JOB_NAME" ];then
   read -p "input password of ${AD_ID} ?" AD_PW
fi

echo #### default value
PATH=.:$PATH
CMD_TEMP=exe_vbee

## get vbee client && login
echo ###########################################################################
wget -q https://cart.lge.com/bee-deploy/bee-cli-v2/vbee/latest/vbee -O $CMD_TEMP && chmod +x $CMD_TEMP
if [ -x $CMD_TEMP ];then $CMD_TEMP --help; else echo "[failed] please check $CMD_TEMP" && exit 1; fi
$CMD_TEMP login -u ${AD_ID} -p  ${AD_PW}
echo ###########################################################################



## parameter pre-processing
A_PARAM=$(IFS=: ; echo "${CMD_3rdBEE[@]}")
## action



function func_worker(){
    echo "func_worker[$1]"
    case "${1%%(*}" in
        list)   $CMD_TEMP worker list                  ;;
        run)    $CMD_TEMP worker run "${WORKER}"       ;;
        "")     menu_worker "${@}"                                                 ;;        
        *) echo invalid; exit 1;;
    esac
}

function func_member(){
    case "${1%%(*}" in
        add) echo "printf "%s\n" ${A_PARAM[@]} | xargs -I{} -t -n1 $CMD_TEMP project add-member --role 10 ${PROJECT} {}" ;;
        list) echo $CMD_TEMP project list-member ${PROJECT} | grep -nEe "( ${A_PARAM[@]/%/|} )";;
        *) echo invalid; exit 1;;
    esac
}


function menu_worker(){
## ---------------------------------------------------------------------------
printf ${green}
cat << PREFACE
===================================================================================================
 common) list, clear
 image) image/images --all, build, hello, find, pull, push, rmi/remove
 container) ps/ps --all, start, run, exec, debug, stop/rm
===================================================================================================
PREFACE
printf ${NCOL}
    local CHOICE
    #local COLUMNS=30
    #local columns="$(tput cols)"
    PS3=$'\e[00;35m=== Please input command! [Number:menu, Ctrl+c:exit] === : \e[0m'
    select CHOICE in list run
    do
        worker $CHOICE
    done
}



function handler_menu(){
## ---------------------------------------------------------------------------
printf ${green}
cat << PREFACE
===================================================================================================
 the menu for vee tools
 -------------------------------------------------------------------------------------------------
 home_dir=${home_dir}"
 -------------------------------------------------------------------------------------------------
 o step: build/pull(image)>> start(container)>> exec(attach)>> stop(container)>> remove(image)
 o step: hello(image)>> run(container)>> exec(attach)>> ...

 supported command category: ex) dock list
 common) list, clear
 image) image/images --all, build, hello, find, pull, push, rmi/remove
 container) ps/ps --all, start, run, exec, debug, stop/rm
===================================================================================================
PREFACE
printf ${NCOL}
    local CHOICE
    #local COLUMNS=30
    #local columns="$(tput cols)"
    PS3=$'\e[00;35m=== Please input command! [Number:menu, Ctrl+c:exit] === : \e[0m'
    select CHOICE in 'worker(list run)' 'member(add list)' 'help'
    do
        handle_commands $CHOICE
    done
}


function handle_commands(){
## ---------------------------------------------------------------------------
local ret=0
    echo "handle_commands[$1]"
    case "${1%%(*}" in
    worker) func_worker "${@:2}"                                                 ;;
    member) func_member "${@:2}"                                                 ;;
    help) help "${@:2}"                                                     ;;
    "") handler_menu "${@}"                                                 ;;
    *) echo there is no matched commands; exit 1;;
    esac
}


##============================================================================
## Main
##============================================================================
# check if called from source or not.
(return 0 2>/dev/null) && sourced=1 || sourced=0
if [ $sourced -eq 0 ]; then handle_commands $@;else echo "plz run without source." && return; fi

## back to original status
rm -f $CMD_TEMP
