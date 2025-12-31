#!/bin/bash

# ==========================================================================
#  mail      : av9300@lge.com
#  readme    : all utils related with build
#
# ==========================================================================

# ==========================================================================
# ---------------------- EDIT HISTORY FOR MODULE
#
# This section contains comments describing changes made to the module.
# Notice that changes are listed in reverse chronological order.
#
# when         who             what, where, why
# ----------   -----------     ---------------------------------------------
# ==========================================================================


function calculate_size(){
## ---------------------------------------------------------------------------

    current_dir_size=$(du -s --block-size=M --exclude=*.iso $1|awk '{print $1}')
    echo -e "\n----------------- target disk size ----------------------"
    adb shell df      �ܾ������ ��/��							 w, e, b     #w�� word����, e�� ��, b�� �ڷ�
    current_sd_size=$(adb shell df ${2}|awk 'NR==2 {gsub(/G/,"*1024",$4);print $4}')
    declare -i dir_size=${current_dir_size%%M}
    declare -i sd_size=$[${current_sd_size%%M}]

    echo -e "\n---------------- source vs target (MB) -------------------"
    echo [SIZE: $1: $dir_size]
    echo [SIZE: $2: $sd_size]

    if [ ${sd_size} -lt ${dir_size} ];then
        echo [ERROR]source dir $1 size is bigger than dest dir,so cannot push all data!!
        exit 1
    fi
    return
}


function put_data(){
## ---------------------------------------------------------------------------
    SAVEIFS=$IFS
    IFS=$(echo -en "\n\b")
    Command="adb push"
    if ! [ "$3" == "" ];then Command="echo";fi
    find $1 -name "*" -type f >temp_win.txt
    iconv -f CP949 -t UTF-8 temp_win.txt >temp_linux.txt
    for x in $(cat temp_linux.txt); do
        adb push "${x}" "${2}/${x#$1/}"
    done
    IFS=$SAVEIFS
    return
}



function put_data2(){
## ---------------------------------------------------------------------------
#work properly but need to debug adb push(copy) operation about encoding, may be unicode for win32 copy
    Command="adb push"
    if ! [ "$3" == "" ];then Command="echo";fi

	find $1 -print0 | while read -d $'' file
    do
    	adb push "${file}" "${2}/${file#$1/}"
    done
    return
}


############## MAIN #############
# Take arguements
    from_LocalDir=$1
    to_SdDir=${2:-/sdcard}


## ---------------------------------------------------------------------------
cat << PREFACE
    format : push_data.sh from_LocalDir to_SdDir [option]
    example: push_data.sh ./tempdata    /sdcard

    current setting is
    ==============================================
    from_LocalDir   = $from_LocalDir [must be defined!]
    to_SdDir        = $to_SdDir [default:/sdcard]
PREFACE


## ---------------------------------------------------------------------------
    if [ "${from_LocalDir}" == "" ];then
        echo please put dir path that you want to push!
        exit
    fi

    isconnect=$(adb get-serialno)

    if [ "${isconnect:0:7}" == "unknown" ]; then
        echo please check device connection by using "adb devices" command!
        echo only one device should be connected now.
        exit 1
    fi

    calculate_size $from_LocalDir $to_SdDir
    put_data2 $from_LocalDir $to_SdDir $3




