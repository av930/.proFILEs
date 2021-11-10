printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"

alias sul="func_ssh vc.integrator"
func_ssh(){
    expect -c "
    spawn su - $1
    set send_human {.1 .3 1 .05 2}

    expect {
        \"Password: \" { send -h \"!devops12\r\" }
    }
    expect eof
    "
}

