printf '[%s] called: [%s:%s] sourced\n' "$0" "$BASH_SOURCE" "$LINENO"
############################## USER DEFINE ################################

SRC_SDK=$HOME/bin/android-sdk-linux:$HOME/bin/android-sdk-linux/platform-tools
APP_SDK=$HOME/APPSDK/buildapp
CGDB=$HOME/cgdb/cgdb
export SRC_SDK LGANT CGDB


PATH=$PATH:$SRC_SDK:$APP_SDK:$CGDB

