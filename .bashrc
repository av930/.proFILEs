## debug .bashrc with set -x / set +x
#set -x

############################## COMMON .bashrc #####################################
printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"
############################## COMMON .bashrc #####################################
:<< COMMENT
# 1. below code called from .profile
# 2. otherwise it could be called from .bashrc or .bash_aliases from HOME.
# 3. this line located in usually end of file, or user dependent postion, or after these line
#    . ~/.bash_aliases , . /etc/bash_completion
printf '[%s] runned: [%s] sourced\n' "$0" "$BASH_SOURCE"
if [ -f "${proFILEdir}/.bashrc" ]; then source "${proFILEdir}/.bashrc"; fi

# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return
COMMENT

# find proFILEs path
##################################################################
#proFILEdir="${BASH_SOURCE%/*}/.proFILEs"
proFILEdir="$HOME/.proFILEs"
#in case of link file
#if [ ! -L "$HOME/$BASH_SOURCE" ]; then ln -fs  ${proFILEdir}/$1 $HOME/$1; fi

proFILEdirOS='unknown'

if [ $(expr match "$OSTYPE" 'cygwin') -ne 0 ]
then proFILEdirOS=${proFILEdir}/cygwin
else proFILEdirOS=${proFILEdir}/linux
fi


############################### make non-login shell  #####################################
USR_FILE=${proFILEdir}/.profile
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}"; fi

############################### RC setting  #####################################
#Beware that most terminals override Ctrl+S to suspend execution until Ctrl+Q is entered.-
#This is called XON/XOFF flow control. For activating forward-search-history,
#either disable flow control by issuing:

###############################
#### default file option on create time
#umask 022 #private read by others
umask 002 #share read/write with group
#umask 077 #secret read by only me
#sudo gpasswd -a temp_user temp_group

###############################
#### profile alias
#global TAG for alias for banning conflict for builtin commands
export ECHO='e'
export TAG='l'
export allfile='* .[^.]*'
export dotfile='.[^.]*'
function CMD(){
    echo "cmd: $@"; 
    "$@" ;
}

alias pro="cd ${proFILEdir}"
alias tools="cd ${proFILEdir}/tools"
alias src="cd ~/Docker_MountDIR"
alias mirr="cd ~/mirror"


###############################
## default value is ctrl+r backward, ctrl+shift+r forward
## if current shell is interractive, add shortcut ctrl-s for forward-search
[[ $- == *i* ]] && stty -ixon

#### history merge after terminal exit
#export HISTCONTROL=ignoredups:ignorespace same to #export HISTCONTROL='ignoreboth'
#export HISTCONTROL='erasedups:ignorespace'
export HISTCONTROL='erasedups'
#history filter out
export HISTIGNORE='pwd:his*:popd'
# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
export HISTSIZE=500
export HISTFILESIZE=40000
export HISTTIMEFORMAT='[%Y-%m-%d_%H] '

#update history only login
#suppress update_history log
#export PROMPT_COMMAND="BASH_XTRACEFD=7; update_history 7>/dev/null; $PROMPT_COMMAND"
function update_history(){
    history -a
    if [ -n "${STY}" ] && [ "${path}" != "${PWD}" ] ; then  #mean [ ${TERM} = 'screen' ]
        [ "${PWD}" = "${HOME}" ] \
		&& printf "\033k%s\033\\" "HOME" \
		|| printf "\033k%s\033\\" "${PWD##*/}"
        path=${PWD}
    fi
    screen -X chdir "$PWD" &>/dev/null
    #history -c
} #redirect log to null#  &>/dev/null
#update_history 
export PROMPT_COMMAND="update_history; $PROMPT_COMMAND"
    
shopt -s cmdhist
shopt -s lithist

alias his='history 300| tail -60'
alias hisgrep='cat ~/.bash_history | egrep -i --color=auto'

###############################
#### screen alias

# screen configuration
# alias byobu='byobu -U $*'
alias sc$ECHO='printf "Usage
screen -U -c ${proFILEdir}/.screenrc -RR
screen -dR -c ${proFILEdir}/.screenrc
screen -ls | tail -n +2 | head -n -2 | awk {print $1} | xargs -I {} screen -S {} -X quit
screen -U -R -c ${proFILEdir}/.screenrc_spilt
"'

alias sc${TAG}='screen -ls'
alias sc="screen -U -RR -c ~/.proFILEs/.screenrc ~/.proFILEs/scw"
alias scr="screen -U -DR -c ~/.proFILEs/.screenrc ~/.proFILEs/scw"
alias scx='kill_screen'

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
#### utility
alias scp$ECHO='printf "Usage
scp -p <port> <user>@<src-ip>:<full-path-filename> .
scp filename -p <port> <user>@<dest-ip>:<full-path-dest-dir>/
docker cp <container-id>:<full-path-filename> .
docker cp <filename> <container-id>:<full-path-dest-dir>/
"'

