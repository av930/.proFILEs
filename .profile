printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"
if [ "$profile_sourced" = "true" ]; then echo "already sourced" >/dev/null; fi
(return 0 2>/dev/null) && export profile_sourced=true || export profile_sourced=false

############################## COMMON .profile#####################################
# common configuration
##################################################################
# LANG & Color
##################################################################
#과거 사용하던 version
#LANG=C.euckr
#LANG=en_US.UTF-8
#LANG=ko_KR.euckr

## 현재 검증된 version
# default is POSIX
# case 구문에 의해 순서대로 적용됨.
case $(locale -a) in
    *C.UTF-8*) LC_ALL=C.UTF-8 ;;
    *ko_KR*)   LC_ALL=ko_KR.UTF-8 ;;
esac

##### color code
red='\e[0;31m';     RED='\e[1;31m';     green='\e[0;32m';       GREEN='\e[1;32m';
yellow='\e[0;33m';  YELLOW='\e[1;33m';  blue='\e[0;34m';        BLUE='\e[1;34m';
cyan='\e[0;36m';    CYAN='\e[1;36m';    magenta='\e[0;35m';     brown='\e[0;33m';
NCOL='\e[0m';



USR_FILE=~/user.profile
if [ -f "${USR_FILE}" ]
then source "${USR_FILE}"
else source ${proFILEdir}/user.profile
fi

line="--------------------------------------------------------------------------------------"
_bar() { printf "\n${YELLOW}%s%s ${NCOL}\n" "${1:+[$1] }" "${line:(${1:+2}+${#1})}" ;}

# get_ip=192.168.0.1
##################################################################
CURR_IP=172.0.0.1
function get_ip(){
readarray -t a <<<"$(hostname -I) $SSH_CONNECTION"
  for ip in ${a[@]}; do
    max=$(grep -o $ip <<< ${a[*]} | wc -l)
    if [ $max -eq 2 ] ;then CURR_IP=$ip && echo $ip && break; fi
  done
#return $ip
}


CURR_IP=$(get_ip)
# user specific setting
TMOUT=100000 #86400 is 24 hours
export proFILEdir proFILEdirOS LC_ALL CURR_IP get_ip TMOUT
export red RED green GREEN yellow YELLOW blue BLUE cyan CYAN magenta brown NCOL


# specific profile
# check linux or cygwin and load profile
##################################################################
if [ -f "${proFILEdirOS}/.profile" ]; then source "${proFILEdirOS}/.profile" ;fi

# common configuration
# .bashrc
##################################################################
# source the users bashrc if it exists
#printf '[%s] runned: [%s:%s] sourced\n' "$0" "${proFILEdir}/.bashrc" "$LINENO"
#if [ -f "${proFILEdir}/.bashrc" ]; then source "${proFILEdir}/.bashrc"; fi


# common configuration
# default path
#Set PATH so it includes user's private bin if it exists
##################################################################
#PATH=".:${HOME}:${proFILEdir}/tools:${HOME}/bin:${PATH}"
PATH=".:${proFILEdir}/tools:${proFILEdir}/bin/prio_high:${proFILEdir}/bin:${PATH}"


# launch default shell emulator
# screen or byobu (default is screen)
##################################################################
if [[ ${SHLVL} -eq 1 && -x $(which screen) ]]; then
    #((SHLVL+=1)); export SHLVL
    #exec screen -R -e "^Ee" ${SHELL} -l
    #start screen if not using cygwin
    if [ "${BASH_SOURCE%/*}" != "$HOME" ]; then return ; fi
    if [ "$OSTYPE" != "cygwin" ] && [ "$opt_screen" = "yes" ]; then screen -U -R; fi
fi
