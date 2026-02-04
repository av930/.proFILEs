#!/bin/bash

# Yocto Build Cache Usage Checker
# This script checks if Yocto build is using premirror and/or sstate-cache
# Usage: ./check_PMnSC.sh [PM|SC] [BUILD_DIR] [MIRROR_DIR]
#   PM  - Check Premirror only
#   SC  - Check Sstate-cache only
#   (empty) - Check both

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse mode parameter
MODE="${1:-BOTH}"
if [[ "$MODE" =~ ^(PM|SC|BOTH)$ ]]; then
    shift
else
    MODE="BOTH"
fi

# Configuration
BUILD_DIR="${1}"
MIRROR_BASE="${2:-/data001/vc.integrator/mirror/tsu_30my_release}"

# Auto-detect build directory if not provided
if [ -z "$BUILD_DIR" ]; then
    echo -e "${BLUE}Auto-detecting build directory...${NC}"
    # Try to find build directory with tmp-glibc
    for base_dir in /data001/vc.integrator/Docker_MountDIR/build_dev/__DEV_HONDA30__*; do
        if [ -d "$base_dir" ]; then
            BUILD_CANDIDATE=$(find "$base_dir" -name "tmp-glibc" -type d 2>/dev/null | head -1)
            if [ -n "$BUILD_CANDIDATE" ]; then
                BUILD_DIR=$(dirname "$BUILD_CANDIDATE")
                echo -e "${GREEN}Found build directory: $BUILD_DIR${NC}"
                break
            fi
        fi
    done

    # If still not found, use default
    if [ -z "$BUILD_DIR" ]; then
        BUILD_DIR="/data001/vc.integrator/Docker_MountDIR/build_dev/__DEV_HONDA30__v2291/nad/sa525m/SA525M_apps/apps_proc/build-qti-distro-tele-debug"
    fi
fi

echo "========================================"
echo "Yocto Build Cache Usage Checker"
echo "========================================"
echo -e "${CYAN}Mode: $MODE${NC}"
echo -e "${BLUE}Build Directory:${NC} $BUILD_DIR"
echo -e "${BLUE}Mirror Base:${NC} $MIRROR_BASE"
echo ""

# Check if build directory exists
if [ ! -d "$BUILD_DIR" ]; then
    echo -e "${RED}Error: Build directory not found!${NC}"
    exit 1
fi

# Set paths
PREMIRROR_DIR="$MIRROR_BASE/premirror"
SSTATE_DIR="$MIRROR_BASE/sstate-cache"

# Alternative locations
if [ ! -d "$PREMIRROR_DIR" ]; then
    PREMIRROR_DIR="$MIRROR_BASE/src_mirror"
fi

# Common function to check directory existence
check_directory() {
    local DIR="$1"
    local NAME="$2"

    if [ -d "$DIR" ]; then
        echo -e "${GREEN}✓ $NAME directory found: $DIR${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ $NAME directory not found: $DIR${NC}"
        return 1
    fi
}

# Common function to check configuration in conf files
check_config_variable() {
    local CONF_FILE="$1"
    local VAR_NAME="$2"
    local EXPECTED_PATH="$3"
    local CONF_TYPE="$4"

    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}✗ $CONF_TYPE not found${NC}"
        return 1
    fi

    echo -e "${BLUE}Checking $CONF_TYPE:${NC}"
    local VAR_CONFIG=$(grep -E "^${VAR_NAME}" "$CONF_FILE" | grep -v "^#" || echo "")

    if [ -n "$VAR_CONFIG" ]; then
        echo -e "${GREEN}✓ Found $VAR_NAME in $CONF_TYPE:${NC}"
        echo "$VAR_CONFIG"

        # Check if it points to correct directory
        if echo "$VAR_CONFIG" | grep -q "$EXPECTED_PATH"; then
            echo -e "${GREEN}✓ $VAR_NAME is configured with expected path${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠ $VAR_NAME exists but may not point to expected directory${NC}"
            return 2
        fi
    else
        echo -e "${YELLOW}⚠ No $VAR_NAME found in $CONF_TYPE${NC}"
        return 1
    fi
}

# Common function to get file count and show samples
show_directory_info() {
    local DIR="$1"
    local NAME="$2"

    echo -e "${BLUE}Checking $NAME directory permissions:${NC}"
    if [ -r "$DIR" ]; then
        echo -e "${GREEN}✓ $NAME directory is readable${NC}"

        local FILE_COUNT=$(find "$DIR" -type f 2>/dev/null | wc -l)
        echo -e "${BLUE}Files in $NAME:${NC} $FILE_COUNT"

        if [ $FILE_COUNT -gt 0 ]; then
            echo -e "${BLUE}Sample files (first 5):${NC}"
            ls -lh "$DIR" | head -6
        fi
        return 0
    else
        echo -e "${RED}✗ $NAME directory is not readable${NC}"
        return 1
    fi
}