alias ssh$ECHO='printf "Usage
ssh -p <port> <user>@<dest-ip>
scp ${USER}@$CURR_IP:${HOME}/filename .
"'
alias ssh${TAG}='_sshl(){ echo "usage: sshl [port]" ; ssh -J localhost vc.integrator@localhost -p "$1" -t screen -dR ;}; _sshl'

alias rsync$ECHO='printf "Usage
rsync -auvht --exclude-from=exclude.txt --port=873 172.21.74.32::$USER/SRC_DIR/* .
"'
alias repo$ECHO='printf "Usage
repo sync -qcj4 --no-tags --no-clone-bundle
"'

###############################
#### move
#alias moveup='mv * .[^.]* ..'
alias moveup='mv {.,}* .. > /dev/null'
alias findrm='__findrm'
function __findrm()
{
    if [ "$1" == "" ]; then echo [WARNING] plz input filename!!
    else find . -name "$1" -exec rm -rf \{\} \;
    fi
}

# combine mkdir & cd : below all space is essential!!!
alias cat${TAG}='_catl(){ cat -n "$1"| more ;}; _catl'
alias catl${TAG}='_catll(){ cat -nA "$1"| more ;}; _catll'
alias cdcd='_cdcd(){ mkdir -p "$1"; cd "$1" ;}; _cdcd'

#### find
alias du${TAG}='_dul(){ printf "usage: dul [dir]\n subdir $1 size is"; du -sh $1; du -sBM $1 ;}; _dul'
alias dus='_dus(){ printf "each directory size is\n"; du -hs */|sort -n ;}; _dus'
alias ps${TAG}='echo "usage: psl"; CMD ps -u $USER -o pid,ppid,args --forest'
alias pst='_pst(){ _bar  "usage: pst [$USER]"; CMD pstree -hapg -u ${1:-$USER} ;}; _pst'
alias kil='_kil(){ _bar "kill -SIGTERM -- -[PGID]"; kill -SIGTERM -- -$1 ;}; _kil'

alias ls='ls --color=auto'
alias lls='_bar size-base; ls -agohrS'
alias llt='_bar time-base; ls -agohrt'
alias lld='_lld(){ _bar "time-base dir-only"; ls -arthlp -d $1*/; }; _lld'
alias ll='_bar time-base all-file; ls -alrthF --color=auto --show-control-chars'
alias dir='ls -al -F --color=auto| grep /'
alias tree='tree  --charset ascii -L '
alias grep='grep --color=auto'
alias grep${TAG}='_grep(){ CMD grep --color=auto --exclude-dir={.git,.byobu,tempdir} -rn $@ ;}; _grep'
alias grepalias='alias | egrep -i --color=auto'
alias findrecent='_findrecent(){ find . -ctime -"$1" -a -type f | xargs ls -l ;}; _findrecent'

alias filegrep='__filegrep'
function __filegrep() {
    if [ -z "$1" ]; then
        echo "you should go topdir first !!"
        echo "cmd) rgrep --color --include="*file*" "string" ./;"
        echo "ex) filegrep *.txt string"
    fi
    rgrep --color --include="*$1*" "$2" ./;
}

alias findgrep='__findgrep'
function __findgrep() {
    if [ -z "$1" ]; then
        echo "you should go topdir first !!"
        echo "ex) findgrep .txt string"
    fi
    find . \( -name ".repo" -o -name ".git" \) -prune -o -name "*$1*" | xargs grep -rn --color "$2"
}

alias greppro='__greppro'
function __grepro() { find "$proFILEdir" -name "*" | xargs grep -rn --color "$1" ;}

# env variable & path control
alias env='env|sort'
alias pathshow='echo $PATH|sed "s/:/:\n/g"'
alias pathexport='echo $PATH|sed "s/:/:\n/g" > ~/path.export; echo "path saved to file: ~/path.export"'

