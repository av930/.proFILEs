#!/bin/bash

# ==========================================================================
#  readme    : manifest handling
#  mail      : joongkeun.kim@lge.com/av9300@gmail.com
# ==========================================================================

# ==========================================================================
# ---------------------- EDIT HISTORY FOR MODULE
#
# This section contains comments describing changes made to the module.
# Notice that changes are listed in reverse chronological order.
#
# when         who             what, where, why
# ----------   -----------     ---------------------------------------------
# 2011/12/02   joongkeun.kim   Initial release.
# ==========================================================================
##--------------------------- Uset Setting-----------------------------
##============================================================================
# Setting by User

FILE_OUT=out.txt
FILE_WORK=out_work.txt


CUR_DIR=${BASH_SOURCE%/*}

##--------------------------- Settup Environments-----------------------------
##============================================================================
# determine whether arrays are zero-based (bash) or one-based (zsh)
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
--------------------      WELCOME TO Manifest Control     ------------------
============================================================================
PREFACE
printf ${NCOL}

OS_TYPE='unknown'
if [ $(expr match "$OSTYPE" 'cygwin') -ne 0 ]; then OS_TYPE='windows'
elif [ $(expr match "$OSTYPE" 'linux') -ne 0 ]; then OS_TYPE='linux'
elif [ $(expr match "$OSTYPE" 'freebsd') -ne 0 ]; then OS_TYPE='bsd'
elif [ $(expr match "$OSTYPE" 'darwin') -ne 0 ]; then OS_TYPE='mac'
fi

##--------------------------- Build Functions --------------------------------
##============================================================================

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
            pathname=${lines[$(($choice-$_arrayoffset))]}
        done
    else
        # even though zsh arrays are 1-based, $foo[0] is an alias for $foo[1]
        pathname=${lines[0]}
    fi
     RET=$pathname
     return 0
 }



function run_ddms(){
## ---------------------------------------------------------------------------
	echo run ddms.bat
    ddms${BAT}&
    return 1
}


function create_avd(){
## ---------------------------------------------------------------------------

if [ "${OS_TYPE}" == "windows" ];then 
    echo ${SRC_SDK}/"AVD Manager.exe"&
    ${SRC_SDK}/"AVD Manager.exe"&
else 
    android &
fi
    return 1
}


function create_sd(){
## ---------------------------------------------------------------------------
	echo all SD card List
    if [ "${OS_TYPE}" == "windows" ];then 
        SDCARD_PATH=$(cygpath -wp ${SRC_SDK}/../AVD/${SD_NAME}.iso)
    else 
        SDCARD_PATH=$(~/${SD_NAME}.iso)
    fi
	ls -hs  ${SDCARD_PATH}

	read -p "put a sdcard size ex(16M or 2G): " SD_SIZE
    read -p "put a sdcard name ex(SD36M): " SD_NAME

    echo  "mksdcard ${SD_SIZE} ${SDCARD_PATH}"
    mksdcard ${SD_SIZE} ${SDCARD_PATH}
    return 1
}


function update_sdk(){
## ---------------------------------------------------------------------------
    echo ${SRC_SDK}/"SDK Manager.exe"&
    android
    return 1
}


function handle_git(){
## ---------------------------------------------------------------------------
    #cat $FILE_WORK | awk -f mani.handler.awk -v VAR2="${SHELL_VAR2}" 
    # COMMAND($1) TARGET($2) RESULT($3) NAME($4) PATH($5) REVISION($6) UPSTREAM($7)

    awk -F'[\t]' -f mani.handler.awk $FILE_WORK
    #awk -F'[\t]' '/^COMMAND/,NR<FNR { if ($1=="check-git-url") git ls-remote  }' $FILE_WORK

    return 1
}


function xml2reformat(){
## ---------------------------------------------------------------------------
    echo "reformat manifest.xml and generate as text file"
    echo "1. remove multi-blanks to one blank"
    echo "2. reformat input manifest and generate $FILE_OUT"
    ls -gohrt *.xml
    read -p "please input manifest.xml to reformat: " file_input
    echo "$file_input >>>> $FILE_OUT"
    cat $file_input |  sed 's/[[:blank:]]\+/ /g' | sed -E 's/(.*")(\/|>)/\1 \2/' > $FILE_OUT.tmp
    echo  "cat $FILE_OUT.tmp | awk -f ${CUR_DIR}/mani_reformat.awk > $FILE_OUT"
    cat $FILE_OUT.tmp | awk -f ${CUR_DIR}/mani_reformat.awk > $FILE_OUT
    echo "$FILE_OUT >>>> $FILE_WORK"
    echo "cat $FILE_OUT | awk -f ${CUR_DIR}/mani_commander.awk > $FILE_WORK"
    cat $FILE_OUT | awk -f ${CUR_DIR}/mani_commander.awk > $FILE_WORK
    ## rm -f $FILE_OUT.tmp >/dev/null    
    if [ -f $FILE_OUT ]; then echo "[$file_input] >>>> [$FILE_OUT] "; fi
    return 1
}


function reformat2xml(){
## ---------------------------------------------------------------------------
    file_output=out.xml
    echo "generate out file from $FILE_OUT"
    echo "1. remove multi-blanks(tap) to one"
    if [ -f $FILE_OUT ]; then cat $FILE_OUT | sed "s/\t\+/ /g" > $file_output ; fi
    echo "make manifest file [$file_output] from $FILE_OUT"
    return 1
}

##--------------------------- Menu Functions --------------------------------
##============================================================================
function handler_args(){
## ---------------------------------------------------------------------------
# Hander Arguments

    local ret
    local options
    while getopts es: options 2> /dev/null
    do
       case $options in
          e) run_emul; ret=processed;;
          d) run_ddms; ret=processed;;
          \?) printf "${RED}Only -a,-e,-s are valid [$options] ${NCOL}\n"
            handler_menu
            ret=processed;;
       esac
    done

    if ! [ "$ret" = "processed" ]; then
        handler_menu
    fi

    unset OPTIND
    unset OPTSTRING
}


function handler_menu(){
## ---------------------------------------------------------------------------
    printf "${YELLOW}========== What do you Want? ========== ${NCOL}\n"
    local COLUMNS=20
    PS3="=== PLZ Command! === : "
    select CHOICE in xml2reformat reformat2xml handle_git create_sd update_sdk logcat_filter log_filter
    do
        case $REPLY in
         1) xml2reformat;           break;;
         2) reformat2xml;           break;;
         3) handle_git;             break;;
         4) create_sd;              break;;
         5) update_sdk;             break;;
         6) logcat_filter;          break;;
		 7) log_filter;             break;;
         *) return 0;
        esac
    done
}


##============================================================================
## Main
##============================================================================



## ---------------------------------------------------------------------------
# Print Preface
## ---------------------------------------------------------------------------

printf ${GREEN}
cat << PREFACE
    choose [option:ex) -abs]
    ==============================================
    Show the menu for MANI.tool

    current settings
    ----------------------------------------------
	    SRC_SDK=${SRC_SDK}
	    OPT_AVD_PATH=${OPT_AVD_PATH}
	    OPT_SD_FILE=${OPT_SD_FILE}
    ----------------------------------------------
    param=a)vd create, e)mul, s)d-card
PREFACE
printf ${NCOL}

handler_args $@