# Function to check premirror usage
check_premirror() {
    echo ""
    echo "========================================"
    echo "PREMIRROR CHECK"
    echo "========================================"

    check_directory "$PREMIRROR_DIR" "Premirror"

    echo ""
    echo "----------------------------------------"
    echo "1. Checking PREMIRRORS Configuration"
    echo "----------------------------------------"

    LOCAL_CONF="$BUILD_DIR/conf/local.conf"
    SITE_CONF="$BUILD_DIR/../poky/meta-qti-bsp/conf/site.conf"

    check_config_variable "$LOCAL_CONF" "PREMIRRORS" "$PREMIRROR_DIR" "local.conf"
    PM_LOCAL_STATUS=$?

    echo ""

    if [ -f "$SITE_CONF" ]; then
        echo -e "${BLUE}Checking site.conf:${NC}"
        PREMIRRORS_SITE=$(grep "PREMIRRORS" "$SITE_CONF" | grep -v "^#" || echo "")
        if [ -n "$PREMIRRORS_SITE" ]; then
            echo -e "${GREEN}✓ Found PREMIRRORS in site.conf:${NC}"
            echo "$PREMIRRORS_SITE" | head -5
            echo ""

            # Check priority (+= vs ?=)
            if echo "$PREMIRRORS_SITE" | grep -q "+="; then
                echo -e "${YELLOW}⚠ site.conf uses += (immediate append) - higher priority${NC}"
            fi
        fi
    fi

    echo ""
    echo "----------------------------------------"
    echo "2. Checking Recent Fetch Logs"
    echo "----------------------------------------"

    check_fetch_logs "$PREMIRROR_DIR" "premirror"

    echo ""
    echo "----------------------------------------"
    echo "3. Testing Premirror Access"
    echo "----------------------------------------"

    show_directory_info "$PREMIRROR_DIR" "premirror"

    return $PM_LOCAL_STATUS
}

# Function to check sstate-cache usage
check_sstate() {
    echo ""
    echo "========================================"
    echo "SSTATE-CACHE CHECK"
    echo "========================================"

    check_directory "$SSTATE_DIR" "Sstate-cache"

    echo ""
    echo "----------------------------------------"
    echo "1. Checking SSTATE Configuration"
    echo "----------------------------------------"

    LOCAL_CONF="$BUILD_DIR/conf/local.conf"

    # Check SSTATE_DIR
    check_config_variable "$LOCAL_CONF" "SSTATE_DIR" "$SSTATE_DIR" "local.conf"
    SS_DIR_STATUS=$?

    echo ""

    # Check SSTATE_MIRRORS
    if [ -f "$LOCAL_CONF" ]; then
        echo -e "${BLUE}Checking SSTATE_MIRRORS:${NC}"
        SSTATE_MIRRORS=$(grep -E "^SSTATE_MIRRORS" "$LOCAL_CONF" | grep -v "^#" || echo "")
        if [ -n "$SSTATE_MIRRORS" ]; then
            echo -e "${GREEN}✓ Found SSTATE_MIRRORS in local.conf:${NC}"
            echo "$SSTATE_MIRRORS"
        else
            echo -e "${YELLOW}⚠ No SSTATE_MIRRORS found in local.conf${NC}"
        fi
    fi

    echo ""
    echo "----------------------------------------"
    echo "2. Checking Recent Sstate Logs"
    echo "----------------------------------------"

    check_sstate_logs "$SSTATE_DIR"

    echo ""
    echo "----------------------------------------"
    echo "3. Testing Sstate-cache Access"
    echo "----------------------------------------"

    show_directory_info "$SSTATE_DIR" "sstate-cache"

    return $SS_DIR_STATUS
}

