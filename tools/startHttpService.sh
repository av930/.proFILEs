#!/bin/bash


## 현재 지정된 IP인 10.159.30.66에 한하여 wget을 허용하는 http 서버를 구동한다.
set -euo pipefail
ROOT_DIR="/data001/vc.integrator/.proFILEs"
PORT="8000"
HOST_IP="10.159.30.66" 
LOG_FILE="${ROOT_DIR}/http/startHttpService.log"

print_usage() {
    echo "Usage: $(basename "$0")"
    echo "This starts an unauthenticated HTTP server for ${ROOT_DIR} on port ${PORT}."
    echo "Example download command from another server: wget http://${HOST_IP}:${PORT}/http/startHttpService.sh"
}
is_target_host() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -Fxq "${HOST_IP}" ; }
is_service_running() { wget -qO- "http://127.0.0.1:${PORT}/http/startHttpService.sh" 2>/dev/null | grep -Fq "ROOT_DIR=\"${ROOT_DIR}\""; }
start_service() { cd "${ROOT_DIR}"; nohup python3 -m http.server "${PORT}" --bind 0.0.0.0 >"${LOG_FILE}" 2>&1 & ; } 


main() {
    if ! is_target_host; then exit 0;  fi
    if is_service_running; then exit 0; fi 
    
    print_usage
    start_service
}

main "$@"