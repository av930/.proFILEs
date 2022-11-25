printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"

func_su(){
    acc=vc.integrator
    echo account is [$acc]

    case $1 in
       1) pd=$(code_perm de .vc.int1) ;;
       2) pd=$(code_perm de .vc.int2) ;;
       3) pd=$(code_perm de .vc.int3) ;;
    esac
    echo $pd

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

alias sul="func_su"