# Common function to check fetch logs
check_fetch_logs() {
    local MIRROR_DIR="$1"
    local MIRROR_NAME="$2"

    WORK_DIR="$BUILD_DIR/tmp-glibc/work"
    if [ ! -d "$WORK_DIR" ]; then
        echo -e "${RED}✗ Work directory not found${NC}"
        return 1
    fi

    # Find recent fetch logs
    echo -e "${BLUE}Searching for recent fetch logs...${NC}"
    local FETCH_LOGS=$(find "$WORK_DIR" -name "log.do_fetch*" -type f -mtime -1 2>/dev/null | head -10)

    if [ -z "$FETCH_LOGS" ]; then
        echo -e "${YELLOW}⚠ No recent fetch logs found (last 24 hours)${NC}"
        echo -e "${BLUE}Searching for any fetch logs...${NC}"
        FETCH_LOGS=$(find "$WORK_DIR" -name "log.do_fetch*" -type f 2>/dev/null | head -10)
    fi

    if [ -z "$FETCH_LOGS" ]; then
        echo -e "${RED}✗ No fetch logs found${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Found fetch logs${NC}"
    echo ""

    local MIRROR_USED=0
    local MIRROR_FAILED=0
    local UPSTREAM_USED=0

    for log in $FETCH_LOGS; do
        PKG_NAME=$(echo "$log" | grep -oP '(?<=work/).*?(?=/temp/)' | tail -1)

        # Check if premirror was tried
        if grep -q "Trying PREMIRRORS" "$log" 2>/dev/null; then
            if grep -q "file://" "$log" 2>/dev/null; then
                if grep -q "DEBUG: Fetching file://$MIRROR_DIR\|file:///.*${MIRROR_NAME}" "$log" 2>/dev/null; then
                    MIRROR_USED=$((MIRROR_USED + 1))
                    echo -e "${GREEN}✓ $PKG_NAME: Tried local $MIRROR_NAME${NC}"
                else
                    # Check for other file:// URLs
                    FILE_URL=$(grep "DEBUG: Fetching file://" "$log" 2>/dev/null | head -1)
                    if [ -n "$FILE_URL" ]; then
                        echo -e "${YELLOW}⚠ $PKG_NAME: Tried file:// but different path${NC}"
                        echo "  $FILE_URL"
                    fi
                fi
            else
                MIRROR_FAILED=$((MIRROR_FAILED + 1))
                echo -e "${YELLOW}⚠ $PKG_NAME: Tried PREMIRRORS but no local file:// access${NC}"
            fi
        fi

        # Check if upstream was used
        if grep -q "Trying Upstream" "$log" 2>/dev/null; then
            UPSTREAM_USED=$((UPSTREAM_USED + 1))
        fi
    done

    echo ""
    echo -e "${BLUE}Summary of last fetches:${NC}"
    echo -e "  ${MIRROR_NAME} (local file://) used: ${GREEN}$MIRROR_USED${NC}"
    echo -e "  ${MIRROR_NAME} tried but no local access: ${YELLOW}$MIRROR_FAILED${NC}"
    echo -e "  Upstream used: ${YELLOW}$UPSTREAM_USED${NC}"

    # Export for diagnosis
    export MIRROR_USED MIRROR_FAILED
}

# Function to check sstate logs
check_sstate_logs() {
    local SSTATE_DIR="$1"

    WORK_DIR="$BUILD_DIR/tmp-glibc/work"
    if [ ! -d "$WORK_DIR" ]; then
        echo -e "${RED}✗ Work directory not found${NC}"
        return 1
    fi

    echo -e "${BLUE}Searching for recent task logs...${NC}"
    local TASK_LOGS=$(find "$WORK_DIR" -name "log.do_*" -type f -mtime -1 2>/dev/null | grep -v "fetch" | head -20)

    if [ -z "$TASK_LOGS" ]; then
        echo -e "${YELLOW}⚠ No recent task logs found${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Found task logs${NC}"
    echo ""

    local SSTATE_FOUND=0
    local SSTATE_MISSED=0

    for log in $TASK_LOGS; do
        if grep -q "Sstate summary" "$log" 2>/dev/null; then
            PKG_NAME=$(echo "$log" | grep -oP '(?<=work/).*?(?=/temp/)' | tail -1)

            if grep -q "Missed" "$log" 2>/dev/null; then
                SSTATE_MISSED=$((SSTATE_MISSED + 1))
            elif grep -q "Found" "$log" 2>/dev/null; then
                SSTATE_FOUND=$((SSTATE_FOUND + 1))
                echo -e "${GREEN}✓ $PKG_NAME: Sstate found${NC}"
            fi
        fi
    done

    echo ""
    echo -e "${BLUE}Summary of sstate usage:${NC}"
    echo -e "  Sstate found (cache hit): ${GREEN}$SSTATE_FOUND${NC}"
    echo -e "  Sstate missed (cache miss): ${YELLOW}$SSTATE_MISSED${NC}"

    # Export for diagnosis
    export SSTATE_FOUND SSTATE_MISSED
}

