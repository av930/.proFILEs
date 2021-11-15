printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"

func_ssh(){
    if [ "$1" == "" ];then account=vc.integrator;else account=$1; fi
    echo account is [$account]

    expect -c "

    spawn su - ${account}
    #set send_human {.1 .3 1 .05 2}

    expect {
        \"Password: \" { send \"!devops12\r\" }
    }

    interact
    "
}

alias sul="func_ssh vc.integrator"