function pathremove()
{
    local p d
    p=":$1:"
    d=":$PATH:"
    d=${d//$p/:}
    d=${d/#:/}
    PATH=${d/%:/}
    pathshow
}

# ~/bin is always applied, but ~/bin/temporary_path is applied when pathimport call
alias pathimport='__pathimport'
function __pathimport()
{
    if [ -f ~/path.export ];then PATH_FILE=$(cat ~/path.export|sed -z "s/\n//g");else PATH_FILE=$PATH; fi
    PATH=$1:$PATH_FILE
    pathshow
    echo
    echo "path is changed by path.export file"
}

alias gg="echo 'find path up&down <gg .git>'; go_updown"
function go_updown()
{
    echo "go parent dir << [$HOME] ---- ${PWD##*/} ---- [depth 8] >> "
    local HERE=$PWD
    local TOPFILE=${proFILEdir}
    local T=

    #in case not HOME or not ROOT, find path to upper dirs.
    while [[ "$PWD" != "$HOME" ]] && [[ "$PWD" != "/"  ]]; do
        T=$PWD
        if [ -d "$T/$1" ]; then
            cd $T
            tree -L 2 -d
            return
        fi
        cd ..
    done
    #not found in partents, now findout in child
    cd $HERE

    local INPUT
    INPUT=$(find $HERE -maxdepth 8 -type d -wholename "*$1" 2> /dev/null)
    if [ -n "$INPUT" ];then
        show_menu_do "$INPUT"
        cd "${RET%/*}"
        tree -L 2 -d
        return
    fi
    #not found, go back origin path
    #cd $HERE
}

alias ggn="go_near"
function go_near(){
    local INPUT
    #find sub dirtory
    # INPUT=$(find ./ -maxdepth 2 -type d -name "$1" 2> /dev/null)
    #find parents dirtory
    # INPUT="${INPUT} $(find ../../ -maxdepth 4 -type d -path ${PWD##*/} -prune -o -name "$1" 2> /dev/null)"
    INPUT="${INPUT} $(find ../../ -maxdepth 4 -type d -name "$1" 2> /dev/null)"
    #find grand parents dirtory
    show_menu_do "$INPUT"
    echo ${RET}
    cd ${RET}
}


###############################
#### encryption
## usage : code_temp|code_perm en|de password [filename]
function code_temp(){
   case $1 in
      en) export ENCODE=$( echo $2 | openssl enc -base64 -e -aes-256-cbc -nosalt -pbkdf2  -pass pass:garbageKey );;
      de) echo "${ENCODE}" | openssl enc -base64 -d -aes-256-cbc -nosalt -pbkdf2 -pass pass:garbageKey ;;
   esac
}

FILE_CODE=.user.code
function code_perm(){
   case $1 in
      en) echo $2 | openssl enc -base64 -e -aes-256-cbc -nosalt -pbkdf2  -pass pass:garbageKey > "${proFILEdir}/${FILE_CODE}.$3";;
      de) cat "${proFILEdir}/${FILE_CODE}.$2" | openssl enc -base64 -d -aes-256-cbc -nosalt -pbkdf2 -pass pass:garbageKey ;;
   esac
}


###############################
#### copy & paste http://sourceforge.net/projects/commandlinecopypaste/
# ex-copy: pwd | cc, ex-paste: cd $(cv)
#command line copy+paste dir
export CLCP_DIR="${proFILEdir}"

#command line clipboard file
export CLCF="${proFILEdir}/.path.log"
alias copy_cc="sh ${CLCP_DIR}/cc.sh"
alias coyp_cv="cat ${CLCF}"

#alias lll="launch_cur_dir | copy_cc; copy_cv"
alias lll="launch_cur_dir"
alias llf='_llf(){ read -p "input filename: " && launch_cur_dir $REPLY }; _llf'


###############################
#### vi startup option
alias vi$ECHO='printf "Usage
VIMINIT=:so ~/.vim/.vimrc MYVIMRC=~/.vim/.vimrc vim $*
VIMINIT=:so ~/.viu/.vimrc_backup MYVIMRC=~/.viu/.vimrc_backup vim $* -V9myLog
VIMINIT=:so ~/.viu/.vimrc MYVIMRC=~/.viu/.vimrc vim $*
VIMINIT=:so ~/.vio/.vimrc MYVIMRC=~/.vio/.vimrc vim $* -V9myLog
"'


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



##################################################################################
# load target specific
##################################################################################
USR_FILE=${proFILEdirOS}/.bashrc
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}" ;fi
USR_FILE=${proFILEdir}/user.bashrc
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}" ;fi

# load android & repo
##################################################################################
USR_FILE=${proFILEdir}/android/.androidrc
if [ -f "${USR_FILE}" ]; then source "${USR_FILE}" ;fi

# show banner when login in screen
##################################################################################
USR_FILE=${proFILEdir}/.banner
if [ -f "${USR_FILE}" ] && [ -z "$STY" ] && [ "$opt_banner" = "yes" ]
then source "${USR_FILE}"
fi
