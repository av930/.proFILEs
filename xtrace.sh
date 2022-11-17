#!/bin/bash
: ' #guide
https://github.com/mug896/bash-stepping-xtrace

# Example 1 : shell script trace

$ xtrace.sh ./twolines.sh "linux" data.txt
put line __trace_ON__ at start of debugging line in twoline.sh
put line __trace_OFF__  at end of debugging line
enter: step over, ctrl+c: exit


# Example 2 : shell function trace

$ f1() { __trace_ON__; echo $1; date; echo $2 ;}
$ export -f f1
$ xtrace.sh f1 111 222
'

################################################
#                                              #
#   This is for /bin/bash scripts              #
#   You can't use this with /bin/sh scripts.   #
#                                              #
################################################

trap 'exec 2> /dev/null
    rm -f $pipe
    kill $print_pid
    kill -- -$target_pid'   EXIT

pipe=/tmp/pipe_$$
mkfifo $pipe

#####  Check usage

if [ ${#@} -eq 0 ]; then
    echo
    echo Usage: "$(basename $0)" bash_script arg1 arg2 ...
    echo
    exit 1
else
    target_command=$1
    shift
fi


#####  Trace functions

__trap_debug__() {
    set -o monitor
    suspend -f
    set +o monitor 
}

__trace_ON__() {
    echo --------- trace ON -----------
    set -o xtrace -o functrace 
    trap __trap_debug__ DEBUG
}
__trace_OFF__() {
    trap - DEBUG
    set +o xtrace +o functrace 
    echo --------- trace OFF -----------
}

export -f __trace_ON__ __trace_OFF__ __trap_debug__


#####  Prompt for xtrace

export PS4='+\[\e[0;32m\]:\[\e[0;49;95m\]${LINENO}\[\e[0;32m\]:${FUNCNAME[0]:+${FUNCNAME[0]}(): }\[\e[0m\]'


#####  Read from pipe and print xtrace

while read -r line; do
    case $line in
        *__trace_OFF__* )  continue ;;
        *__trap_debug__* )  continue ;;
    esac
    echo "$line" >&2
done < $pipe &

print_pid=$!


#####  Excute target command

# disable suspend
set -o monitor

# enable tracing for shell functions
bash -c "$target_command"' "$0" "$@"' "$@" &> $pipe & 

target_pid=$!


#####  Trace !

while read line; do  
    if kill -0 $target_pid 2> /dev/null; then
        fg %% > /dev/null
        sleep 0; echo -e "\e[0;34mDONE\e[0m"
    else
        exit
    fi
done 
