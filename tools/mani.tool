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
#DEBUG=["echo -e"|:], : means no-operation
DEBUG=:

SCRIPT_DIR=${BASH_SOURCE%/*}

FILE_LOG=debug.log
FILE_OUT=out.txt
FILE_CACHE=out.cache
FILE_REPO=out.repo.csv
FILE_GIT=out.git.txt
DIR_OUT=DIR_OUT
CURR_REMOTE=NA
CURR_BRANCH=NA
CURR_FILE_MANI=NA
CURR_REPO_URL=NA
CURR_REFERENCE=NA


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


function move_parentdir(){
## ---------------------------------------------------------------------------
## move parent directory of input dir
   TOPFILE=.repo/manifests
   HERE=$PWD
   T=
   while [[ !( -d $TOPFILE ) && ( $PWD != "/" ) ]]; do
       T=$PWD
       if [ -d "$T/$@" ]; then
           cd $T/$@
           break
       fi
       cd ..
   done
}



function get_repoinit_cmd(){
## ---------------------------------------------------------------------------
    get_current_repo
    
    if [ "$CURR_REFERENCE" != "" ];then 
        EXTRA_OPTION="--reference $CURR_REFERENCE"; 
    fi
    echo "repo init -u $CURR_REMOTE -b $CURR_BRANCH -m $CURR_FILE_MANI" --repo-url $CURR_REPO_URL $EXTRA_OPTION
}


function get_current_repo(){
## ---------------------------------------------------------------------------
    pushd $(git rev-parse --show-toplevel) >/dev/null
    
    REMOTE=$(git remote -v |grep fetch |awk '{print $2}')
    BRANCH=$(git rev-parse --abbrev-ref --symbolic-full-name @{u}| sed 's:.*/::')
    REPO_URL=$(cat ../repo/.git/config |grep url|sed 's/.*=\(.*\)/\1/')
    REFERENCE=$(cat ../manifests.git/config |grep reference|sed 's/.*=\(.*\)/\1/')
    
    FILE_TEMPA=$(ls -Art ../*.xml | tail -n 1)
    count=$(grep -c include ${FILE_TEMPA})
    
    if [ -L "${FILE_TEMPA}" ];then 
        FILE_TEMPB=$(readlink "${FILE_TEMPA}")
        FILE_MANI=${FILE_TEMPB#*/}
    elif [ $count -eq 1 ]; then
        FILE_MANI=$(grep include $FILE_TEMPA |sed -E 's/<.*name="(.*)".\/>/\1/')
    else
        FILE_MANI=default.xml
    fi
    CURR_REMOTE=$REMOTE; CURR_BRANCH=$BRANCH; CURR_FILE_MANI=$FILE_MANI; CURR_REPO_URL=$REPO_URL; CURR_REFERENCE=$REFERENCE
    #echo "repo init -u $CURR_REMOTE -b $CURR_BRANCH -m $CURR_FILE_MANI" --repo-url $CURR_REPO_URL --reference $CURR_REFERENCE
    
    popd >/dev/null
    return 1
}



function handle_manifest(){
## ---------------------------------------------------------------------------
    get_repoinit_cmd
    handle_repo $1
}


function handle_repo(){
## ---------------------------------------------------------------------------
    #cat $FILE_GIT | awk -f mani.handler.awk -v VAR2="${SHELL_VAR2}"
    #COMMAND($1) TARGET($2) PARAM($3) NAME($4) PATH($5) REVISION($6) UPSTREAM($7)
    #echo "awk -F'[\t]' -f ${SCRIPT_DIR}/mani_handler.awk $1"
    rm -f $1.tmp
    RNAME=(); RFETCH=(); RREVISION=(); RPUSHURL=();
    FLAG_FORALL=false
    RET=$2 #repeat

    cat $1 | sed $'s/\r$//' | while IFS=$',' read -r -a col
    do
        GCOMMAND=${col[0]%% }; GTARGET=${col[1]%% }; GPARAM=${col[2]}; GNAME=${col[3]}; GPATH=${col[4]}; GREVISION=${col[5]}; GUPSTREAM=${col[6]};
        #$DEBUG "## [${col[@]}]"
        $DEBUG "## [COMMAND:$GCOMMAND] [TARGET:$GTARGET] [PARAM:$GPARAM] [NAME:$GNAME] [PATH:$GPATH] [REVISION:$GREVISION] [UPSTREAM:$GUPSTREAM]"
        if [ "$FORALL_FLAG" = "true" ];then GCOMMAND=$FORALL_CMD && GTARGET=$FORALL_TARGET; fi

        ################# manifest git handle
        case $GCOMMAND in
        \#*|"")
            #$DEBUG "#### skip comment"
            continue
            ;;
        register-remote)
            $DEBUG "#### read remote info     [NAME FETCH REVISION PUSHURL]"
            RNAME+=($GNAME); RFETCH+=($GPATH); RREVISION+=($GREVISION); RPUSHURL+=($GUPSTREAM);
            continue
            ;;
        select-default)
            $DEBUG "#### read default setting [REMOTE DEST-branch REVISION UPSTREAM]"
            DREMOTE=$GNAME; DDESTBRANCH=$GPATH; DREVISION=$GREVISION; DUPSTREAM=$GUPSTREAM;
            continue
            ;;
        FORALL)
            if [ "$GTARGET" != "noop" ]; then
                echo -e "#### this command is applied to all git [$GCOMMAND $GTARGET]"
                echo -e "#### original command will be ignored !!!"
                FORALL_FLAG=true; FORALL_CMD=$GTARGET; FORALL_TARGET=$GPARAM
            fi
            continue
            ;;
        esac
        
        #CURR_REMOTE=${CURR_REMOTE} CURR_BRANCH=${CURR_BRANCH} CURR_FILE_MANI=${CURR_FILE_MANI} \
        #GCOMMAND=${col[0]%% } GTARGET=${col[1]%% } GPARAM=${col[2]} GNAME=${col[3]} GPATH=${col[4]} GREVISION=${col[5]} GUPSTREAM=${col[6]} ${SCRIPT_DIR}/command_git.sh
        source command_git.sh
    done #> $FILE_LOG

    let "RET--"
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
    #echo "[$FILE_OUT >>>> $FILE_GIT]"
    #$DEBUG "cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani.git.awk > $FILE_GIT"
    #cat $FILE_OUT | awk -f ${SCRIPT_DIR}/mani.git.awk | sed 's/[[:blank:]]\+$//g'| sed 's/"//g' > $FILE_GIT


    ## add valid command in header of file
    #echo -e "CMDLIST,check-remote-url,tcheck-remote-branch" |cat - $FILE_GIT > $FILE_GIT.tmp
    echo -e "#CMDLIST,remote-check-url,remote-check-branch,remote-delete-branch" |cat - $FILE_REPO > $FILE_REPO.tmp
    mv $FILE_REPO.tmp $FILE_REPO
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
    select CHOICE in xml2reformat reformat2xml handle_manifest handle_git handle_repo get_repoinit movedir
    do
        case $REPLY in
         1) xml2reformat;                                       break;;
         2) reformat2xml;                                       break;;
         3) handle_manifest $FILE_REPO;                             break;;
         4) handle_repo $FILE_REPO;                             break;;
         5) handle_git $FILE_GIT;                               break;;
         6) get_repoinit_cmd;                                   break;;
         7) movedir .repo;                                   break;;
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
