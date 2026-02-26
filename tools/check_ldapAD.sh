#!/bin/bash
#------------------------------------------------------------------------------
# AD LDAP 인증 테스트 및 계정 정보 디코딩 스크립트
# Usage: ./check_ldapAD.sh <username> <password>
#------------------------------------------------------------------------------
#한줄명령
#LDAPTLS_REQCERT=never ldapsearch -x -H "ldaps://lgesaads01.lge.net:636" -D "AD_ACCOUNT" -w 'AD_PW' -b "OU=LGE Users,dc=LGE,dc=NET" -s sub "(mail=AD_EMAIL@lge.com)"

# set -exEo pipefail 환경(Jenkins 등)에서 source 될 때 안전하게 동작하도록 처리
# -e: 에러시 즉시 종료, -E: ERR trap 함수/서브쉘 전파, -o pipefail: 파이프 내 실패 전파
_LDAP_SAVED_OPTS=$(set +o); set +eE; set +o pipefail 2>/dev/null

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' D='\033[2m' N='\033[0m'

AD_SERVER="${AD_SERVER:-ldaps://lge.net}"
AD_BASE_DN="${AD_BASE_DN:-ou=LGE Users,dc=lge,dc=net}"
AD_DOMAIN="${AD_DOMAIN:-lge.com}"

# NT타임스탬프(100ns/1601기준) → 날짜
nt2date() {
    local v="$1"
    [[ -z "$v" || "$v" == "N/A" ]] && echo "N/A" && return
    [[ "$v" == "0" ]] && echo "설정 안됨 (Never Set)" && return
    [[ "$v" == "9223372036854775807" ]] && echo "만료 없음 (Never)" && return
    local ts=$(echo "$v/10000000-11644473600" | bc 2>/dev/null || python3 -c "print($v//10000000-11644473600)" 2>/dev/null)
    [[ -z "$ts" || "$ts" -le 0 ]] 2>/dev/null && echo "$v (변환불가)" && return
    date -d "@$ts" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$v (변환불가)"
}

# whenCreated(YYYYMMDDHHMMSS.0Z) → 날짜
when2date() {
    local v="$1"; [[ -z "$v" || "$v" == "N/A" ]] && echo "N/A" && return
    echo "${v:0:4}-${v:4:2}-${v:6:2} ${v:8:2}:${v:10:2}:${v:12:2} UTC"
}

# userAccountControl 비트마스크 디코딩
decode_uac() {
    local v=$1 f=()
    [[ -z "$v" || "$v" == "N/A" ]] && echo "N/A" && return
    local -A bits=([0x0002]=ACCOUNTDISABLE [0x0010]=LOCKOUT [0x0020]=PASSWD_NOTREQD
        [0x0040]=PASSWD_CANT_CHANGE [0x0200]=NORMAL_ACCOUNT [0x2000]=SERVER_TRUST_ACCOUNT
        [0x10000]=DONT_EXPIRE_PASSWD [0x40000]=SMARTCARD_REQUIRED
        [0x80000]=TRUSTED_FOR_DELEGATION [0x800000]=PASSWORD_EXPIRED)
    for bit in "${!bits[@]}"; do (( v & bit )) && f+=("${bits[$bit]}"); done
    echo "${f[*]}"
}

# DN → 부서경로 (OU 역순)
dn2path() { echo "$1" | grep -oP 'OU=[^,]+' | sed 's/^OU=//' | tac | paste -sd ' → '; }

# LDAP속성 추출 (Base64 자동 디코딩)
ga() {
    local f="$1" a="$2" v
    v=$(grep -i "^${a}: " "$f" | head -1 | sed "s/^${a}: *//I")
    [[ -z "$v" ]] && v=$(grep -i "^${a}:: " "$f" | head -1 | sed "s/^${a}:: *//I" | base64 -d 2>/dev/null)
    echo "${v:-N/A}"
}

kv() { printf "  ${B}%-22s${N} %s\n" "$1:" "$2"; }
sec() { echo ""; echo -e "${C}${B}━━━ $1 ━━━${N}"; }

# 의존성 체크
command -v ldapsearch &>/dev/null || { echo -e "${R}✗ ldapsearch 없음. apt install ldap-utils${N}"; exit 1; }

echo -e "${C}${B}╔══════════════════════════════════════════╗${N}"
echo -e "${C}${B}║     AD LDAP 인증 테스트 & 계정 정보      ║${N}"
echo -e "${C}${B}╚══════════════════════════════════════════╝${N}"
echo -e "  ${D}AD Server: $AD_SERVER | Base DN: $AD_BASE_DN${N}"

[[ -z "$1" || -z "$2" ]] && echo -e "\n${Y}Usage: $0 <login_user> <password> [target_user]${N}\n  target_user 미지정시 login_user 자신을 조회" && exit 1

USERNAME="$1"; PASSWORD="$2"; TARGET="${3:-$1}"
echo -e "\n${Y}⏳ 인증: ${USERNAME} → 조회: ${TARGET}${N}"

TF=/tmp/.check_ldapAD_$$.tmp; rm -f /tmp/.check_ldapAD_*.tmp 2>/dev/null
ATTRS="cn mail displayName memberOf sAMAccountName userPrincipalName distinguishedName \
department title telephoneNumber company description userAccountControl pwdLastSet \
accountExpires lastLogon lastLogonTimestamp whenCreated whenChanged DepartmentCode \
uSNCreated lockoutTime employeeNumber physicalDeliveryOfficeName"
FILTER="(|(sAMAccountName=$TARGET)(mail=${TARGET}@${AD_DOMAIN})(userPrincipalName=${TARGET}@${AD_DOMAIN}))"


# set -e 환경에서도 안전하게 exit code 캡처 (ERR trap 방지)
EXIT_CODE=0
set -x
LDAPTLS_REQCERT=never timeout 5 ldapsearch -x -o nettimeout=3 -H "$AD_SERVER" -D "${USERNAME}@${AD_DOMAIN}" \
        -w "$PASSWORD" -b "$AD_BASE_DN" "$FILTER" $ATTRS > "$TF" 2>&1 || EXIT_CODE=$?
set +x

if [[ $EXIT_CODE -eq 124 ]]; then
    echo -e "${R}✗ 타임아웃${N}"; rm -f "$TF"; exit 124
fi

# 결과 출력
if [[ $EXIT_CODE -eq 0 ]] && ! grep -qi "invalid credentials\|bind failed" "$TF"; then
    echo -e "${G}✔ 인증 성공!${N}"

    if grep -q "dn:" "$TF"; then
        sec "기본 정보"
        v_dn=$(ga "$TF" dn)
        kv "sAMAccountName" "$(ga "$TF" sAMAccountName)"
        kv "Display Name" "$(ga "$TF" displayName)"
        kv "Email" "$(ga "$TF" mail)"
        kv "UserPrincipalName" "$(ga "$TF" userPrincipalName)"
        kv "Phone" "$(ga "$TF" telephoneNumber)"
        kv "Employee Number" "$(ga "$TF" employeeNumber)"
        v=$(ga "$TF" company);           [[ "$v" != "N/A" ]] && kv "Company" "$v"
        v=$(ga "$TF" physicalDeliveryOfficeName); [[ "$v" != "N/A" ]] && kv "Office" "$v"
        v=$(ga "$TF" description);        [[ "$v" != "N/A" ]] && kv "Description" "$v"

        sec "조직 정보"
        kv "Department" "$(ga "$TF" department)"
        kv "DepartmentCode" "$(ga "$TF" DepartmentCode)"
        kv "Title" "$(ga "$TF" title)"
        kv "uSNCreated" "$(ga "$TF" uSNCreated)"
        kv "부서 경로 (DN)" "$(dn2path "$v_dn")"

        sec "계정 상태"
        v_uac=$(ga "$TF" userAccountControl)
        if [[ "$v_uac" != "N/A" ]]; then
            kv "userAccountControl" "$v_uac → [$(decode_uac "$v_uac")]"
            (( v_uac & 0x0002 )) && echo -e "  ${R}${B}⚠ 계정: 비활성화 (DISABLED)${N}" \
                                 || echo -e "  ${G}${B}✔ 계정: 활성 (ENABLED)${N}"
            (( v_uac & 0x10000 ))  && echo -e "  ${D}  ⤷ 비밀번호 만료 없음${N}"
            (( v_uac & 0x800000 )) && echo -e "  ${Y}  ⤷ 비밀번호 만료됨${N}"
        fi
        v_lock=$(ga "$TF" lockoutTime)
        [[ "$v_lock" != "N/A" && "$v_lock" != "0" ]] && echo -e "  ${R}${B}🔒 계정 잠김: $(nt2date "$v_lock")${N}"

        sec "시간 정보"
        kv "계정 생성일" "$(when2date "$(ga "$TF" whenCreated)")"
        kv "마지막 변경" "$(when2date "$(ga "$TF" whenChanged)")"
        kv "비밀번호 변경일" "$(nt2date "$(ga "$TF" pwdLastSet)")"
        kv "계정 만료일" "$(nt2date "$(ga "$TF" accountExpires)")"
        v_lts=$(ga "$TF" lastLogonTimestamp); v_lo=$(ga "$TF" lastLogon)
        [[ "$v_lts" != "N/A" && "$v_lts" != "0" ]] && kv "마지막 로그인" "$(nt2date "$v_lts")" \
        || { [[ "$v_lo" != "N/A" && "$v_lo" != "0" ]] && kv "마지막 로그인" "$(nt2date "$v_lo")" || kv "마지막 로그인" "N/A"; }

        sec "그룹 멤버십"
        groups=()
        while IFS= read -r l; do
            g=$(echo "$l" | grep -oP '^CN=[^,]+' | sed 's/^CN=//'); groups+=("${g:-$l}")
        done < <(grep "^memberOf: " "$TF" | sed 's/^memberOf: //')
        while IFS= read -r l; do
            d=$(echo "$l" | base64 -d 2>/dev/null)
            g=$(echo "$d" | grep -oP '^CN=[^,]+' | sed 's/^CN=//'); groups+=("${g:-$d}")
        done < <(grep "^memberOf:: " "$TF" | sed 's/^memberOf:: //')

        total=${#groups[@]}
        if (( total > 0 )); then
            echo -e "  ${D}총 ${total}개 그룹${N}"
            max=0; for g in "${groups[@]}"; do l=$(echo -n "$g"|wc -m); ((l>max)) && max=$l; done
            col=0; for g in "${groups[@]}"; do
                ((col==0)) && printf "    "
                printf "• %-${max}s  " "$g"
                ((++col>=3)) && printf "\n" && col=0
            done; ((col>0)) && printf "\n"
        else echo "  (그룹 없음)"; fi

        sec "DN (Distinguished Name)"
        echo -e "  ${D}$v_dn${N}"
    else
        echo -e "${R}✗ 대상 계정 '${TARGET}'을(를) AD에서 찾을 수 없습니다.${N}"
        echo -e "  ${D}(로그인 인증은 성공했으나 조회 대상이 존재하지 않음)${N}"
        RETRUN_MSG="FAIL 계정 '${TARGET}'을(를) 찾을 수 없습니다."
        EXIT_CODE=32
    fi
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo -e "\n${G}${B}═══ AD 계정 비밀번호가 유효합니다. ═══${N}"
        RETRUN_MSG="OKAY 유효한 사용자입니다."
    fi
else
    echo -e "${R}✗ 인증 실패 (Exit Code: $EXIT_CODE)${N}\n"
    ERR=$(cat "$TF")
    RETRUN_MSG="FAIL 인증이 실패했습니다."
    echo "$ERR" | grep -i "error\|invalid\|fail" || echo "$ERR" | tail -3
    echo -e -n "\n${Y}원인:${N} "
    case $EXIT_CODE in
        49) RETRUN_MSG="${R}Invalid Credentials - 잘못된 비밀번호/사용자명/계정잠김${N}";;
        32) RETRUN_MSG="${R}No Such Object - Base DN 오류${N}";;
        52) RETRUN_MSG="${R}Unavailable - AD 서버 응답 없음${N}";;
        53) RETRUN_MSG="${R}Server Unwilling - 비밀번호 만료/AD정책 위반${N}";;
         8) RETRUN_MSG="${R}LDAP Error - 보안연결(LDAPS) 필요 또는 프로토콜 오류${N}";;
         1) RETRUN_MSG="${R}Operations Error - 쿼리 구문/서버 내부 오류${N}";;
        -1) RETRUN_MSG="${R}Can't Contact Server - 서버 연결 실패${N}";;
         *) RETRUN_MSG="${R}Unknown Error (code=$EXIT_CODE)${N}";;
    esac

fi

echo -e "$RETRUN_MSG"
# 원래 shell 옵션 복원
eval "$_LDAP_SAVED_OPTS" 2>/dev/null
exit $EXIT_CODE
