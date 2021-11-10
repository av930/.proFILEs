printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"
############################## USER DEFINE ################################

DEVTOOLS=/cygdrive/d/.gradle/OneDrive/_MyProgram
SETTING=/cygdrive/d/.gradle/OneDrive/_MySetting

SRC_WORK=/cygdrive/d/.gradle/SRC_WORK
SRC_SDK=$DEVTOOLS/_Android/android-sdk-windows
SRC_FULL=$(cygpath -wp ${SRC_WORK}/nativeAOSP)

ASTYLE=$DEVTOOLS/_Gnutool/astyle/bin
CGDB=$DEVTOOLS/_Gnutool/cgdb/cgdb

CLASSPATH_L=.:$JAVA_HOME/lib/tools.jar
CLASSPATH=`cygpath -wp $CLASSPATH_L` 
#INDENT_PROFILE=$HOME/.indent.pro
GNUPLOT=$DEVTOOLS/_Shell/_Gnutool/gnuplot/bin

#VIM specific setting
#export VIMRUNTIME=/usr/share/vim/vim73
#export VIMINIT=":so /cygdrive/d/code_study/vimrc/vim_NObundle_NOcommandt/.vimrc"
#export VIMINIT=":so /cygdrive/d/code_study/tool/.unite/.vimrc"

export SRC_SDK SETTING CGDB ANT_HOME SRC_WORK DEVTOOLS CLASSPATH SOLAR JAVA_HOME

#PATH=$ASTYLE:$PATH:$GNUPLOT