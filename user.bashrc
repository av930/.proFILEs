# vim: set filetype=bash:
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
    spawn su - ${acc} -c \"LOGIN_IP=${IP_CURR} bash\"
    expect {
        \"Password: \" { send \"${pd}\r\" }
    }

    interact
    "
}

alias sul='_bar "auto su" ;func_su'
if (( 8 < $(grep \/docker /proc/1/cgroup 2>/dev/null |wc -l)  )); then
    eval $(cat ~/.bash_aliases | grep PS1SC)
    [ -n "${PS1SC}" ] && PS1="${PS1SC}"
fi
