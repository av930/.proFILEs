printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"

func_su(){
    if [ "$1" == "" ];then account=vc.integrator;else account=$1; fi
    echo account is [$account]

    expect -c "
    #spawn su -s \"${proFILEdir}/func_su.sh\" - ${account}
    spawn su - ${account}
    expect {
        \"Password: \" { send \"!devops12\r\" }
    }

    interact
    "
}

alias sul="func_su"
if [ "$USER" == "vc.integrator" ]; then
    echo "login as [$USER]"
fi
