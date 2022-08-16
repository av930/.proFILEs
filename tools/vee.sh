echo #### input value
AD_ID=${AD_ID=vc.integrator}
PROJECT=${PROJECT=honda-tsu-25-5my}
WORKER=${WORKER=honda-25-5my}
CMD_1stBEE=${CMD_1stBEE=$1}
CMD_2ndBEE=${CMD_2ndBEE=$2}
CMD_3rdBEE=${CMD_3rdBEE="testaccount"}

echo #### default value
PATH=.:$PATH
CMD_TEMP=cmd_vbee

## get vbee client
echo ###########################################################################
wget -q http://cart.lge.com/bee-deploy/bee-cli/vbee/latest/vbee -o $CMD_TEMP && chmod +x $CMD_TEMP
$CMD_TEMP --help
echo ###########################################################################

## login to vbee
$CMD_TEMP login -u ${AD_ID} -p  ${AD_PW}
$CMD_TEMP worker run honda-25-5my > /dev/null


## parameter pre-processing
A_PARAM=$(IFS=: ; echo "${CMD_3rdBEE[@]}")
## action
case ${CMD_1stBEE} in
    worker)
        case ${CMD_2ndBEE} in
            list)    $CMD_TEMP worker list                  ;;
            run)     $CMD_TEMP worker run "${WORKER}"       ;;
            *) echo invalid; exit 1;;
        esac;;
    member)
        case ${CMD_2ndBEE} in
            add) echo "printf "%s\n" ${A_PARAM[@]} | xargs -I{} -t -n1 $CMD_TEMP project add-member --role 10 ${PROJECT} {}" ;;
            list) echo $CMD_TEMP project list-member ${PROJECT} | grep -nEe "( ${A_PARAM[@]/%/|} )";;
            *) echo invalid; exit 1;;
        esac;;
    *) echo there is no matched commands; exit 1;;
esac
echo "echo $CMD_TEMP project list-member ${PROJECT} | grep -nEe \( ${A_PARAM[@]/%/|} \)"

## back to original status
rm -f $CMD_TEMP
