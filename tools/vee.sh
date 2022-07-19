#!/bin/bash

echo "[$1] [$2] [${@:3}]"
PATH=.:$PATH
CMD_BEE=temp_vbee
AD_ID=${AD_ID=vc.integrator}
PROJECT=honda-tsu-25-5my
WORKER=honda-25-5my


## get vbee client
wget -q http://cart.lge.com/bee-deploy/bee-cli/vbee/latest/vbee -o $CMD_BEE && chmod +x $CMD_BEE


## login to vbee
$CMD_BEE login -u ${AD_ID} -p  ${AD_PW}
$CMD_BEE worker run honda-25-5my > /dev/null


## action
case $1 in
    worker)
        case $2 in
            list)    $CMD_BEE worker list                  ;;
            run)     $CMD_BEE worker run "${WORKER}"       ;;
            *) echo invalid; exit 1;;
        esac;;
    member)
        case $2 in
            add)  echo ${@:3} | xargs -t -o -n1 $CMD_BEE project add-member --role 10 ${PROJECT}  ;;
            *) echo invalid; exit 1;;
        esac;;
    *) echo goodbye; exit 1;;
esac


## back to original status
rm -f $CMD_BEE
