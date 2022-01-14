#!/bin/bash
#DEBUG=[echo|:], : means no-operation
DEBUG=echo

################# manifest git handle
$DEBUG "##DEBUG [COMMAND:$GCOMMAND] [TARGET:$GTARGET] [RESULT:$RESULT] [NAME:$GNAME] [PATH:$GPATH] [REVISION:$GREVISION] [UPSTREAM:$GUPSTREAM]"
case $GCOMMAND in
remote-check-url)
    $DEBUG "#### check remote is valid"
    git remote show $CURR_REMOTE
    RESULT="A"
    ;; 
remote-check-branch)
    $DEBUG "#### check remote branch/tag info"
    git ls-remote
    RESULT=$?
    ;;
remote-delete-branch)
    $DEBUG "#### delete remote branch/tag info"
    pushd $GPATH                                &&\
    git remote show $CURR_REMOTE                &&\
    #git push origin --delete ${branch}         &&\
    popd
    RESULT=$?
    ;;
*)
    $DEBUG "[warning] there is unrecognized commands. plz check!!!"
    ;;
esac