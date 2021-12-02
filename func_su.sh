#!/bin/sh
LOGIN_IP=$1
LOGIN_MODE=SU
export LOGIN_IP LOGIN_MODE
#echo ${LOGIN_IP},${CURR_IP},${USER}

exec /bin/bash --rcfile /data001/joongkeun.kim/.profile "$@"
