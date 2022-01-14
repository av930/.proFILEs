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
DEBUG=echo #DEBUG=[echo|:], : means no-operation
SCRIPT_DIR=${BASH_SOURCE%/*}

FILE_LOG=debug.log
FILE_OUT=out.txt
FILE_CACHE=out.cache
FILE_REPO=out.repo.txt
FILE_GIT=out.git.txt
DIR_OUT=DIR_OUT
CURR_REMOTE=NA
CURR_BRANCH=NA
CURR_FILE_MANI=NA


##--------------------------- Settup Environments-----------------------------
##============================================================================
# determine whether arrays are zero-based (bash) or one-based (zsh)





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



function get_repoinit_cmd(){
## ---------------------------------------------------------------------------
    REMOTE=$(git remote -v |grep fetch |awk '{print $2}')
    BRANCH=$(git rev-parse --abbrev-ref --symbolic-full-name @{u}| sed 's:.*/::')
    FILE_TEMPA=$(ls -Art ../*.xml | tail -n 1)
    count=$(grep -c include $(ls -Art ../*.xml | tail -n 1))
    
    if [ -L "${FILE_TEMPA}" ];then 
        FILE_TEMPB=$(readlink "${FILE_TEMPA}")
        FILE_MANI=${FILE_TEMPB#*/}
    elif [ $count -eq 1 ]; then
        FILE_MANI=$(grep include $(ls -Art ../*.xml | tail -n 1)|sed -E 's/<.*name="(.*)".\/>/\1/')
    else
        FILE_MANI=default.xml
    fi
    CURR_REMOTE=$REMOTE; CURR_BRANCH=$BRANCH; CURR_FILE_MANI=$FILE_MANI
    echo "repo init -u $CURR_REMOTE -b $CURR_BRANCH -m $CURR_FILE_MANI"
    return 1
}





function handle_repo(){
## ---------------------------------------------------------------------------
    rm -f $1.tmp
    RNAME=(); RFETCH=(); RREVISION=(); RPUSHURL=();
    RET=0

    cat $1 | sed $'s/\r$//' | while IFS=$'\t' read -r -a col
    do
        case ${col[0]%% } in
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
        esac

        echo -e "${col[0]}\t${col[1]}\t${col[2]}\t${col[3]}\t${col[4]}\t${col[5]}\t${col[6]}" >> $1.tmp
    done

    ## output file
    $DEBUG; mv $1.tmp $1
    return $RET
}


function handle_git(){
## ---------------------------------------------------------------------------
    #cat $FILE_GIT | awk -f mani.handler.awk -v VAR2="${SHELL_VAR2}"
    #COMMAND($1) TARGET($2) RESULT($3) NAME($4) PATH($5) REVISION($6) UPSTREAM($7)
    #echo "awk -F'[\t]' -f ${SCRIPT_DIR}/mani_handler.awk $1"
    rm -f $1.tmp
    FLAG_FORALL=false
    RET=$2 #repeat

    cat $1 | sed $'s/\r$//' | while IFS=$'\t' read -r -a col
    do
        GCOMMAND=${col[0]%% }; GTARGET=${col[1]%% }; RESULT=${col[2]}; GNAME=${col[3]}; GPATH=${col[4]}; GREVISION=${col[5]}; GUPSTREAM=${col[6]};
        $DEBUG "##DEBUG [${col[@]}]"
        $DEBUG "##DEBUG [COMMAND:$GCOMMAND] [TARGET:$GTARGET] [RESULT:$RESULT] [NAME:$GNAME] [PATH:$GPATH] [REVISION:$GREVISION] [UPSTREAM:$GUPSTREAM]"
        if [ "$FORALL_FLAG" = "true" ];then GCOMMAND=$FORALL_CMD && GTARGET=$FORALL_TARGET; fi

        case $GCOMMAND in
        CMDLIST|COMMAND|"")
            $DEBUG "#### skip line $GCOMMAND"
            ;;
        FORALL)
            if [ "$GTARGET" != "noop" ]; then
                echo -e "#### this command is applied to all git [$GCOMMAND $GTARGET]"
                echo -e "#### original command will be ignored !!!"
                FORALL_FLAG=true; FORALL_CMD=$GTARGET; FORALL_TARGET=$RESULT
            fi
            ;;
        remote-check-url)
            $DEBUG "#### check remote is valid"
            git remote -v
            RESULT="A"
            ;;
        remote-check-branch)
            $DEBUG "#### check remote branch/tag info"
            git ls-remote
            RESULT=$?
            ;;
        remote-delete-branch)
            $DEBUG "#### delete remote branch/tag info"
            #git push origin --delete ${branch}
            git ls-remote
            RESULT=$?
            ;;
            
        esac

        #printf 구문에서는 \t 저장시 \t이 누락되는 error가 발생함, 또한 echo -e를 사용하지 않고 echo를 사용해도 \t들이 누락되는 현상 발생
        #printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$GCOMMAND" "$GTARGET" "$RESULT" "$GNAME" "$GPATH" "$GREVISION" "$GUPSTREAM" >> $1.tmp
        echo -e "$GCOMMAND\t$GTARGET\t$RESULT\t$GNAME\t$GPATH\t$GREVISION\t$GUPSTREAM" >> $1.tmp
    done #> $FILE_LOG

    let "RET--"
    ## output file
    $DEBUG; mv $1.tmp $1
    return $RET
}


function xml2reformat(){
## ---------------------------------------------------------------------------
    echo "reformat manifest.xml and generate as text file"
    echo "1. remove multi-blanks to one blank"
    echo "2. reformat input manifest and generate $FILE_OUT"
    ls -gohrt *.xml
    file_c=$( tail -n 1 $FILE_CACHE )
    read -p "please input manifest.xml or enter (use ${file_c}}: " file_input

    if [ "$file_input" = "" ]; then
        file_input=${file_c}
    else
        echo "$file_input" >> $FILE_CACHE
    fi


    ## make all blank to one, add ">" or "/>" as last column
    echo "[$file_input >>>> $FILE_OUT.tmp]"
    cat $file_input |  sed 's/[[:blank:]]\+/ /g' | sed -E 's/(.*")(\/|>)/\1 \2/' > $FILE_OUT.tmp
    $DEBUG  "cat $FILE_OUT.tmp | awk -f ${SCRIPT_DIR}/mani.reformat.awk > $FILE_OUT"
    cat $FILE_OUT.tmp | awk -f ${SCRIPT_DIR}/mani.reformat.awk > $FILE_OUT

    ##  make header to handle remote
    echo "[$FILE_OUT >>>> $FILE_REPO]"
    $DEBUG "cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani.repo.awk > $FILE_REPO"
    cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani.repo.awk | sed 's/[[:blank:]]\+$//g'| sed 's/"//g' > $FILE_REPO

    ##  make body to handle git
    echo "[$FILE_OUT >>>> $FILE_GIT]"
    $DEBUG "cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani.git.awk > $FILE_GIT"
    cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani.git.awk | sed 's/[[:blank:]]\+$//g'| sed 's/"//g' > $FILE_GIT

    ## add valid command in header of file
    echo -e "CMDLIST\tcheck-remote-url\tcheck-remote-branch" |cat - $FILE_GIT > $FILE_GIT.tmp
    mv $FILE_GIT.tmp $FILE_GIT
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
    select CHOICE in xml2reformat reformat2xml handle_all handle_git handle_repo get_repoinit
    do
        case $REPLY in
         1) xml2reformat;                                       break;;
         2) reformat2xml;                                       break;;
         3) echo "process command file: $FILE_GIT/$FILE_GIT generated"
            handle_repo $FILE_REPO
            handle_git $FILE_GIT 1
            if [[ $? -lt 1 ]]; then break;else continue; fi;         ;;
         4) handle_repo $FILE_REPO;                             break;;
         5) handle_git $FILE_GIT;                               break;;
         6) get_repoinit_cmd;                                   break;;
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

printf ${green}
cat << PREFACE
    choose [option:ex) -abs]
    ==============================================
    Show the menu for MANI.tool

    current settings
    ----------------------------------------------
        OPT_AVD_PATH=${OPT_AVD_PATH}
        OPT_SD_FILE=${OPT_SD_FILE}
    ----------------------------------------------
    param=a)vd create, e)mul, s)d-card
PREFACE
printf ${NCOL}

handler_args $@