# Function to provide diagnosis
provide_diagnosis() {
    local CHECK_MODE="$1"

    echo ""
    echo "========================================"
    echo "Diagnosis and Recommendations"
    echo "========================================"

    ISSUES=0
    LOCAL_CONF="$BUILD_DIR/conf/local.conf"
    SITE_CONF="$BUILD_DIR/../poky/meta-qti-bsp/conf/site.conf"

    if [[ "$CHECK_MODE" == "PM" ]] || [[ "$CHECK_MODE" == "BOTH" ]]; then
        echo ""
        echo -e "${CYAN}[PREMIRROR Issues]${NC}"

        # Check if local.conf has file:// premirror
        if [ -f "$LOCAL_CONF" ]; then
            if ! grep -q "file://" "$LOCAL_CONF" 2>/dev/null || ! grep -q "PREMIRRORS" "$LOCAL_CONF" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Issue: local.conf may not have file:// PREMIRRORS configured${NC}"
                echo "  Recommendation: Add or update PREMIRRORS in local.conf:"
                echo "  PREMIRRORS:prepend = \".*://.*/.* file://$PREMIRROR_DIR \\n\""
                ISSUES=$((ISSUES + 1))
            fi
        fi

        # Check priority issue
        if [ -f "$SITE_CONF" ] && grep -q "PREMIRRORS +=" "$SITE_CONF" 2>/dev/null; then
            if [ -f "$LOCAL_CONF" ] && grep -q "PREMIRRORS ?=" "$LOCAL_CONF" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Issue: Priority conflict detected${NC}"
                echo "  site.conf uses '+=' (immediate) while local.conf uses '?=' (default)"
                echo "  site.conf PREMIRRORS will take precedence"
                echo "  Recommendation: Use 'PREMIRRORS:prepend' in local.conf for highest priority"
                ISSUES=$((ISSUES + 1))
            fi
        fi

        # Check if premirror was actually used
        if [ "${MIRROR_USED:-0}" -eq 0 ] && [ "${MIRROR_FAILED:-0}" -gt 0 ]; then
            echo -e "${YELLOW}⚠ Issue: Premirror attempted but local file:// not accessed${NC}"
            echo "  Recent fetches tried PREMIRRORS but didn't use local file:// protocol"
            echo "  Recommendation: Check PREMIRRORS configuration in local.conf"
            ISSUES=$((ISSUES + 1))
        fi
    fi

    if [[ "$CHECK_MODE" == "SC" ]] || [[ "$CHECK_MODE" == "BOTH" ]]; then
        echo ""
        echo -e "${CYAN}[SSTATE-CACHE Issues]${NC}"

        # Check if SSTATE_DIR is configured
        if [ -f "$LOCAL_CONF" ]; then
            if ! grep -q "SSTATE_DIR" "$LOCAL_CONF" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Issue: SSTATE_DIR not configured in local.conf${NC}"
                echo "  Recommendation: Set SSTATE_DIR in local.conf:"
                echo "  SSTATE_DIR = \"$SSTATE_DIR\""
                ISSUES=$((ISSUES + 1))
            elif ! grep -q "$SSTATE_DIR" "$LOCAL_CONF" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Issue: SSTATE_DIR points to different location${NC}"
                echo "  Current config doesn't point to: $SSTATE_DIR"
                echo "  Recommendation: Update SSTATE_DIR in local.conf"
                ISSUES=$((ISSUES + 1))
            fi
        fi

        # Check sstate usage
        if [ "${SSTATE_FOUND:-0}" -eq 0 ] && [ "${SSTATE_MISSED:-0}" -gt 0 ]; then
            echo -e "${YELLOW}⚠ Issue: Sstate cache not being used${NC}"
            echo "  All tasks missed sstate cache"
            echo "  Recommendation: Check SSTATE_DIR configuration and ensure cache is populated"
            ISSUES=$((ISSUES + 1))
        fi
    fi

    echo ""
    if [ $ISSUES -eq 0 ]; then
        echo -e "${GREEN}✓ No major issues detected${NC}"
    else
        echo -e "${YELLOW}Found $ISSUES potential issue(s)${NC}"
    fi
}

# Main execution
case "$MODE" in
    PM)
        check_premirror
        provide_diagnosis "PM"
        ;;
    SC)
        check_sstate
        provide_diagnosis "SC"
        ;;
    BOTH)
        check_premirror
        check_sstate
        provide_diagnosis "BOTH"
        ;;
esac

echo ""
echo "========================================"
echo "Script completed"
echo "========================================"
