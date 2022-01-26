printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"

func_su(){
    if [ "$1" == "first" ];then pd=!devops12;else pd=!dlatl00; fi
    acc=vc.integrator
    echo account is [$acc]

    expect -c "
    #spawn su -s \"${proFILEdir}/func_su.sh\" - ${acc}
    #spawn su - ${acc}
    spawn su - ${acc} -c \"LOGIN_IP=${CURR_IP} bash\"
    expect {
        \"Password: \" { send \"${pd}\r\" }
    }

    interact
    "
}

alias sul="func_su first"
alias sull="func_su"
