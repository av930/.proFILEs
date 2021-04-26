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



############################### RC setting  #####################################
#Beware that most terminals override Ctrl+S to suspend execution until Ctrl+Q is entered.-
#This is called XON/XOFF flow control. For activating forward-search-history, 
#either disable flow control by issuing:

###############################
#### basic terminal setting
stty -ixon

#default file option on create time
umask 022

#global TAG for alias for banning conflict for builtin commands
export TAG='l'
alias bashg="cd ${HOME}/${proFILEdir}"
alias bashs="source ${HOME}/${proFILEdir}/.bashrc"
alias bashe="vi ${HOME}/${proFILEdir}/.bashrc"


###############################
#### history merge after terminal exit
#export HISTCONTROL=ignoredups:ignorespace same to export HISTCONTROL=ignoreboth
export HISTCONTROL='erasedups:ignorespace'
#history filter out
export HISTIGNORE='pwd:history*:'
# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
export HISTSIZE=10000
export HISTFILESIZE=40000
export HISTTIMEFORMAT='[%F %T]  '

function update_history(){
    history -a
    history -c
    history -r
    shopt -u histappend
}
#update history only login
update_history
#export PROMPT_COMMAND="history -a; history -c; history -r; $PROMPT_COMMAND"
#shopt -s histappend

alias his='history 100'
alias hisgrep='history | egrep -i --color=auto'


###############################
#### screen alias

# screen configuration
# alias byobu='byobu -U $*'
alias ${TAG}sc='screen -ls'
alias ${TAG}scr='screen -U -R'
alias ${TAG}scl="screen -U -R -c ${proFILEdir}/.screenrc_spilt"
alias ${TAG}scx='kill_screen'
function kill_screen()
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

###############################
#### move & find
export alldot='* .[^.]*'

alias ${TAG}du='echo subdir size is; du -sh'
alias ${TAG}ps="ps -u $USER -o pid,args --forest"
alias ${TAG}s='ls -thrF --color=auto --show-control-chars'
alias grep='grep --color=auto'
alias env='env|sort'
alias ${TAG}epo='echo repo sync -qcj4; repo sync -qcj4'
alias dir='ls -al -F --color=auto| grep /'
alias showpath='echo $PATH|sed "s/:/:\n/g"'
alias findgrep='findandgrep'
alias findrm='findandremove'

function findandgrep() { find . -name $1 -print | xargs grep -e "$2";}
function findandremove()
{
    if [ "$1" == "" ]; then echo [WARNING] plz input filename!!
    else find . -name "$1" -exec rm -rf \{\} \;
    fi
}

alias moveup='mv * .[^.]* ..'
alias grepo="goup .repo"
alias gup="goup"
alias gg="godown_withmenu"
alias ga="goaround_withmenu"
function goup()
{
    local TOPFILE=${proFILEdir}
    local HERE=$PWD
    local T=
    while [ \( ! \( -d $TOPFILE \) \) -a \( $PWD != "/" \) ]; do
        T=$PWD
        if [ -d "$T/$@" ]; then
            \cd $T
            return
        fi
        \cd ..
    done
    \cd $HERE
    cd $HOME 
}


function godown_withmenu(){
local INPUT
INPUT=$(find ~/ -mindepth 1 -maxdepth 4 -type d -name "$@" 2> /dev/null)
show_menu_do "$INPUT"
cd ${RET} 
}

function goaround_withmenu(){
local INPUT
#find sub dirtory
INPUT=$(find ./ -maxdepth 2 -type d -name "$@" 2> /dev/null)
#find parents dirtory
INPUT="${INPUT} $(find ../ -maxdepth 2 -type d -name ${PWD##*/} -prune -o -name "$@" 2> /dev/null)"
#find grand parents dirtory
show_menu_do "$INPUT"
echo ${RET}
cd ${RET}
if [ "${RET##*/}" = "${PWD##*/}" ]; then goup "$@";fi
}


alias ${TAG}cp='echo "scp ${USER}@$(hostname -i):${HOME}/filename . ";\
echo scp filename ${USER}@$(hostname -i):${HOME}/'


###############################
#### internal fuction 

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


#### copy & paste http://sourceforge.net/projects/commandlinecopypaste/
# ex-copy: pwd | cc, ex-paste: cd $(cv)
#command line copy+paste dir
export CLCP_DIR="${proFILEdir}"

#command line clipboard file
export CLCF="${proFILEdir}/.path.log"

alias copy_cc="sh ${CLCP_DIR}/cc.sh"
alias coyp_cv="cat ${CLCF}"
#alias lll="launch_cur_dir | cc; cv"
alias lll="launch_cur_dir"



#### vi startup option
alias  vi="VIMINIT=':so ~/.vim/.vimrc' MYVIMRC='~/.vim/.vimrc' vim $*"
alias  vimp="VIMINIT=':so ~/.viu/.vimrc_backup' MYVIMRC='~/.viu/.vimrc_backup' vim $* -V9myLog"
alias  vimu="VIMINIT=':so ~/.viu/.vimrc' MYVIMRC='~/.viu/.vimrc' vim $*" 
alias  vimo="VIMINIT=':so ~/.vio/.vimrc' MYVIMRC='~/.vio/.vimrc' vim $* -V9myLog"

#go file on symbol definition
alias vimt='vi -t'







##################################################################################
##################################################################################
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
