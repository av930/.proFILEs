#!/bin/bash

# ==========================================================================
#  mail      : joongkeun.kim@lge.com
#  readme    : all utils related with build
#
#  Copyright (c) 2010 by OASIS.  All Rights Reserved.
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


if [ "${OS_TYPE}" == "windows" ];then 
    BAT=.bat
    EXE=.exe
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



function run_emul(){
## ---------------------------------------------------------------------------
# launch emulator

    printf ${GREEN}
    PS3="which binary is :"
    select start_dir in $(cat ~/android.list) exit
    do
        printf "$start_dir\n"
        break
    done
    printf ${NCOL}

    GOLDFISH=${start_dir}/kernel_goldfish/zImage
    IMG_DIR=out/target/product
    if ! [ -d $IMG_DIR ]; then
        IMG_DIR=${start_dir}/${IMG_DIR}
    fi


    local INPUT
    INPUT=$(find ${IMG_DIR}/ -maxdepth 2  -name "system.img" |sort)
    show_menu_do "$INPUT"
    echo $RET

    android${BAT} list avd 
    read -p "input AVD Name: " -e -i I15W INPUT_AVD

    DEF_OPT="-no-boot-anim -nojni -debug-init"
    echo "ex) -qemu -s, -no-cache, -sdcard filename, -ramdisk filename"
    echo "ex) -wipe-data, -debug all,-qemud,-sensors, "
    echo "ex) -logcat '*:v' -show-kernel -qemu -monitor telnet::4444,server -s"
	echo "ex) -logcat [v|d|i|w|e|s]"

    echo "ex) -partition-size 256, for adb remount"
    read -p "input extra Option: " -e -i "$DEF_OPT " INPUT_OPT
    
    set -x
    emulator @${INPUT_AVD} -kernel ${GOLDFISH} -system ${RET} -data ${RET%/*}/userdata.img -ramdisk ${RET%/*}/ramdisk.img $INPUT_OPT&
    #emulator @${INPUT_AVD} -system ${RET} -data ${RET%/*}/userdata.img -ramdisk ${RET%/*}/ramdisk.img $INPUT_OPT&
    #(echo stop; cat -) | telnet localhost 4444 > /dev/tty &
    set +x
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


function logcat_filter(){
## ---------------------------------------------------------------------------
    ${DEVTOOLS}/_LogFilter/LogcatFilter.exe
    return 1
}


function log_filter(){
## ---------------------------------------------------------------------------
	echo java -jar $(cygpath -wp ${DEVTOOLS}/_LogFilter/LogFilter.jar)&
    java -jar $(cygpath -wp ${DEVTOOLS}/_LogFilter/LogFilter.jar)&
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
    select CHOICE in run_emul run_ddms create_avd create_sd update_sdk logcat_filter log_filter
    do
        case $REPLY in
         1) run_emul;         break;;
         2) run_ddms;         break;;
         3) create_avd;       break;;
         4) create_sd;        break;;
         5) update_sdk;       break;;
         6) logcat_filter;       break;;
		 7) log_filter;       break;;
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
    Show the menu for android SDK

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
