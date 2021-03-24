############################## COMMON .bashrc #####################################
:<< COMMENT
# below code should be inserted in .bashrc
# usually end of file is ok, or user dependent postion is ok, or after these line
#    . ~/.bash_aliases
#    . /etc/bash_completion
printf '[%s] runned: [%s] sourced\n' "$0" "$BASH_SOURCE"
if [ -f "${proFILEdir}/.bashrc" ]; then source "${proFILEdir}/.bashrc"; fi

# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return
COMMENT


############################## Prompt DEFINE #####################################

############################### RC setting  #####################################
#Beware that most terminals override Ctrl+S to suspend execution until Ctrl+Q is entered.-
#This is called XON/XOFF flow control. For activating forward-search-history, either disable flow control by issuing:
stty -ixon
#terminal setting

#default file option on create time
umask 022

#### history merge for multi terminal
#export HISTCONTROL=ignoredups:ignorespace same to export HISTCONTROL=ignoreboth
export HISTCONTROL='erasedups:ignorespace'
#history filter out
export HISTIGNORE='pwd:history*:pscp*'

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
export HISTSIZE=10000
export HISTFILESIZE=40000
shopt -s histappend
export HISTTIMEFORMAT='[%F %T]  '
export PROMPT_COMMAND="history -a; history -c; history -r; $PROMPT_COMMAND"
alias his='history 50'

############################### USER DEFINE #####################################
export alldot='* .[^.]*'
alias ls='ls -thrF --color=auto --show-control-chars'
alias grep='grep --color=auto'
alias env='env|sort'
alias dir='ls -al -F --color=auto| grep /'

############################### Tool ALIAS #####################################

alias ps="ps -u $USER -o pid,args --forest"
alias du='echo subdir size is; du -sh'
# screen configuration
# alias byobu='byobu -U $*'
alias sccl='screen -ls'
alias sccr='screen -U -R'
alias sccs="screen -U -R -c ${proFILEdir}/.screenrc_spilt"
function sccx()
{
    if [ "$1" != "" ]; then 
       #kill only one
       screen -S $1 -X quit
    else
       #kill all
       #alias scx="screen -ls | grep Detached | cut -f1 -d .| xargs -i screen -S {} -X quit"
       for var in $(screen -ls | grep Detached | cut -f1 -d .)
       do
           screen -S $var -X quit
       done
    fi
}

############################### ENV DEFINE ######################################
alias moveup='mv * .[^.]* ..'
alias gpro="cd ${proFILEdir}"
function gtop()
{
    local TOPFILE=${proFILEdir}
    local HERE=$PWD
    local T=
    while [ \( ! \( -d $TOPFILE \) \) -a \( $PWD != "/" \) ]; do
        T=$PWD
        if [ -d "$T/.repo" ]; then
            \cd $T
            return
        fi
        \cd ..
    done
    \cd $HERE
    cd $HOME 
}


function setup-gdb()
{
    adb devices
    echo "only 1 device: enter, more than 1: -e or -d"
    read choice
    adb $choice forward tcp:5039 tcp:5039
    adb $choice shell ps
    echo -n "Which process? with & for background:"
    read process_id
    adb $choice shell gdbserver :5039 --attach $process_id &
}

function start-gdb()
{
    if [ "$1" == "" ]; then 
        echo [WARNING] "you must run envsetup.sh \& lunch before gdb"
        echo [WARNING] current PRODUCT_OUT is $(get_build_var PRODUCT_OUT)
        echo [WARNING] plz input \$PRODUCT_OUT/symbols/system/xxx 
        echo \$1 should be symbol file, \$2 optionally could be remote ip
        return 
    fi

    # should be ndk gdb for windows
    if [ "${OSTYPE}" == "cygwin" ]; then
        local GDB=/cygdrive/d/SDK/Android/android-ndk-r8b/toolchains/arm-linux-androideabi-4.6/prebuilt/windows/bin/arm-linux-androideabi-gdb.exe
    else
        local GDB=prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.6/bin/arm-linux-androideabi-gdb
        export PATH=$PATH:~/out/host/linux-x86/bin/adb
    fi

    # should be product dir
    local OUT_SYMBOLS=$(expr match "$1" '\(.*symbols\)')
    local OUT_SO_SYMBOLS=$OUT_SYMBOLS/system/lib



    echo >|"gdbclient.cmds" "set solib-absolute-prefix $OUT_SYMBOLS"
    echo >>"gdbclient.cmds" "set solib-search-path $OUT_SO_SYMBOLS:$OUT_SO_SYMBOLS/hw:$OUT_SO_SYMBOLS/ssl/engines"
    echo >>"gdbclient.cmds" "target remote $2:5039"
    echo >>"gdbclient.cmds" ""

    cat "gdbclient.cmds"
    echo "cgdb -d $GDB -x gdbclient.cmds $1"
    cgdb -d $GDB -x "gdbclient.cmds" $1

}
alias show-path='echo $PATH|sed "s/:/:\n/g"'


