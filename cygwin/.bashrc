#------------------------------ cygwin -----------------------------------------
# The absolute path must be eliminated within this file
# 이 파일에는 절대 path가 없어야 합니다.
############################## Prompt DEFINE #####################################


############################### Tool ALIAS #####################################
function launch_cur_dir()
{
    echo $(cygpath -wp $PWD)
}

alias xming='export DISPLAY=localhost:0.0'
alias ${TAG}term='rxvt -rv -sr -sw -sl 9999 -fg black -bg white -fn "Lucida Sans Typewriter" -mcc -ls -g 100X50 -e /usr/bin/bash --login -i &'

#gvim start option
alias  gvi="VIMINIT=':so ~/.vim/.vimrc' MYVIMRC='~/.vim/.vimrc' /cygdrive/c/DevTools/gVim/vim74/gvim.exe $* &"
alias gvip="VIMINIT=':so ~/.vim/.vimrc_backup' MYVIMRC='~/.vim/.vimrc_backup' /cygdrive/c/DevTools/gVim/vim74/gvim.exe $* &"
alias gviu="VIMINIT=':so ~/.viu/.vimrc' MYVIMRC='~/.viu/.vimrc' /cygdrive/c/DevTools/gVim/vim74/gvim.exe $* &"


alias lsync='echo rsync -auvht --port=873 172.21.74.32::$USER/SRC_DIR/*  /cygdrive/d/DEST_DIR'
alias lsyne='echo rsync -auvht --exclude-from=exclude.txt --port=873 172.21.74.32::$USER/SRC_DIR/* /cygdrive/d/DEST_DIR'

#GDB debugging
function setup-gdb()
{
    adb devices
    echo "only 1 device: enter, more than 1: -e or -d"
    read choice
    adb $choice forward tcp:5039 tcp:5039
    adb $choice shell ps
    echo -n "Which process? with & for background:"
    read process_id
    adb $choice shell gdbserver :5039 --attach $process_id &
}

function start-gdb()
{
    if [ "$1" == "" ]; then
        echo [WARNING] "you must run envsetup.sh \& lunch before gdb"
        echo [WARNING] current PRODUCT_OUT is $(get_build_var PRODUCT_OUT)
        echo [WARNING] plz input \$PRODUCT_OUT/symbols/system/xxx
        echo \$1 should be symbol file, \$2 optionally could be remote ip
        return
    fi

    # should be ndk gdb for windows
    if [ "${OSTYPE}" == "cygwin" ]; then
        local GDB=/cygdrive/d/SDK/Android/android-ndk-r8b/toolchains/arm-linux-androideabi-4.6/prebuilt/windows/bin/arm-linux-androideabi-gdb.exe
    else
        local GDB=prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.6/bin/arm-linux-androideabi-gdb
        export PATH=$PATH:~/out/host/linux-x86/bin/adb
    fi

    # should be product dir
    local OUT_SYMBOLS=$(expr match "$1" '\(.*symbols\)')
    local OUT_SO_SYMBOLS=$OUT_SYMBOLS/system/lib



    echo >|"gdbclient.cmds" "set solib-absolute-prefix $OUT_SYMBOLS"
    echo >>"gdbclient.cmds" "set solib-search-path $OUT_SO_SYMBOLS:$OUT_SO_SYMBOLS/hw:$OUT_SO_SYMBOLS/ssl/engines"
    echo >>"gdbclient.cmds" "target remote $2:5039"
    echo >>"gdbclient.cmds" ""

    cat "gdbclient.cmds"
    echo "cgdb -d $GDB -x gdbclient.cmds $1"
    cgdb -d $GDB -x "gdbclient.cmds" $1

}    


############################### ENV DEFINE ######################################
alias setsdk='set-android-sdk'
function set-android-sdk(){
    export PATH=${SRC_SDK}/platform-tools:${SRC_SDK}/tools:$PATH;
    export ANDROID_PRODUCT_OUT=${SRC_FULL}/out/target/product/generic
    export USE_CYGWIN=1 #refer HOST_windows-x86.mk for cygwin building 

}


############################### Utility #####################################

printf '[%s] runned: [%s] sourced\n' "$0" "$BASH_SOURCE"
