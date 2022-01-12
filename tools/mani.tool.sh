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

DEBUG=echo #DEBUG=[echo|:], : means no-operation
FILE_LOG=debug.log
FILE_OUT=out.txt
FILE_CACHE=out.cache
FILE_WORK=out_work.txt
DIR_OUT=DIR_OUT



SCRIPT_DIR=${BASH_SOURCE%/*}

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




function handle_git(){
## ---------------------------------------------------------------------------
    #cat $FILE_WORK | awk -f mani.handler.awk -v VAR2="${SHELL_VAR2}"
    # COMMAND($1) TARGET($2) RESULT($3) NAME($4) PATH($5) REVISION($6) UPSTREAM($7)
    #echo "awk -F'[\t]' -f ${SCRIPT_DIR}/mani_handler.awk $FILE_WORK"
    rm -f $FILE_LOG $FILE_WORK.tmp
    RNAME=(); RFETCH=(); RREVISION=(); RPUSHURL=();

    cat $FILE_WORK | sed $'s/\r$//' | while IFS=$'\t' read -r -a col
    do
        GCOMMAND=${col[0]}; GTARGET=${col[1]}; RET=${col[2]}; GNAME=${col[3]}; GPATH=${col[4]}; GREVISION=${col[5]}; GUPSTREAM=${col[6]}; 
        $DEBUG "##DEBUG [${col[@]}]"
        $DEBUG "##DEBUG [COMMAND:$GCOMMAND] [TARGET:$GTARGET] [RET:$RET] [NAME:$GNAME] [PATH:$GPATH] [REVISION:$GREVISION] [UPSTREAM:$GUPSTREAM]"
        
        case $GCOMMAND in
        CMDLIST|COMMAND|"")
            $DEBUG "#### skip line $GCOMMAND"
            ;;
        register-remote)
            $DEBUG "#### read remote info     [NAME FETCH REVISION PUSHURL]"
            RNAME+=($GNAME); RFETCH+=($GPATH); RREVISION+=($GREVISION); RPUSHURL+=($GUPSTREAM);
            ;;
        select-default)
            $DEBUG "#### read default setting [REMOTE DEST-branch REVISION UPSTREAM]"
            DREMOTE=$GNAME; DDESTBRANCH=$GPATH; DREVISION=$GREVISION; DUPSTREAM=$GUPSTREAM;
            ;;
        check-remote-url)
            $DEBUG "#### check remote is valid"
            git remote -v
            RET="A"
            ;;
        check-remote-branch)
            $DEBUG "#### check remote branch/tag info"
            git ls-remote
            RET=$?
            ;;
        esac
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$GCOMMAND" "$GTARGET" "$RET" "$GNAME" "$GPATH" "$GREVISION" "$GUPSTREAM" >> $FILE_WORK.tmp
    done #> $FILE_LOG

    ## output file
    mv $FILE_WORK.tmp $FILE_WORK
    return 1
}


function xml2reformat(){
## ---------------------------------------------------------------------------
    echo "reformat manifest.xml and generate as text file"
    echo "1. remove multi-blanks to one blank"
    echo "2. reformat input manifest and generate $FILE_OUT"
    ls -gohrt *.xml
    read -p "please input manifest.xml or enter (use lastfile): " file_input

    if [ "$file_input" = "" ]; then
        file_input=$( tail -n 1 $FILE_CACHE )
    else
        echo $file_input >> $FILE_CACHE
    fi


    ## make all blank to one, add ">" or "/>" as last column
    echo "[$file_input >>>> $FILE_OUT.tmp]"
    cat $file_input |  sed 's/[[:blank:]]\+/ /g' | sed -E 's/(.*")(\/|>)/\1 \2/' > $FILE_OUT.tmp

    ## reorder manifest elements and generate reformatted out file
    echo  "cat $FILE_OUT.tmp | awk -f ${SCRIPT_DIR}/mani_reformat.awk > $FILE_OUT"
    cat $FILE_OUT.tmp | awk -f ${SCRIPT_DIR}/mani_reformat.awk > $FILE_OUT

    ##  make brief commander file to handle manifest.xml
    echo "[$FILE_OUT >>>> $FILE_WORK]"
    echo "cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani_commander.awk > $FILE_WORK"
    cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani_commander.awk | sed 's/"//g'  > $FILE_WORK
    
    ## add valid command in header of file
    echo -e "CMDLIST\tregister-remote\tselect-default\tcheck-remote-url\tcheck-remote-branch" \
        |cat - $FILE_WORK > $FILE_WORK.tmp
    mv $FILE_WORK.tmp $FILE_WORK
    rm -f $FILE_OUT.tmp >/dev/null
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