############################### Utility #####################################
alias  vi="VIMINIT=':so ~/.vim/.vimrc' MYVIMRC='~/.vim/.vimrc' vim $*"
alias  vimp="VIMINIT=':so ~/.viu/.vimrc_backup' MYVIMRC='~/.viu/.vimrc_backup' vim $* -V9myLog"
alias  vimu="VIMINIT=':so ~/.viu/.vimrc' MYVIMRC='~/.viu/.vimrc' vim $*" 
alias  vimo="VIMINIT=':so ~/.vio/.vimrc' MYVIMRC='~/.vio/.vimrc' vim $* -V9myLog"

#go file on symbol definition
alias vimt='vi -t'


function findgrep() { find . -name $1 -print | xargs grep -e "$2";}
function findrm()
{
    if [ "$1" == "" ]; then echo [WARNING] plz input filename!!
    else find . -name "$1" -exec rm -rf \{\} \;
    fi
}

alias scp_echo='echo scp-get;echo "scp joongkeun.kim@100.1.1.1:/home/joongkeun.kim/filename . ";echo scp filename joongkeun.kim@$SOLAR:/home/joongkeun.kim'


function show_menu_do(){
## ---------------------------------------------------------------------------
# show the menu and make user select one from it.

local lines
#should be up one token
lines=($1)
if [[ ${#lines[@]} = 0 ]]; then
    echo "Not found"
    return 1
fi
local pathname
local choice
if [[ ${#lines[@]} > 1 ]]; then
    while [[ -z "$pathname" ]]; do
        local index=1
        local line
        for line in ${lines[@]}; do
            printf "%6s %s\n" "[$index]" $line
            index=$(($index + 1))
        done
        echo
        echo -n "Select one: "
        unset choice
        read choice
        if [[ $choice -gt ${#lines[@]} || $choice -lt 1 ]]; then
            echo "Invalid choice"
            continue
        fi
        pathname=${lines[$(($choice-1))]}
    done
else
    # even though zsh arrays are 1-based, $foo[0] is an alias for $foo[1]
    pathname=${lines[0]}
fi
 RET=$pathname
 return 0
}

function show-out(){
local INPUT
INPUT=$(find ~/ -maxdepth 3 -type d -name "out*" -exec \
    find {}/target/product -mindepth 1 -maxdepth 1 -type d \; 2> /dev/null)
show_menu_do "$INPUT"
cd ${RET} 
}


# copy & paste http://sourceforge.net/projects/commandlinecopypaste/
## ---------------------------------------------------------------------------
# ex-copy: pwd | cc, ex-paste: cd $(cv)
#command line copy+paste dir
export CLCP_DIR="${proFILEdir}"

#command line clipboard file
export CLCF="${proFILEdir}/.path.log"

alias copy_cc="sh ${CLCP_DIR}/cc.sh"
alias coyp_cv="cat ${CLCF}"
#alias lll="launch_cur_dir | cc; cv"
alias lll="launch_cur_dir"


printf '[%s] runned: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"

# load target specific
##################################################################################
USR_FILE=${proFILEdirOS}/.bashrc
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}" ;fi

# load android & repo
##################################################################################
USR_FILE=${proFILEdir}/android/android
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}" ;fi
USR_FILE=${proFILEdir}/android/repo
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}" ;fi

# show banner when login in screen
##################################################################################
USR_FILE=${proFILEdir}/.banner

if [ -f "${USR_FILE}" ] && [ -n "$STY" ] && [ "$opt_banner" = "yes" ] 
	then source "${USR_FILE}" 
fi
