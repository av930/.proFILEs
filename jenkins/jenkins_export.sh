#!/bin/bash
# Jenkins Config.xml Batch Download Script
# Output format: ViewName/jobname.xml
set -euo pipefail

# ========================================
# Configuration
# ========================================
JENKINS_URL="${JENKINS_URL:-http://vjenkins.lge.com/jenkins03}"
JENKINS_USER="${JENKINS_USER:-joongkeun.kim}"
JENKINS_TOKEN="${JENKINS_TOKEN:-11ab112cf452ffb160bdb000b29c9395e2}"
OUT_DIR="${OUT_DIR:-./jenkins_export}"

# ========================================
# Functions
# ========================================
# Download single job config.xml
# Args: $1=job_url, $2=job_name, $3=view_name
download_job() {
    local job_url="$1" job_name="$2" view_name="$3"
    local view_dir

    # Sanitize view name for directory (remove quotes and replace special chars)
    view_dir=$(echo "$view_name" |'s#[/:]#_#g' |sed 's# #_#g')

    # Full output path: ViewName/jobname.xml
    local output_path="${OUT_DIR}/${view_dir}/${job_name}.xml"

    # Download
    mkdir -p "${OUT_DIR}/${view_dir}"
    if curl -sf -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${job_url}config.xml" -o "$output_path" 2>/dev/null;
    then echo "✓ ${view_dir}/${job_name}.xml"
    else echo "✗ Failed: ${view_dir}/${job_name}.xml" >&2
    fi
}

# Process jobs recursively (handles both views and folders)
# Args: $1=url (with trailing /), $2=view_name, $3=log_prefix (optional)
process_jobs() {
    local url="$1" view_name="$2" log_prefix="${3:-}"
    [[ -n "$log_prefix" ]] && echo "$log_prefix" >&2

    # Fetch jobs list once and process
    curl -sf -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${url}api/json?tree=jobs\[name,url,_class\]" 2>/dev/null \
        | jq -r '.jobs[]? | "\(.name)|\(.url)|\(._class)"' \
        | while IFS='|' read -r name job_url job_class; do
            [[ -z "$name" ]] && continue

            case "$job_class" in
                *Folder|*WorkflowMultiBranchProject) # Recursively process folder contents
                    process_jobs "$job_url" "$view_name"

                ;;                                *) # Download regular job
                    download_job "$job_url" "$name" "$view_name"
            esac
        done
}

# ========================================
# Main
# ========================================
main() {
    echo "Jenkins Config.xml Batch Downloader"
    echo "========================================="
    echo "Jenkins: ${JENKINS_URL}"
    echo "User: ${JENKINS_USER}"
    echo "Output: ${OUT_DIR}"
    echo ""

    # Test connection
    if ! curl -sf -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${JENKINS_URL}/api/json" 2>/dev/null | jq -e '.jobs' >/dev/null 2>&1; then
        echo "ERROR: Cannot connect to Jenkins. Check credentials." >&2;  exit 1
    fi

    # Create output directory
    mkdir -p "$OUT_DIR"

    # Get all views
    echo "Fetching all views..."
    local views_list
    views_list=$(curl -sf -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${JENKINS_URL}/api/json?tree=views\[name,url\]" 2>/dev/null | jq -r '.views[]? | "\(.name)|\(.url)"')
    while IFS='|' read -r view_name view_url; do
        [[ -z "$view_name" ]] && continue
        process_jobs "$view_url" "$view_name" "$(echo -e '\nProcessing View: '"$view_name")"
    done <<< "$views_list"

    echo ""
    echo "========================================="
    echo "Download complete!"
    echo "Total files: $(find "$OUT_DIR" -name "*.xml" 2>/dev/null | wc -l)"
    echo "Output: ${OUT_DIR}"
    echo "========================================="
}

main "$@"
