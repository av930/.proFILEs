printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"
# below code should be called from ~/.bashrc
# usually called from .bash_aliases

if [ -f "${proFILEdir}/.bashrc" ]; then source "${proFILEdir}/.bashrc"; fi


#gen_alias.sh is automatically generated everytime login windows by windows format
#USERPROFILE path sometimes has a space and special chars
if [ $(expr match "$OSTYPE" 'cygwin') -ne 0 ]; then
    dos2unix $(cygpath -p ${USERPROFILE}/gen_alias.sh) >/dev/null 2>&1
    source $(cygpath -p ${USERPROFILE}/gen_alias.sh)
fi

# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return
