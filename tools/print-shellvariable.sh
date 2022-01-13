#!/bin/bash

# ==========================================================================
#  mail      : joongkeun.kim@lge.com
#  readme    : all utils related with build
#
#  Copyright (c) 2010 by OASIS.  All Rights Reserved.
# ==========================================================================

_xarray=(a b c)
if [ -z "${_xarray[${#_xarray[@]}]}" ]
then
    _arrayoffset=1
else
    _arrayoffset=0
fi
unset _xarray


printf ${CYAN}
cat << PREFACE
============================================================================
---------------------------           +             ------------------------
-----------------------                                ---------------------
--------------------    WELCOME TO OASIS BUILD SYSTEM    ------------------
============================================================================
PREFACE
printf ${NCOL}

OS_TYPE='unknown'
if [ $(expr match "$OSTYPE" 'cygwin') -ne 0 ]; then OS_TYPE='windows'
elif [ $(expr match "$OSTYPE" 'linux') -ne 0 ]; then OS_TYPE='linux'
elif [ $(expr match "$OSTYPE" 'freebsd') -ne 0 ]; then OS_TYPE='bsd'
elif [ $(expr match "$OSTYPE" 'darwin') -ne 0 ]; then OS_TYPE='mac'
fi

echo "current dir path" $(dirname $0)
echo "current file path" "${0%/*}"
echo "BASE_SOURCE" "${BASH_SOURCE%/*}"
echo "BASH" $BASH
echo "HISTFILE" $HISTFILE
echo "HOME" $HOME
echo "IFS" $IFS
echo "LANG" $LANG
echo "LC_ALL" $LC_ALL
echo "MACHTYPE" $MACHTYPE
echo "OLDPWD" $OLDPWD
echo "OSTYPE" $OSTYPE
echo "PATH" $PATH
echo "PPID" $PPID
echo "PS1" $PS1, $PS2, $PS3, $PS4
echo "PWD" $PWD
echo "RANDOM" $RANDOM
echo "REPLY" $REPLY
echo "SHELL" $SHELL
echo "BASH_SOURCE" $BASH_SOURCE

