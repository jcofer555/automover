#!/usr/bin/env bash
set -Eeuo pipefail

rm -f /tmp/automover/boot_failure
rm -f /tmp/automover/temp_logs/status.txt

# ==========================================================
#  CONSTANTS
# ==========================================================
readonly SCRIPT_NAME="automover"
readonly CFG_PATH="/boot/config/plugins/automover/settings.cfg"
readonly PLG_FILE="/boot/config/plugins/automover.plg"
readonly SHARE_CFG_DIR="/boot/config/shares"
readonly EXCLUSIONS_FILE="/boot/config/plugins/automover/exclusions.txt"
readonly ARRAY_STATE_FILE="/var/local/emhttp/var.ini"

readonly TMP_DIR="/tmp/automover"
readonly TMP_LOGS_DIR="${TMP_DIR}/temp_logs"
readonly LAST_RUN_FILE="${TMP_DIR}/last_run.log"
readonly DEBUG_LOG="${TMP_DIR}/automover-debug.log"
readonly FILES_MOVED_LOG="${TMP_DIR}/files_moved.log"
readonly IN_USE_FILE="${TMP_DIR}/in_use_files.txt"
readonly STATUS_FILE="${TMP_LOGS_DIR}/status.txt"
readonly MOVED_SHARES_FILE="${TMP_LOGS_DIR}/moved_shares.txt"
readonly CLEANUP_SOURCES_FILE="${TMP_LOGS_DIR}/cleanup_sources.txt"
readonly STOP_FILE="${TMP_LOGS_DIR}/stopped_containers.txt"
readonly RSYNC_SPEED_FILE="${TMP_LOGS_DIR}/rsync_speed.txt"
readonly LOCK_FILE="${TMP_DIR}/lock.txt"
readonly DONE_FILE="${TMP_LOGS_DIR}/done.txt"
readonly QBIT_PAUSED_FILE="${TMP_DIR}/qbittorrent_paused.txt"
readonly QBIT_RESUMED_FILE="${TMP_DIR}/qbittorrent_resumed.txt"
readonly ELIGIBLE_TMP_FILE="${TMP_LOGS_DIR}/eligible_files.txt"

# ==========================================================
#  STATE
# ==========================================================
STATE_INIT="INIT"
STATE_VALIDATE="VALIDATE"
STATE_PROCESS="PROCESS"
STATE_COMPLETE="COMPLETE"
STATE_ERROR="ERROR"

current_state_str="${STATE_INIT}"

# ==========================================================
#  RUNTIME FLAGS
# ==========================================================
move_now_bool=false
containers_stopped_bool=false
moved_anything_bool=false
stop_triggered_bool=false
qbit_paused_bool=false
skip_qbit_bool=false
pre_move_done_str="no"
sent_start_notif_str="no"
turbo_write_enabled_bool=false

skipped_hidden_int=0
skipped_size_int=0
skipped_age_int=0
skipped_excl_int=0

start_time_int=0
prev_status_str="Stopped"

# ==========================================================
#  LOGGING
# ==========================================================
mkdir -p "${TMP_DIR}" "${TMP_LOGS_DIR}"

# log_info  — writes to last_run.log (human-facing session log)
log_info() {
    echo "$*" >> "${LAST_RUN_FILE}"
}

# log_debug — writes to debug log with timestamp + level
log_debug() {
    echo "[$(date '+%F %T')] [DEBUG] $*" >> "${DEBUG_LOG}"
}

# log_warn — both logs
log_warn() {
    echo "[$(date '+%F %T')] [WARN]  $*" >> "${DEBUG_LOG}"
    echo "⚠ $*" >> "${LAST_RUN_FILE}"
}

# log_error — both logs
log_error() {
    echo "[$(date '+%F %T')] [ERROR] $*" >> "${DEBUG_LOG}"
    echo "❌ $*" >> "${LAST_RUN_FILE}"
}

# log_step — debug log only, marks major state transitions
log_step() {
    echo "[$(date '+%F %T')] [STEP]  state=${current_state_str} | $*" >> "${DEBUG_LOG}"
}

# ==========================================================
#  ERROR TRAP
# ==========================================================
trap 'log_error "Unexpected error on line ${LINENO} (exit ${?}). state=${current_state_str}"' ERR

# ==========================================================
#  SETUP
# ==========================================================
log_debug "Script invoked. args=${*:-<none>}"

# Rotate debug log if over 5 MB
if [[ -f "${DEBUG_LOG}" ]] && (( $(stat -c%s "${DEBUG_LOG}" 2>/dev/null || echo 0) > 5242880 )); then
    mv "${DEBUG_LOG}" "${DEBUG_LOG}.prev"
    log_debug "Debug log rotated (exceeded 5 MB)"
fi

# Clear temp state files
> "${IN_USE_FILE}"
> "${CLEANUP_SOURCES_FILE}"
> "${RSYNC_SPEED_FILE}"
> "${QBIT_PAUSED_FILE}"
> "${QBIT_RESUMED_FILE}"
rm -f "${TMP_LOGS_DIR}/qbittorrent_pause.txt" \
      "${TMP_LOGS_DIR}/qbittorrent_resume.txt" \
      "${DONE_FILE}"
> "${MOVED_SHARES_FILE}"

# ==========================================================
#  STATUS HELPER
# ==========================================================
set_status() {
    local new_status_str="$1"
    echo "${new_status_str}" > "${STATUS_FILE}"
    log_debug "Status → ${new_status_str}"
}

# Capture previous status before overwriting
if [[ -f "${STATUS_FILE}" ]]; then
    prev_status_str="$(tr -d '\r\n' < "${STATUS_FILE}")"
fi
log_debug "Previous status: ${prev_status_str}"

# ==========================================================
#  LOCK
# ==========================================================
if [[ -z "${SCHEDULE_ID:-}" ]]; then
    # Direct or Move Now invocation — check for a running instance ourselves
    if [[ -f "${LOCK_FILE}" ]]; then
        lock_pid_int="$(grep -m1 '^PID=' "${LOCK_FILE}" | cut -d'=' -f2)"
        [[ -z "${lock_pid_int}" ]] && lock_pid_int="$(head -1 "${LOCK_FILE}" 2>/dev/null)"
        if [[ -n "${lock_pid_int}" ]] && ps -p "${lock_pid_int}" > /dev/null 2>&1; then
            log_debug "Another instance is running (PID ${lock_pid_int}). Exiting."
            exit 0
        else
            log_warn "Stale lock file found (PID ${lock_pid_int:-unknown} not running). Removing."
            rm -f "${LOCK_FILE}"
        fi
    fi
fi
# Write our PID — takes over from PHP's metadata for scheduled runs,
# or establishes the lock for direct runs.
echo $$ > "${LOCK_FILE}"
log_debug "Lock acquired (PID $$)"

# ==========================================================
#  CLEANUP / EXIT HANDLER
# ==========================================================
cleanup() {
    local exit_code_int="${1:-0}"
    log_debug "cleanup() called. exit_code=${exit_code_int} state=${current_state_str}"
    set_status "${prev_status_str}"
    rm -f "${LOCK_FILE}"
    log_debug "Lock released. Exiting with code ${exit_code_int}."
    exit "${exit_code_int}"
}

# Graceful stop — called when stop button sends SIGTERM.
_stop_requested_bool=false
handle_stop() {
    if [[ "${_stop_requested_bool}" == true ]]; then return; fi
    _stop_requested_bool=true
    log_info "Stop requested — finishing current file then stopping"
    log_debug "SIGTERM received. Finishing current rsync then stopping."
    ( sleep 2 && kill -TERM $$ 2>/dev/null ) &
}
trap 'handle_stop' SIGTERM
trap 'cleanup 0' SIGINT SIGHUP SIGQUIT

# ==========================================================
#  MOVE NOW OVERRIDE
# ==========================================================
if [[ "${1:-}" == "--force-now" ]]; then
    move_now_bool=true
    shift
    log_debug "Move Now mode activated"
fi
if [[ "${1:-}" == "--pool" && -n "${2:-}" ]]; then
    POOL_NAME_OVERRIDE="${2}"
    shift 2
    log_debug "Pool override: ${POOL_NAME_OVERRIDE}"
fi

# ==========================================================
#  LOAD CONFIG
# ==========================================================
current_state_str="${STATE_VALIDATE}"
log_step "Loading config"
set_status "Loading Config"

if [[ ! -f "${CFG_PATH}" ]]; then
    log_error "Config file not found: ${CFG_PATH}"
    cleanup 0
fi

CONFIG_VARS=(
    AGE_BASED_FILTER AGE_DAYS ALLOW_DURING_PARITY
    CLEANUP CLEANUP_ZFS_DATASETS CPU_AND_IO_PRIORITIES DRY_RUN
    EXCLUSIONS FORCE_TURBO_WRITE
    HASH_LOCATION HIDDEN_FILTER IO_PRIORITY
    JDUPES
    NOTIFICATION_SERVICE NOTIFICATIONS POOL_NAME POST_SCRIPT PRE_AND_POST_SCRIPTS PRE_SCRIPT
    CPU_PRIORITY PUSHOVER_USER_KEY
    QBITTORRENT_DAYS_FROM QBITTORRENT_DAYS_TO QBITTORRENT_HOST
    QBITTORRENT_MOVE_SCRIPT QBITTORRENT_PASSWORD QBITTORRENT_STATUS QBITTORRENT_USERNAME
    SIZE SIZE_BASED_FILTER SIZE_UNIT
    STOP_ALL_CONTAINERS STOP_CONTAINERS STOP_THRESHOLD SSD_TRIM
    THRESHOLD
    WEBHOOK_DISCORD WEBHOOK_GOTIFY WEBHOOK_NTFY WEBHOOK_PUSHOVER WEBHOOK_SLACK
)

declare -A sched_env_arr=()
if [[ -n "${SCHEDULE_ID:-}" ]]; then
    log_debug "Scheduled run detected (SCHEDULE_ID=${SCHEDULE_ID}) — capturing env overrides"
    for var in "${CONFIG_VARS[@]}"; do
        if [[ -n "${!var+x}" ]]; then
            sched_env_arr["${var}"]="${!var}"
        fi
    done
fi

# shellcheck source=/dev/null
source "${CFG_PATH}"
log_debug "Config loaded from ${CFG_PATH}"

if [[ "${#sched_env_arr[@]}" -gt 0 ]]; then
    for var in "${!sched_env_arr[@]}"; do
        declare "${var}=${sched_env_arr[${var}]}"
        log_debug "Schedule override: ${var}=${sched_env_arr[${var}]}"
    done
fi

if [[ -n "${POOL_NAME_OVERRIDE:-}" ]]; then
    POOL_NAME="${POOL_NAME_OVERRIDE}"
fi

for var in "${CONFIG_VARS[@]}"; do
    if [[ -n "${!var+x}" ]]; then
        eval "${var}=\"$(echo "${!var}" | tr -d '\"')\""
    fi
done
log_debug "Config values stripped of quotes"

# ==========================================================
#  SIZE UNIT → BYTES CONVERSION
# ==========================================================
SIZE_BYTES_INT=0
if [[ "${SIZE_BASED_FILTER:-no}" == "yes" && "${SIZE:-0}" -gt 0 ]]; then
    case "${SIZE_UNIT:-MB}" in
        TB) SIZE_BYTES_INT=$(( SIZE * 1024 * 1024 * 1024 * 1024 )) ;;
        GB) SIZE_BYTES_INT=$(( SIZE * 1024 * 1024 * 1024 )) ;;
        MB) SIZE_BYTES_INT=$(( SIZE * 1024 * 1024 )) ;;
        *)  SIZE_BYTES_INT=$(( SIZE * 1024 * 1024 )) ;;
    esac
    log_debug "Size filter: ${SIZE} ${SIZE_UNIT:-MB} = ${SIZE_BYTES_INT} bytes"
fi

if [[ "${DRY_RUN:-no}" == "yes" ]]; then
    NOTIFICATIONS="no"
    log_debug "Dry run active — notifications disabled"
fi

# ==========================================================
#  PRIORITY SETUP
# ==========================================================
log_step "Normalising priority settings"

IO_CLASS_STR=""
IO_LEVEL_STR=""

if [[ "${CPU_AND_IO_PRIORITIES:-no}" != "yes" ]]; then
    CPU_PRIORITY=""
    log_debug "Priorities disabled"
else
    if [[ -z "${CPU_PRIORITY:-}" || ! "${CPU_PRIORITY}" =~ ^-?[0-9]+$ ]]; then
        CPU_PRIORITY=0
    elif (( CPU_PRIORITY < -20 )); then
        CPU_PRIORITY=-20
    elif (( CPU_PRIORITY > 19 )); then
        CPU_PRIORITY=19
    fi

    case "${IO_PRIORITY:-normal}" in
        idle)     IO_CLASS_STR=3; IO_LEVEL_STR="" ;;
        be:[0-7]) IO_CLASS_STR=2; IO_LEVEL_STR="${IO_PRIORITY#be:}" ;;
        normal|"") IO_CLASS_STR=""; IO_LEVEL_STR="" ;;
        *) IO_CLASS_STR=""; IO_LEVEL_STR="" ;;
    esac
    log_debug "Priorities: cpu=${CPU_PRIORITY} io_class=${IO_CLASS_STR} io_level=${IO_LEVEL_STR}"
fi

rsync_wrapper_arr=()
if [[ "${CPU_AND_IO_PRIORITIES:-no}" == "yes" ]]; then
    [[ -n "${CPU_PRIORITY}" ]] && rsync_wrapper_arr+=(nice -n "${CPU_PRIORITY}")
    if [[ -n "${IO_CLASS_STR}" ]]; then
        if [[ "${IO_CLASS_STR}" == "3" ]]; then
            rsync_wrapper_arr+=(ionice -c3)
        elif [[ "${IO_CLASS_STR}" == "2" ]]; then
            rsync_wrapper_arr+=(ionice -c2 -n "${IO_LEVEL_STR}")
        fi
    fi
fi
log_debug "rsync_wrapper_arr=(${rsync_wrapper_arr[*]:-<none>})"

# ==========================================================
#  SKIP LOGIC (scheduled runs only)
# ==========================================================
if [[ "${move_now_bool}" != true ]]; then
    if [[ -f "${STATUS_FILE}" && "$(cat "${STATUS_FILE}")" == "Stopped" ]]; then
        log_debug "Status is Stopped and this is a scheduled run. Exiting."
        cleanup 0
    fi
fi

# ==========================================================
#  NOTIFICATIONS HELPERS
# ==========================================================
unraid_notify() {
    local title_str="$1"
    local message_str="$2"
    local level_str="${3:-normal}"
    local delay_int="${4:-0}"
    if (( delay_int > 0 )); then
        echo "/usr/local/emhttp/webGui/scripts/notify -e '${SCRIPT_NAME}' -s '${title_str}' -d '${message_str}' -i '${level_str}'" \
            | at now + "${delay_int}" minutes 2>/dev/null
    else
        /usr/local/emhttp/webGui/scripts/notify \
            -e "${SCRIPT_NAME}" -s "${title_str}" -d "${message_str}" -i "${level_str}"
    fi
}

send_discord_message() {
    local title_str="$1"
    local message_str="$2"
    local color_int="${3:-65280}"
    local webhook_str="${WEBHOOK_URL:-}"
    [[ -z "${webhook_str}" ]] && return
    if ! command -v jq > /dev/null 2>&1; then
        log_warn "jq not found — skipping Discord notification"
        return
    fi
    local json_str
    json_str="$(jq -n \
        --arg title "${title_str}" \
        --arg message "${message_str}" \
        --argjson color "${color_int}" \
        '{embeds:[{title:$title,description:$message,color:$color}]}')"
    curl -s -X POST -H "Content-Type: application/json" \
        -d "${json_str}" "${webhook_str}" > /dev/null 2>&1
    log_debug "Discord notification sent: ${title_str}"
}

send_summary_notification() {
    [[ "${NOTIFICATIONS:-no}" != "yes" ]] && return
    if [[ "${prev_status_str}" == "Stopped" && "${move_now_bool}" == false ]]; then
        return
    fi
    if [[ "${moved_anything_bool}" != true ]]; then
        log_info "No files moved — skipping summary notification"
        return
    fi

    declare -A share_counts_arr
    local total_moved_int=0

    if [[ -f "${FILES_MOVED_LOG}" && -s "${FILES_MOVED_LOG}" ]]; then
        while IFS='>' read -r _ dst_str; do
            dst_str="$(echo "${dst_str}" | xargs)"
            [[ -z "${dst_str}" ]] && continue
            local share_str
            share_str="$(echo "${dst_str}" | awk -F'/' '$3=="user0"{print $4}')"
            [[ -z "${share_str}" ]] && continue
            (( share_counts_arr["${share_str}"]++ )) || true
            (( total_moved_int++ )) || true
        done < <(grep -E ' -> ' "${FILES_MOVED_LOG}" || true)
    fi

    local end_time_int duration_int runtime_str
    end_time_int="$(date +%s)"
    duration_int=$(( end_time_int - start_time_int ))
    if (( duration_int < 60 )); then
        runtime_str="${duration_int}s"
    elif (( duration_int < 3600 )); then
        runtime_str="$((duration_int / 60))m $((duration_int % 60))s"
    else
        runtime_str="$((duration_int / 3600))h $(((duration_int % 3600) / 60))m"
    fi

    local notif_body_str="automover finished moving ${total_moved_int} file(s) in ${runtime_str}."
    log_debug "Summary notification: ${notif_body_str}"

    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        if (( ${#share_counts_arr[@]} > 0 )); then
            notif_body_str+=$'\n\nPer share summary:'
            while IFS= read -r share_str; do
                notif_body_str+=$'\n'"• ${share_str}: ${share_counts_arr[${share_str}]} file(s)"
            done < <(printf '%s\n' "${!share_counts_arr[@]}" | LC_ALL=C sort)
        fi
        send_discord_message "Session finished" "${notif_body_str}" 65280
    else
        local notif_body_html_str="${notif_body_str}"
        local agent_active_bool=false
        local notif_cfg_str="/boot/config/plugins/dynamix/dynamix.cfg"
        if [[ -f "${notif_cfg_str}" ]]; then
            local normal_val_str
            normal_val_str="$(grep -Po 'normal="\K[0-9]+' "${notif_cfg_str}" 2>/dev/null || echo "")"
            if [[ "${normal_val_str}" =~ ^(4|5|6|7)$ ]]; then
                agent_active_bool=true
            elif [[ "${normal_val_str}" == "0" ]]; then
                log_info "Unraid notice notifications are disabled at Settings > Notifications"
            fi
        fi
        if [[ "${agent_active_bool}" == true ]]; then
            if (( ${#share_counts_arr[@]} > 0 )); then
                notif_body_html_str+=" - Per share summary: "
                local first_bool=true
                while IFS= read -r share_str; do
                    if [[ "${first_bool}" == true ]]; then
                        notif_body_html_str+="${share_str}: ${share_counts_arr[${share_str}]} file(s)"
                        first_bool=false
                    else
                        notif_body_html_str+=" - ${share_str}: ${share_counts_arr[${share_str}]} file(s)"
                    fi
                done < <(printf '%s\n' "${!share_counts_arr[@]}" | LC_ALL=C sort)
            fi
        else
            if (( ${#share_counts_arr[@]} > 0 )); then
                notif_body_html_str+="<br><br>Per share summary:<br>"
                while IFS= read -r share_str; do
                    notif_body_html_str+="• ${share_str}: ${share_counts_arr[${share_str}]} file(s)<br>"
                done < <(printf '%s\n' "${!share_counts_arr[@]}" | LC_ALL=C sort)
            fi
        fi
        unraid_notify "Session finished" "${notif_body_html_str}" "normal" 1
    fi
}

# ==========================================================
#  CONTAINER MANAGEMENT
# ==========================================================
manage_containers() {
    local action_str="$1"
    log_step "manage_containers action=${action_str}"

    if [[ "${STOP_ALL_CONTAINERS:-no}" == "yes" && "${DRY_RUN:-no}" != "yes" ]]; then
        if [[ "${action_str}" == "stop" ]]; then
            set_status "Stopping all docker containers"
            log_info "Stopping all docker containers"
            : > "${STOP_FILE}"
            while IFS= read -r cid_str; do
                local cname_str
                cname_str="$(docker inspect --format='{{.Name}}' "${cid_str}" | sed 's#^/##')"
                if docker stop "${cid_str}" > /dev/null 2>&1; then
                    log_info "Stopped container: ${cname_str}"
                    log_debug "Stopped container: ${cname_str} (${cid_str})"
                    echo "${cname_str}" >> "${STOP_FILE}"
                else
                    log_error "Failed to stop container: ${cname_str}"
                fi
            done < <(docker ps -q)
            containers_stopped_bool=true

        elif [[ "${action_str}" == "start" && "${containers_stopped_bool}" == true ]]; then
            set_status "Starting docker containers that automover stopped"
            log_info "Starting docker containers that automover stopped"
            if [[ -f "${STOP_FILE}" ]]; then
                while IFS= read -r cname_str; do
                    [[ -z "${cname_str}" ]] && continue
                    if docker start "${cname_str}" > /dev/null 2>&1; then
                        log_info "Started container: ${cname_str}"
                        log_debug "Started container: ${cname_str}"
                    else
                        log_error "Failed to start container: ${cname_str}"
                    fi
                done < "${STOP_FILE}"
                rm -f "${STOP_FILE}"
            fi
        fi

    elif [[ -n "${STOP_CONTAINERS:-}" && "${DRY_RUN:-no}" != "yes" ]]; then
        IFS=',' read -ra containers_arr <<< "${STOP_CONTAINERS}"
        if [[ "${action_str}" == "stop" ]]; then
            set_status "Stopping selected containers"
            : > "${STOP_FILE}"
            for container_str in "${containers_arr[@]}"; do
                container_str="$(echo "${container_str}" | xargs)"
                [[ -z "${container_str}" ]] && continue
                if docker stop "${container_str}" > /dev/null 2>&1; then
                    log_info "Stopped container: ${container_str}"
                    log_debug "Stopped container: ${container_str}"
                    echo "${container_str}" >> "${STOP_FILE}"
                else
                    log_error "Failed to stop container: ${container_str}"
                fi
            done
            containers_stopped_bool=true

        elif [[ "${action_str}" == "start" && "${containers_stopped_bool}" == true ]]; then
            set_status "Starting selected containers"
            if [[ -f "${STOP_FILE}" ]]; then
                while IFS= read -r container_str; do
                    [[ -z "${container_str}" ]] && continue
                    if docker start "${container_str}" > /dev/null 2>&1; then
                        log_info "Started container: ${container_str}"
                        log_debug "Started container: ${container_str}"
                    else
                        log_error "Failed to start container: ${container_str}"
                    fi
                done < "${STOP_FILE}"
                rm -f "${STOP_FILE}"
            fi
        fi
    else
        log_debug "manage_containers: no container config applies for action=${action_str}"
    fi
}

# ==========================================================
#  QBITTORRENT HELPER
# ==========================================================
run_qbit_script() {
    local action_str="$1"
    local python_script_str="/usr/local/emhttp/plugins/automover/helpers/qbittorrent_script.py"
    local tmp_out_str="${TMP_LOGS_DIR}/qbittorrent_${action_str}.txt"
    local status_filter_str="${QBITTORRENT_STATUS:-completed}"

    log_step "run_qbit_script action=${action_str}"

    if [[ ! -f "${python_script_str}" ]]; then
        log_error "qBittorrent script not found: ${python_script_str}"
        return
    fi
    [[ "${action_str}" == "resume" ]] && status_filter_str="paused"

    python3 "${python_script_str}" \
        --host "${QBITTORRENT_HOST:-}" \
        --user "${QBITTORRENT_USERNAME:-}" \
        --password "${QBITTORRENT_PASSWORD:-}" \
        --cache-mount "/mnt/${POOL_NAME:-cache}" \
        --days_from "${QBITTORRENT_DAYS_FROM:-0}" \
        --days_to "${QBITTORRENT_DAYS_TO:-2}" \
        --status-filter "${status_filter_str}" \
        "--${action_str}" 2>&1 \
    | tee -a "${tmp_out_str}" \
    | grep -E '^(Running qBittorrent|Paused|Resumed|Pausing|Resuming|qBittorrent)' \
    >> "${LAST_RUN_FILE}" || true

    grep -E "Pausing:|Paused:" "${tmp_out_str}" \
        | sed -E 's/.*(Pausing:|Paused:)[[:space:]]*//; s/[[:space:]]*\[[0-9]+\][[:space:]]*$//' \
        >> "${QBIT_PAUSED_FILE}" || true

    if [[ "${action_str}" == "pause" ]] && ! grep -qE "Pausing:|Paused:" "${tmp_out_str}" 2>/dev/null; then
        echo "Pause attempted but no torrents were paused" >> "${QBIT_PAUSED_FILE}"
    fi

    grep -E "Resuming:|Resumed:" "${tmp_out_str}" \
        | sed -E 's/.*(Resuming:|Resumed:)[[:space:]]*//; s/[[:space:]]*\[[0-9]+\][[:space:]]*$//' \
        >> "${QBIT_RESUMED_FILE}" || true

    if [[ "${action_str}" == "resume" ]] && ! grep -qE "Resuming:|Resumed:" "${tmp_out_str}" 2>/dev/null; then
        echo "Resume attempted but no torrents were resumed" >> "${QBIT_RESUMED_FILE}"
    fi

    local count_int=0
    if [[ "${action_str}" == "pause" ]]; then
        count_int="$(grep -v "Pause attempted" "${QBIT_PAUSED_FILE}" 2>/dev/null | grep -cve '^\s*$' || echo 0)"
    else
        count_int="$(grep -v "Resume attempted" "${QBIT_RESUMED_FILE}" 2>/dev/null | grep -cve '^\s*$' || echo 0)"
    fi
    log_info "qBittorrent ${action_str} of ${count_int} torrents"
    log_debug "qBittorrent ${action_str} completed. count=${count_int}"
}

# ==========================================================
#  HELPER: WAIT FOR FILE HANDLE RELEASE
# ==========================================================
wait_for_release() {
    local file_str="$1"
    local attempt_int
    for attempt_int in {1..10}; do
        if ! fuser "${file_str}" > /dev/null 2>&1; then
            return 0
        fi
        log_debug "File in use (attempt ${attempt_int}/10): ${file_str}"
        sleep 2
    done
    log_warn "File still in use after 10 attempts: ${file_str}"
    return 1
}

# ==========================================================
#  HELPER: COPY EMPTY DIRECTORIES
# ==========================================================
copy_empty_dirs() {
    local src_str="$1"
    local dst_str="$2"
    [[ ! -d "${src_str}" ]] && return
    src_str="${src_str%/}"

    find "${src_str}" -type d | while IFS= read -r dir_str; do
        [[ "${dir_str}" == "${src_str}" ]] && continue
        local dst_dir_str="${dst_str}/${dir_str#${src_str}/}"
        local skip_dir_bool=false

        if [[ "${EXCLUSIONS:-no}" == "yes" && ${#excluded_paths_arr[@]} -gt 0 ]]; then
            local ex_str
            for ex_str in "${excluded_paths_arr[@]}"; do
                [[ -d "${ex_str}" && "${ex_str}" != */ ]] && ex_str="${ex_str}/"
                local dir_check_str="${dir_str}/"
                if [[ "${dir_check_str}" == "${ex_str}"* ]]; then
                    skip_dir_bool=true
                    break
                fi
            done
        fi
        "${skip_dir_bool}" && continue

        if [[ -z "$(ls -A "${dir_str}" 2>/dev/null)" ]]; then
            mkdir -p "${dst_dir_str}"
            chown "${src_owner_str}:${src_group_str}" "${dst_dir_str}"
            chmod "${src_perms_str}" "${dst_dir_str}"
            log_debug "Created empty directory: ${dst_dir_str}"
        fi
    done
}

# ==========================================================
#  FILESYSTEM SAFETY HELPERS
# ==========================================================
hash_string() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

safe_rmdir() {
    local dir_str="$1"
    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        local hash_str
        hash_str="$(hash_string "${dir_str}")"
        log_info "DRY-RUN: would remove empty folder [${hash_str}] ${dir_str}"
        log_debug "DRY-RUN rmdir: ${dir_str}"
    else
        if rmdir "${dir_str}" 2>/dev/null; then
            log_debug "Removed empty folder: ${dir_str}"
        fi
    fi
}

safe_zfs_destroy() {
    local ds_str="$1"
    local hash_str
    hash_str="$(hash_string "${ds_str}")"
    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "DRY-RUN: would destroy empty dataset [${hash_str}] ${ds_str}"
        log_debug "DRY-RUN zfs destroy: ${ds_str}"
    else
        if zfs destroy -f "${ds_str}" > /dev/null 2>&1; then
            log_debug "Destroyed empty dataset [${hash_str}]: ${ds_str}"
        fi
    fi
}

guard_pool_path() {
    local pool_name_str="$1"
    local pool_path_str="/mnt/${pool_name_str}"
    [[ -n "${pool_name_str}" ]]                         || { log_error "guard_pool_path: empty pool name"; return 1; }
    [[ "${pool_name_str}" =~ ^[A-Za-z0-9._-]+$ ]]      || { log_error "guard_pool_path: invalid characters in pool name: ${pool_name_str}"; return 1; }
    [[ -d "${pool_path_str}" ]]                         || { log_error "guard_pool_path: pool path does not exist: ${pool_path_str}"; return 1; }
    [[ "${pool_path_str}" == /mnt/* ]]                  || { log_error "guard_pool_path: pool path not under /mnt: ${pool_path_str}"; return 1; }
    log_debug "guard_pool_path: ${pool_path_str} OK"
    return 0
}

# ==========================================================
#  CLEANUP HELPERS (mover-tuning style)
#
#  CLEANUP controls empty folder removal:
#    no  — disabled entirely
#    yes — remove empty subdirectories (never the share root itself)
#    top — same as yes, but also removes the top-level share dir if empty
#
#  CLEANUP_ZFS_DATASETS controls ZFS dataset removal independently:
#    no  — never destroy empty ZFS datasets
#    yes — destroy empty ZFS sub-datasets under moved shares
#
#  All functions below are only ever called when CLEANUP != no.
# ==========================================================

# Returns 0 if the given path is itself a ZFS mountpoint (not just under one)
is_zfs_mountpoint() {
    local path_str="${1%/}"
    command -v zfs > /dev/null 2>&1 || return 1
    zfs list -H -o mountpoint 2>/dev/null | grep -qxF "${path_str}"
}

# cleanup_empty_parents()
# Called immediately after each successful file move (only when CLEANUP != no).
# Walks up the source directory tree from the moved file, removing each
# ancestor that is now empty, stopping just before the share root.
# When CLEANUP=top the share root itself is also eligible for removal.
#
# Protections (matching mover tuning):
#   - Share root is only removed when CLEANUP=top
#   - Skips dirs containing a .placeholder file
#   - Skips dirs that are ZFS mountpoints
#   - Stops climbing as soon as a non-empty dir is found
#   - Full dry-run support
#
# Args:
#   $1  moved_file_src  — absolute source path of the file that was just moved
#   $2  share_src_root  — absolute path of the share root on the pool
#                         e.g. /mnt/cache/movies
cleanup_empty_parents() {
    local file_src_str="$1"
    local share_root_str="${2%/}"

    local dir_str
    dir_str="$(dirname "${file_src_str}")"

    # Walk up. When CLEANUP=top we allow removing the share root itself;
    # otherwise we stop as soon as we reach it.
    while [[ "${dir_str}" == "${share_root_str}" || "${dir_str}" == "${share_root_str}/"* ]]; do

        # If we've reached the share root, only continue when CLEANUP=top
        if [[ "${dir_str}" == "${share_root_str}" && "${CLEANUP:-no}" != "top" ]]; then
            break
        fi

        # Must still exist
        [[ -d "${dir_str}" ]] || break

        # .placeholder protection — leave the folder and stop climbing
        if [[ -f "${dir_str}/.placeholder" ]]; then
            log_debug "cleanup_empty_parents: skipping (has .placeholder): ${dir_str}"
            break
        fi

        # ZFS mountpoint protection — skip rmdir on a dataset root
        if is_zfs_mountpoint "${dir_str}"; then
            log_debug "cleanup_empty_parents: skipping ZFS mountpoint: ${dir_str}"
            break
        fi

        # If not empty, stop — parent dirs won't be empty either
        local contents_str
        contents_str="$(ls -A "${dir_str}" 2>/dev/null)"
        if [[ -n "${contents_str}" ]]; then
            log_debug "cleanup_empty_parents: not empty, stopping at: ${dir_str}"
            break
        fi

        # Empty — remove it
        if [[ "${DRY_RUN:-no}" == "yes" ]]; then
            log_info "DRY-RUN: would remove empty folder: ${dir_str}"
            log_debug "DRY-RUN cleanup_empty_parents: ${dir_str}"
        else
            if rmdir "${dir_str}" 2>/dev/null; then
                log_debug "Removed empty folder: ${dir_str}"
            else
                log_debug "cleanup_empty_parents: rmdir failed (busy?): ${dir_str}"
                break
            fi
        fi

        # Once we've handled the share root (top mode) there's nowhere left to climb
        [[ "${dir_str}" == "${share_root_str}" ]] && break

        # Climb one level
        dir_str="$(dirname "${dir_str}")"
    done
}

# Protected share names — never cleaned at top level
declare -A _CLEANUP_HARD_EXCL=([appdata]=1 [system]=1 [domains]=1 [isos]=1)

# _cleanup_share_ok()
# Returns 0 if a share is eligible for cleanup:
#   - not in the hard-exclude list
#   - has a secondary pool configured in its share config
_cleanup_share_ok() {
    local share_str="$1"
    [[ -n "${_CLEANUP_HARD_EXCL[${share_str}]+x}" ]] && return 1
    local cfg_str="${SHARE_CFG_DIR}/${share_str}.cfg"
    [[ -f "${cfg_str}" ]] || return 1
    local pool2_str
    pool2_str="$(grep -E '^shareCachePool2=' "${cfg_str}" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs || true)"
    [[ -n "${pool2_str}" ]]
}

# _sweep_empty_dirs()
# Depth-first sweep of all subdirectories under a share root, removing empty
# ones. The share root itself is only removed when CLEANUP=top.
# ZFS sub-datasets are only destroyed when CLEANUP_ZFS_DATASETS=yes.
# Protections: .placeholder, ZFS mountpoints, dry-run.
#
# Args:
#   $1  share_root_str — absolute path of the share root to sweep
_sweep_empty_dirs() {
    local share_root_str="${1%/}"
    [[ -d "${share_root_str}" ]] || return

    # Process deepest directories first so parents become empty after children
    while IFS= read -r dir_str; do
        [[ -d "${dir_str}" ]] || continue

        # Share root: only remove when CLEANUP=top
        if [[ "${dir_str}" == "${share_root_str}" ]]; then
            [[ "${CLEANUP:-no}" == "top" ]] || continue
        fi

        # .placeholder protection
        if [[ -f "${dir_str}/.placeholder" ]]; then
            log_debug "_sweep_empty_dirs: skipping (has .placeholder): ${dir_str}"
            continue
        fi

        # ZFS mountpoint protection
        if is_zfs_mountpoint "${dir_str}"; then
            log_debug "_sweep_empty_dirs: skipping ZFS mountpoint: ${dir_str}"
            continue
        fi

        # Only act if empty
        local contents_str
        contents_str="$(ls -A "${dir_str}" 2>/dev/null)"
        [[ -n "${contents_str}" ]] && continue

        safe_rmdir "${dir_str}"

    done < <(find "${share_root_str}" -mindepth 1 -type d | sort -r)

    # Optionally remove the share root itself when CLEANUP=top
    if [[ "${CLEANUP:-no}" == "top" && -d "${share_root_str}" ]]; then
        if [[ -z "$(ls -A "${share_root_str}" 2>/dev/null)" && ! -f "${share_root_str}/.placeholder" ]]; then
            if ! is_zfs_mountpoint "${share_root_str}"; then
                safe_rmdir "${share_root_str}"
            fi
        fi
    fi

    # Handle empty ZFS sub-datasets — only when CLEANUP_ZFS_DATASETS=yes
    if [[ "${CLEANUP_ZFS_DATASETS:-no}" == "yes" ]] && command -v zfs > /dev/null 2>&1; then
        while IFS=$'\t' read -r ds_str mp_str; do
            # Skip the share root dataset itself unless CLEANUP=top
            if [[ "${mp_str%/}" == "${share_root_str}" ]]; then
                [[ "${CLEANUP:-no}" == "top" ]] || continue
            fi
            [[ -d "${mp_str}" ]] || continue
            [[ -f "${mp_str}/.placeholder" ]] && continue
            local contents_str
            contents_str="$(ls -A "${mp_str}" 2>/dev/null)"
            [[ -n "${contents_str}" ]] && continue
            safe_zfs_destroy "${ds_str}"
        done < <(zfs list -H -o name,mountpoint 2>/dev/null \
                    | awk -v mp="${share_root_str}/" '$2 ~ "^"mp')
    fi
}

# ==========================================================
#  HELPER: RUN USER SCRIPTS
# ==========================================================
run_user_script() {
    local script_path_str="$1"
    if [[ ! -f "${script_path_str}" ]]; then
        log_error "Script not found: ${script_path_str}"
        return 1
    fi
    chmod +x "${script_path_str}" 2>/dev/null || true
    log_debug "Running user script: ${script_path_str}"
    case "${script_path_str}" in
        *.sh|*.bash) bash "${script_path_str}" ;;
        *.php)       /usr/bin/php "${script_path_str}" ;;
        *)           "${script_path_str}" ;;
    esac
}

# ==========================================================
#  SESSION HEADER
# ==========================================================
current_state_str="${STATE_PROCESS}"
start_time_int="$(date +%s)"

plugin_version_str="unknown"
if [[ -f "${PLG_FILE}" ]]; then
    plugin_version_str="$(grep -oP 'version="\K[^"]+' "${PLG_FILE}" | head -n1)"
fi

{
    echo "--------------------------------------------"
    echo "Session started - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Plugin version: ${plugin_version_str}"
} >> "${LAST_RUN_FILE}"
log_debug "Session started. version=${plugin_version_str} move_now=${move_now_bool} dry_run=${DRY_RUN:-no}"

# ==========================================================
#  SESSION END LOGGER
# ==========================================================
log_session_end() {
    log_step "log_session_end"
    if [[ "${moved_anything_bool}" == true ]]; then
        if [[ "${CPU_AND_IO_PRIORITIES:-no}" == "yes" ]]; then
            log_info "Cpu priority: ${CPU_PRIORITY}"
            if [[ "${IO_PRIORITY:-normal}" == "normal" ]]; then
                log_info "I/O priority: normal"
            elif [[ "${IO_CLASS_STR}" == "3" ]]; then
                log_info "I/O priority: idle"
            else
                log_info "I/O priority: best-effort ${IO_LEVEL_STR}"
            fi
        fi
        if [[ -s "${RSYNC_SPEED_FILE}" ]]; then
            local avg_speed_str
            avg_speed_str="$(awk '{sum+=$1;n++} END {if(n>0) printf "%.2f",sum/n; else print 0}' "${RSYNC_SPEED_FILE}")"
            log_info "Average move speed: ${avg_speed_str} MB/s"
            log_debug "Average rsync speed: ${avg_speed_str} MB/s"
        fi
    fi

    local end_time_int duration_int
    end_time_int="$(date +%s)"
    duration_int=$(( end_time_int - start_time_int ))
    local duration_str
    if (( duration_int < 60 )); then
        duration_str="${duration_int}s"
    elif (( duration_int < 3600 )); then
        duration_str="$((duration_int / 60))m $((duration_int % 60))s"
    else
        duration_str="$((duration_int / 3600))h $(((duration_int % 3600) / 60))m $((duration_int % 60))s"
    fi

    log_info "Duration: ${duration_str}"
    log_info "Session finished - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info ""
    log_debug "Session ended. duration=${duration_str} moved=${moved_anything_bool} state=${current_state_str}"
}

# ==========================================================
#  PARITY GUARD
# ==========================================================
log_step "Parity check guard"
if [[ "${ALLOW_DURING_PARITY:-no}" == "no" && "${move_now_bool}" == false ]]; then
    if grep -Eq 'mdResync="([1-9][0-9]*)"' "${ARRAY_STATE_FILE}" 2>/dev/null; then
        set_status "Check If Parity Is In Progress"
        log_info "Parity check in progress — skipping"
        log_debug "Parity check detected. Exiting."
        log_session_end
        cleanup 0
    fi
fi

# ==========================================================
#  FILTERS
# ==========================================================
age_filter_bool=false
size_filter_bool=false

log_step "Applying filters"
set_status "Applying Filters"
if [[ "${AGE_BASED_FILTER:-no}" == "yes" && "${AGE_DAYS:-0}" -gt 0 ]]; then
    age_filter_bool=true
    log_debug "Age filter enabled: ${AGE_DAYS} days"
fi
if [[ "${SIZE_BASED_FILTER:-no}" == "yes" && "${SIZE_BYTES_INT:-0}" -gt 0 ]]; then
    size_filter_bool=true
    log_debug "Size filter enabled: ${SIZE} ${SIZE_UNIT:-MB} (${SIZE_BYTES_INT} bytes)"
fi

mount_point_str="/mnt/${POOL_NAME:-cache}"

# ==========================================================
#  RSYNC SETUP
# ==========================================================
log_step "Setting up rsync options"
set_status "Prepping Rsync"
rsync_opts_arr=(-aiHAX --numeric-ids --checksum --perms --owner --group --info=progress2)
if [[ "${DRY_RUN:-no}" == "yes" ]]; then
    rsync_opts_arr+=(--dry-run)
    log_debug "Rsync dry-run flag added"
else
    rsync_opts_arr+=(--remove-source-files)
fi
log_debug "rsync_opts_arr=(${rsync_opts_arr[*]})"

# ==========================================================
#  POOL USAGE CHECK
# ==========================================================
log_step "Pool usage check"
set_status "Checking Usage"
used_pct_int=0

if [[ "${DRY_RUN:-no}" != "yes" ]]; then
    local_pool_name_str="$(basename "${mount_point_str}")"
    zfs_cap_str="$(zpool list -H -o name,cap 2>/dev/null \
        | awk -v pool="${local_pool_name_str}" '$1==pool{gsub("%","",$2);print $2}')"
    if [[ -n "${zfs_cap_str}" ]]; then
        used_pct_int="${zfs_cap_str}"
        log_debug "ZFS pool usage: ${used_pct_int}%"
    else
        used_pct_int="$(df -h --output=pcent "${mount_point_str}" 2>/dev/null \
            | awk 'NR==2{gsub("%","");print}' || echo "")"
        log_debug "df pool usage: ${used_pct_int}%"
    fi

    if [[ -z "${used_pct_int}" ]]; then
        log_warn "${mount_point_str} usage not detected — nothing to do"
        log_session_end
        cleanup 0
    fi

    log_info "${POOL_NAME:-cache} usage:${used_pct_int}% Threshold:${THRESHOLD:-0}% Stop Threshold:${STOP_THRESHOLD:-0}%"

    if (( used_pct_int <= ${THRESHOLD:-0} )); then
        log_info "Usage below threshold — nothing to do"
        log_debug "Usage ${used_pct_int}% <= threshold ${THRESHOLD:-0}%. Exiting."
        log_session_end
        cleanup 0
    fi

    if [[ "${STOP_THRESHOLD:-0}" -gt 0 ]] && (( used_pct_int <= ${STOP_THRESHOLD} )); then
        log_info "Usage already below stop threshold:${STOP_THRESHOLD}% — skipping moves"
        log_debug "Pre-move stop threshold triggered: ${used_pct_int}% <= ${STOP_THRESHOLD}%"
        log_session_end
        cleanup 0
    fi
fi

# ==========================================================
#  STATUS: STARTING
# ==========================================================
if [[ "${DRY_RUN:-no}" == "yes" ]]; then
    set_status "Dry Run: Simulating Moves"
    log_info "Dry Run: Simulating Moves"
else
    set_status "Starting Move Process"
    log_info "Starting move process"
fi

# ==========================================================
#  PRE-MOVE SCRIPT
# ==========================================================
if [[ "${PRE_AND_POST_SCRIPTS:-no}" == "yes" && -n "${PRE_SCRIPT:-}" ]]; then
    log_step "Running pre-move script: ${PRE_SCRIPT}"
    log_info "Running pre-move script: ${PRE_SCRIPT}"
    if run_user_script "${PRE_SCRIPT}" >> "${LAST_RUN_FILE}" 2>&1; then
        log_info "Pre-move script completed successfully"
        log_debug "Pre-move script OK: ${PRE_SCRIPT}"
    else
        log_error "Pre-move script failed: ${PRE_SCRIPT}"
    fi
fi

# ==========================================================
#  LOG ACTIVE FILTERS
# ==========================================================
filters_active_bool=false
for flag_str in "${HIDDEN_FILTER:-no}" "${SIZE_BASED_FILTER:-no}" \
                "${AGE_BASED_FILTER:-no}" "${EXCLUSIONS:-no}"; do
    [[ "${flag_str}" == "yes" ]] && { filters_active_bool=true; break; }
done

if [[ "${filters_active_bool}" == true ]]; then
    {
        echo "***************** Filters Used *****************"
        [[ "${HIDDEN_FILTER:-no}"      == "yes" ]] && echo "Hidden Filter Enabled"
        [[ "${SIZE_BASED_FILTER:-no}"  == "yes" ]] && echo "Size Based Filter Enabled (${SIZE:-0} ${SIZE_UNIT:-MB})"
        [[ "${AGE_BASED_FILTER:-no}"   == "yes" ]] && echo "Age Based Filter Enabled (${AGE_DAYS:-0} days)"
        [[ "${EXCLUSIONS:-no}" == "yes" ]] && echo "Exclusions Enabled"
        echo "***************** Filters Used *****************"
    } >> "${LAST_RUN_FILE}"
    log_debug "Filters active: hidden=${HIDDEN_FILTER:-no} size=${SIZE_BASED_FILTER:-no} age=${AGE_BASED_FILTER:-no} excl=${EXCLUSIONS:-no}"
fi

# ==========================================================
#  LOAD EXCLUSIONS
# ==========================================================
excluded_paths_arr=()
if [[ "${EXCLUSIONS:-no}" == "yes" && -f "${EXCLUSIONS_FILE}" ]]; then
    while IFS= read -r line_str; do
        line_str="$(echo "${line_str}" | sed 's/\r//g' | xargs)"
        [[ -z "${line_str}" || "${line_str}" =~ ^# ]] && continue
        excluded_paths_arr+=("${line_str}")
    done < "${EXCLUSIONS_FILE}"
    log_debug "Loaded ${#excluded_paths_arr[@]} exclusion(s)"
fi

# ==========================================================
#  MAIN MOVE LOOP
# ==========================================================
log_step "Starting main move loop"

for cfg_file_str in "${SHARE_CFG_DIR}"/*.cfg; do
    [[ -f "${cfg_file_str}" ]] || continue
    share_name_str="${cfg_file_str##*/}"
    share_name_str="${share_name_str%.cfg}"

    use_cache_str="$(grep -E '^shareUseCache=' "${cfg_file_str}" \
        | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs | tr '[:upper:]' '[:lower:]' || true)"
    pool1_str="$(grep -E '^shareCachePool='  "${cfg_file_str}" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs || true)"
    pool2_str="$(grep -E '^shareCachePool2=' "${cfg_file_str}" | cut -d'=' -f2- | tr -d '"' | tr -d '\r' | xargs || true)"

    [[ -z "${use_cache_str}" || -z "${pool1_str}" ]] && continue
    if [[ "${pool1_str}" != "${POOL_NAME:-cache}" && "${pool2_str}" != "${POOL_NAME:-cache}" ]]; then
        continue
    fi

    src_str=""
    dst_str=""
    if [[ -z "${pool2_str}" ]]; then
        if   [[ "${use_cache_str}" == "yes"    ]]; then src_str="/mnt/${pool1_str}/${share_name_str}"; dst_str="/mnt/user0/${share_name_str}"
        elif [[ "${use_cache_str}" == "prefer" ]]; then src_str="/mnt/user0/${share_name_str}";        dst_str="/mnt/${pool1_str}/${share_name_str}"
        else continue; fi
    else
        case "${use_cache_str}" in
            yes)    src_str="/mnt/${pool1_str}/${share_name_str}"; dst_str="/mnt/${pool2_str}/${share_name_str}" ;;
            prefer) src_str="/mnt/${pool2_str}/${share_name_str}"; dst_str="/mnt/${pool1_str}/${share_name_str}" ;;
            *) continue ;;
        esac
    fi

    [[ ! -d "${src_str}" ]] && continue

    if [[ "${src_str}" == /mnt/user0/* ]]; then
        log_info "Skipping ${share_name_str} (array → pool moves not allowed)"
        log_debug "Skipping ${share_name_str}: src is /mnt/user0 (not allowed)"
        continue
    fi

    log_debug "Processing share: ${share_name_str} src=${src_str} dst=${dst_str}"

    # ── COLLECT FILES ──────────────────────────────────────────────────────────
    mapfile -t all_items_arr < <(cd "${src_str}" && find . -type f -printf '%P\n' | LC_ALL=C sort)
    log_debug "Share ${share_name_str}: ${#all_items_arr[@]} total files found"

    eligible_items_arr=()
    for relpath_str in "${all_items_arr[@]}"; do
        [[ -z "${relpath_str}" ]] && continue
        srcfile_str="${src_str}/${relpath_str}"

        # Hidden filter
        if [[ "${HIDDEN_FILTER:-no}" == "yes" && "$(basename "${srcfile_str}")" == .* ]]; then
            (( skipped_hidden_int++ )) || true
            log_debug "Hidden filter skip: ${srcfile_str}"
            continue
        fi

        # Size filter
        if [[ "${size_filter_bool}" == true ]]; then
            filesize_int="$(stat -c%s "${srcfile_str}" 2>/dev/null || echo 0)"
            if (( filesize_int < SIZE_BYTES_INT )); then
                (( skipped_size_int++ )) || true
                log_debug "Size filter skip (${filesize_int}B < ${SIZE_BYTES_INT}B): ${srcfile_str}"
                continue
            fi
        fi

        # Age filter
        if [[ "${age_filter_bool}" == true ]]; then
            file_age_days_int="$(( ( $(date +%s) - $(stat -c %Y "${srcfile_str}" 2>/dev/null || echo 0) ) / 86400 ))"
            if (( file_age_days_int < ${AGE_DAYS:-0} )); then
                (( skipped_age_int++ )) || true
                log_debug "Age filter skip (${file_age_days_int}d < ${AGE_DAYS}d): ${srcfile_str}"
                continue
            fi
        fi

        # Exclusions
        skip_file_bool=false
        if [[ "${EXCLUSIONS:-no}" == "yes" && ${#excluded_paths_arr[@]} -gt 0 ]]; then
            for ex_str in "${excluded_paths_arr[@]}"; do
                [[ -d "${ex_str}" ]] && ex_str="${ex_str%/}/"
                if [[ "${srcfile_str}" == "${ex_str}"* ]]; then
                    skip_file_bool=true
                    log_debug "Exclusion skip: ${srcfile_str} (rule: ${ex_str})"
                    break
                fi
            done
        fi
        if [[ "${skip_file_bool}" == true ]]; then
            (( skipped_excl_int++ )) || true
            continue
        fi

        # In-use check
        if ! wait_for_release "${srcfile_str}"; then
            grep -qxF "${srcfile_str}" "${IN_USE_FILE}" 2>/dev/null \
                || echo "${srcfile_str}" >> "${IN_USE_FILE}"
            continue
        fi

        eligible_items_arr+=("${relpath_str}")
    done

    file_count_int="${#eligible_items_arr[@]}"
    log_debug "Share ${share_name_str}: ${file_count_int} eligible files after filters"
    (( file_count_int == 0 )) && continue

    # ── PRE-MOVE TRIGGERS (first eligible share) ────────────────────────────────
    if [[ "${pre_move_done_str}" != "yes" ]]; then

        # Start notification
        if [[ "${NOTIFICATIONS:-no}" == "yes" && "${sent_start_notif_str}" != "yes" ]]; then
            notif_title_str="Session started"
            notif_msg_str="automover is beginning to move eligible files."
            if [[ -n "${WEBHOOK_URL:-}" ]]; then
                send_discord_message "${notif_title_str}" "${notif_msg_str}" 16776960
            else
                unraid_notify "${notif_title_str}" "${notif_msg_str}" "normal" 0
            fi
            sent_start_notif_str="yes"
            log_debug "Start notification sent"
        fi

        # Turbo write
        if [[ "${FORCE_TURBO_WRITE:-no}" == "yes" && "${DRY_RUN:-no}" != "yes" ]]; then
            set_status "Enabling Turbo Write"
            turbo_prev_str="$(grep -Po 'md_write_method="\K[^"]+' "${ARRAY_STATE_FILE}" 2>/dev/null || echo "")"
            echo "${turbo_prev_str}" > /tmp/prev_write_method
            logger "Force turbo write on"
            /usr/local/sbin/mdcmd set md_write_method 1
            log_info "Enabled reconstructive write mode (turbo write)"
            log_debug "Turbo write enabled. prev=${turbo_prev_str}"
            turbo_write_enabled_bool=true
        fi

        # qBittorrent pause
        if [[ "${QBITTORRENT_MOVE_SCRIPT:-no}" == "yes" && "${DRY_RUN:-no}" != "yes" ]]; then
            skip_qbit_bool=false
            IFS=',' read -ra stop_list_arr <<< "${STOP_CONTAINERS:-}"
            for c_str in "${stop_list_arr[@]}"; do
                c_str="$(echo "${c_str}" | xargs)"
                [[ -z "${c_str}" ]] && continue
                repo_str="$(docker inspect --format '{{.Config.Image}}' "${c_str}" 2>/dev/null \
                    | tr '[:upper:]' '[:lower:]' || echo "")"
                if [[ "${repo_str}" == *qbittorrent* ]]; then
                    skip_qbit_bool=true
                    log_info "qBittorrent container in stop list — skipping qBittorrent pause/resume"
                    log_debug "qBittorrent skip: container ${c_str} uses qbittorrent image"
                    break
                fi
            done

            if [[ "${skip_qbit_bool}" == false ]]; then
                if docker ps --format '{{.Names}}' | grep -qi '^qbittorrent$'; then
                    if ! python3 -m pip show qbittorrent-api > /dev/null 2>&1; then
                        log_info "Installing qbittorrent-api"
                        command -v pip3 > /dev/null 2>&1 && pip3 install qbittorrent-api -q > /dev/null 2>&1
                    fi
                    set_status "Pausing Torrents"
                    run_qbit_script pause
                    qbit_paused_bool=true
                    sleep 2
                    log_debug "qBittorrent paused, sleeping 2s for handle release"
                else
                    skip_qbit_bool=true
                    log_info "qBittorrent container not running — skipping qBittorrent pause/resume"
                    log_debug "qBittorrent container not found in docker ps"
                fi
            fi
        fi

        # Stop containers (after qbit pause)
        manage_containers stop

        # Clear files moved log
        [[ -f "${FILES_MOVED_LOG}" ]] && rm -f "${FILES_MOVED_LOG}"
        log_debug "Files moved log cleared"
        pre_move_done_str="yes"
    fi

    # ── MOVE FILES ─────────────────────────────────────────────────────────────
    log_info "Starting move of ${file_count_int} file(s) for share: ${share_name_str}"
    set_status "Moving Files For Share: ${share_name_str}"
    log_debug "Moving share: ${share_name_str} (${file_count_int} files) src=${src_str} dst=${dst_str}"

    printf '%s\n' "${eligible_items_arr[@]}" > "${ELIGIBLE_TMP_FILE}"

    file_count_moved_int=0
    src_owner_str="$(stat -c "%u" "${src_str}")"
    src_group_str="$(stat -c "%g" "${src_str}")"
    src_perms_str="$(stat -c "%a" "${src_str}")"

    if [[ ! -d "${dst_str}" ]]; then
        mkdir -p "${dst_str}"
    fi
    chown "${src_owner_str}:${src_group_str}" "${dst_str}"
    chmod "${src_perms_str}" "${dst_str}"

    copy_empty_dirs "${src_str}" "${dst_str}"

    while IFS= read -r relpath_str; do
        [[ -z "${relpath_str}" ]] && continue
        srcfile_str="${src_str}/${relpath_str}"
        dstfile_str="${dst_str}/${relpath_str}"
        dstdir_str="$(dirname "${dstfile_str}")"

        # Re-check exclusions
        skip_file_bool=false
        if [[ "${EXCLUSIONS:-no}" == "yes" && ${#excluded_paths_arr[@]} -gt 0 ]]; then
            for ex_str in "${excluded_paths_arr[@]}"; do
                [[ -d "${ex_str}" ]] && ex_str="${ex_str%/}/"
                if [[ "${srcfile_str}" == "${ex_str}"* ]]; then
                    skip_file_bool=true
                    break
                fi
            done
        fi
        [[ "${skip_file_bool}" == true ]] && continue

        # Re-check in-use
        if ! wait_for_release "${srcfile_str}"; then
            grep -qxF "${srcfile_str}" "${IN_USE_FILE}" 2>/dev/null \
                || echo "${srcfile_str}" >> "${IN_USE_FILE}"
            continue
        fi

        if [[ "${DRY_RUN:-no}" != "yes" ]]; then
            mkdir -p "${dstdir_str}"
            chown "${src_owner_str}:${src_group_str}" "${dstdir_str}"
            chmod "${src_perms_str}" "${dstdir_str}"
        fi

        # Stop threshold check (per-file, ZFS-aware)
        if [[ "${move_now_bool}" == false && "${DRY_RUN:-no}" != "yes" && "${STOP_THRESHOLD:-0}" -gt 0 ]]; then
            cur_pool_name_str="$(basename "${mount_point_str}")"
            cur_zfs_cap_str="$(zpool list -H -o name,cap 2>/dev/null \
                | awk -v pool="${cur_pool_name_str}" '$1==pool{gsub("%","",$2);print $2}')"
            if [[ -n "${cur_zfs_cap_str}" ]]; then
                final_used_int="${cur_zfs_cap_str}"
            else
                final_used_int="$(df --output=pcent "${mount_point_str}" \
                    | awk 'NR==2{gsub("%","");print}' || echo "")"
            fi
            if [[ -n "${final_used_int}" ]] && (( final_used_int <= ${STOP_THRESHOLD} )); then
                log_info "Move stopped — pool usage reached stop threshold: ${final_used_int}% (<= ${STOP_THRESHOLD}%)"
                log_debug "Stop threshold triggered: ${final_used_int}% <= ${STOP_THRESHOLD}%"
                stop_triggered_bool=true
                break
            fi
        fi

        # Run rsync
        log_debug "rsync: ${srcfile_str} → ${dstdir_str}/"
        if (( ${#rsync_wrapper_arr[@]} > 0 )); then
            "${rsync_wrapper_arr[@]}" rsync "${rsync_opts_arr[@]}" "${srcfile_str}" "${dstdir_str}/" 2>&1 \
            | awk '/MB\/s/{for(i=1;i<=NF;i++){if($i~/MB\/s/){gsub(/MB\/s/,"",$i);print $i;fflush()}}}' \
            >> "${RSYNC_SPEED_FILE}" || true
        else
            rsync "${rsync_opts_arr[@]}" "${srcfile_str}" "${dstdir_str}/" 2>&1 \
            | awk '/MB\/s/{for(i=1;i<=NF;i++){if($i~/MB\/s/){gsub(/MB\/s/,"",$i);print $i;fflush()}}}' \
            >> "${RSYNC_SPEED_FILE}" || true
        fi

        sync
        sleep 1

        if [[ "${DRY_RUN:-no}" == "yes" ]]; then
            echo "${srcfile_str} -> ${dstfile_str}" >> "${FILES_MOVED_LOG}"
            log_debug "DRY-RUN logged: ${srcfile_str} → ${dstfile_str}"
            # Per-file parent cleanup — only when CLEANUP is enabled (dry-run = log only)
            [[ "${CLEANUP:-no}" != "no" ]] && cleanup_empty_parents "${srcfile_str}" "${src_str}"
        else
            if [[ -f "${dstfile_str}" ]]; then
                (( file_count_moved_int++ )) || true
                echo "${srcfile_str} -> ${dstfile_str}" >> "${FILES_MOVED_LOG}"
                log_debug "Moved: ${srcfile_str} → ${dstfile_str}"
                # Per-file parent cleanup — only when CLEANUP is enabled
                [[ "${CLEANUP:-no}" != "no" ]] && cleanup_empty_parents "${srcfile_str}" "${src_str}"
            else
                log_warn "File not found at destination after rsync: ${dstfile_str}"
            fi
        fi

        # Check for stop request after each file
        if [[ "${_stop_requested_bool}" == true ]]; then
            log_debug "Stop flag detected after file move — breaking move loop"
            stop_triggered_bool=true
            break
        fi
    done < "${ELIGIBLE_TMP_FILE}"
    rm -f "${ELIGIBLE_TMP_FILE}"

    log_info "Finished move of ${file_count_moved_int} file(s) for share: ${share_name_str}"
    log_debug "Share ${share_name_str} done: moved=${file_count_moved_int} stop_triggered=${stop_triggered_bool}"

    if (( file_count_moved_int > 0 )); then
        moved_anything_bool=true
        echo "${share_name_str}" >> "${MOVED_SHARES_FILE}"
        echo "${src_str}" >> "${CLEANUP_SOURCES_FILE}"
    fi

    [[ "${stop_triggered_bool}" == true ]] && break
done

# ==========================================================
#  PRINT SKIP TOTALS
# ==========================================================
{
    [[ "${HIDDEN_FILTER:-no}"      == "yes" ]] && echo "Skipped due to hidden filter: ${skipped_hidden_int} file(s)"
    [[ "${SIZE_BASED_FILTER:-no}"  == "yes" ]] && echo "Skipped due to size filter: ${skipped_size_int} file(s)"
    [[ "${AGE_BASED_FILTER:-no}"   == "yes" ]] && echo "Skipped due to age filter: ${skipped_age_int} file(s)"
    [[ "${EXCLUSIONS:-no}" == "yes" ]] && echo "Skipped due to exclusions: ${skipped_excl_int} file(s)"
} >> "${LAST_RUN_FILE}"
log_debug "Skip totals: hidden=${skipped_hidden_int} size=${skipped_size_int} age=${skipped_age_int} excl=${skipped_excl_int}"

# ==========================================================
#  NO FILES MOVED / NO PRE-MOVE ACTIONS TAKEN
# ==========================================================
if [[ "${pre_move_done_str}" != "yes" && "${moved_anything_bool}" == false ]]; then
    log_info "No shares had files to move"
    log_debug "No eligible files found across all shares"
    [[ "${FORCE_TURBO_WRITE:-no}" == "yes" ]] && log_info "No files moved — skipping enabling reconstructive write (turbo write)"
    [[ -n "${STOP_CONTAINERS:-}" ]]                         && log_info "No files moved — skipping stopping of containers"
    [[ "${QBITTORRENT_MOVE_SCRIPT:-no}" == "yes" ]]         && log_info "No files moved — skipping pausing of qbittorrent torrents"
fi

# ==========================================================
#  IN-USE FILE SUMMARY
# ==========================================================
if [[ -s "${IN_USE_FILE}" ]]; then
    set_status "In-Use Summary"
    sort -u "${IN_USE_FILE}" -o "${IN_USE_FILE}"
    inuse_count_int="$(wc -l < "${IN_USE_FILE}")"
    log_info "Skipped ${inuse_count_int} in-use file(s)"
    log_debug "In-use files: ${inuse_count_int}"
else
    log_info "No in-use files detected during move"
    log_debug "No in-use files"
fi

# ==========================================================
#  RESUME QBITTORRENT
# ==========================================================
if [[ "${qbit_paused_bool}" == true && "${QBITTORRENT_MOVE_SCRIPT:-no}" == "yes" && "${skip_qbit_bool}" == false ]]; then
    set_status "Resuming Torrents"
    log_debug "Waiting 10s before resuming qBittorrent"
    sleep 10
    run_qbit_script resume
fi

# ==========================================================
#  START CONTAINERS
# ==========================================================
manage_containers start

# ==========================================================
#  FINISHED MOVE PROCESS
# ==========================================================
[[ "${DRY_RUN:-no}" != "yes" ]] && log_info "Finished move process"

# ==========================================================
#  CLEANUP EMPTY FOLDERS
#  Gated on CLEANUP != no — nothing here runs when CLEANUP=no.
#
#  CLEANUP values:
#    no  — disabled entirely
#    yes — remove empty subdirectories, never the share root
#    top — same as yes, but also removes the share root if empty
#
#  CLEANUP_ZFS_DATASETS=yes additionally destroys empty ZFS sub-datasets.
#
#  Phase 1 — safety-net sweep of share source dirs that had files moved.
#             Catches anything the per-file cleanup_empty_parents() may have
#             missed (e.g. stop_triggered fired mid-share).
#  Phase 2 — full depth-first sweep of every share dir on the pool.
#
#  Protections on every directory checked:
#    - Share root only removed when CLEANUP=top
#    - Dirs containing a .placeholder file are skipped
#    - ZFS mountpoints are skipped (unless CLEANUP_ZFS_DATASETS=yes for datasets)
#    - Protected shares (appdata, system, domains, isos) are skipped
#    - Shares without a secondary pool configured are skipped
#    - Dry-run is fully supported (logs only, no deletes)
# ==========================================================
current_state_str="${STATE_COMPLETE}"

if [[ "${CLEANUP:-no}" != "no" && "${moved_anything_bool}" == true ]]; then
    log_step "Cleaning up empty folders (CLEANUP=${CLEANUP:-no})"
    set_status "Cleaning Up"

    # ── Phase 1: safety-net sweep of moved share sources ─────────────────────
    if [[ -s "${CLEANUP_SOURCES_FILE}" ]]; then
        while IFS= read -r src_path_str; do
            [[ -z "${src_path_str}" || ! -d "${src_path_str}" ]] && continue
            local_share_str="$(basename "${src_path_str}")"

            if ! _cleanup_share_ok "${local_share_str}"; then
                log_debug "Cleanup safety-net: skipping protected/ineligible share: ${local_share_str}"
                continue
            fi

            log_debug "Cleanup safety-net sweep: ${src_path_str}"
            _sweep_empty_dirs "${src_path_str}"
        done < <(sort -u "${CLEANUP_SOURCES_FILE}")
        log_debug "Cleanup safety-net pass complete"
    fi

    # ── Phase 2: full pool-wide sweep ─────────────────────────────────────────
    local_pool_path_str="/mnt/${POOL_NAME:-cache}"

    if guard_pool_path "${POOL_NAME:-cache}"; then
        for share_dir_str in "${local_pool_path_str}"/*/; do
            [[ -d "${share_dir_str}" ]] || continue
            share_dir_str="${share_dir_str%/}"
            local_share_name_str="$(basename "${share_dir_str}")"

            if ! _cleanup_share_ok "${local_share_name_str}"; then
                log_debug "Pool-wide cleanup: skipping protected/ineligible share: ${local_share_name_str}"
                continue
            fi

            log_debug "Pool-wide cleanup sweep: ${share_dir_str}"
            _sweep_empty_dirs "${share_dir_str}"
        done
        log_info "Cleanup of empty folders finished"
        log_debug "Pool-wide cleanup complete: ${local_pool_path_str}"
    else
        log_error "Cleanup aborted by pool guard: ${POOL_NAME:-cache}"
    fi
fi

# ==========================================================
#  JDUPES
# ==========================================================
if [[ "${JDUPES:-no}" == "yes" && "${DRY_RUN:-no}" != "yes" && "${moved_anything_bool}" == true ]]; then
    log_step "Running jdupes"
    set_status "Running Jdupes"
    if command -v jdupes > /dev/null 2>&1; then
        temp_list_str="${TMP_LOGS_DIR}/jdupes_list.txt"
        hash_dir_str="${HASH_LOCATION:-/mnt/user/appdata}"
        hash_db_str="${hash_dir_str}/jdupes_hash_database.db"

        mkdir -p "${hash_dir_str}"
        chmod 777 "${hash_dir_str}"

        if [[ ! -f "${hash_db_str}" ]]; then
            touch "${hash_db_str}"
            chmod 666 "${hash_db_str}"
            log_info "Creating jdupes hash database at ${hash_dir_str}"
            log_debug "Created jdupes DB: ${hash_db_str}"
        else
            log_info "Using existing jdupes database: ${hash_db_str}"
        fi

        grep -E -- ' -> ' "${FILES_MOVED_LOG}" \
            | awk -F'->' '{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2}' > "${temp_list_str}" || true

        if [[ ! -s "${temp_list_str}" ]]; then
            log_info "No moved files found — skipping jdupes step"
            log_debug "jdupes: temp list empty"
        else
            mapfile -t jdupes_shares_arr < <(awk -F'/' '$2=="mnt"&&$3=="user0"&&$4!=""{print $4}' \
                "${temp_list_str}" | LC_ALL=C sort -u)
            jdupes_excl_arr=("appdata" "system" "domains" "isos")

            for share_str in "${jdupes_shares_arr[@]}"; do
                skip_bool=false
                for ex_str in "${jdupes_excl_arr[@]}"; do
                    [[ "${share_str}" == "${ex_str}" ]] && { skip_bool=true; break; }
                done
                if [[ "${skip_bool}" == true ]]; then
                    log_info "Jdupes — Skipping excluded share: ${share_str}"
                    log_debug "jdupes skip excluded share: ${share_str}"
                    continue
                fi

                share_path_str="/mnt/user/${share_str}"
                if [[ ! -d "${share_path_str}" ]]; then
                    log_info "Jdupes — Skipping missing path: ${share_path_str}"
                    log_debug "jdupes skip missing path: ${share_path_str}"
                    continue
                fi

                log_info "Jdupes processing share ${share_str}"
                log_debug "jdupes running on: ${share_path_str}"
                /usr/bin/jdupes -rLX onlyext:mp4,mkv,avi -y "${hash_db_str}" "${share_path_str}" 2>&1 \
                | grep -v -E \
                    -e "^Creating a new hash database" \
                    -e "^[[:space:]]*AT YOUR OWN RISK" \
                    -e "^[[:space:]]*yet and basic" \
                    -e "^[[:space:]]*but there are LOTS OF QUIRKS" \
                    -e "^WARNING: THE HASH DATABASE FEATURE IS UNDER HEAVY DEVELOPMENT" \
                >> "${LAST_RUN_FILE}" || true
                log_info "Completed jdupes step for ${share_str}"
                log_debug "jdupes complete for share: ${share_str}"
            done
        fi
    else
        log_info "jdupes not installed — skipping jdupes step"
        log_debug "jdupes binary not found"
    fi
elif [[ "${JDUPES:-no}" == "yes" ]]; then
    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "Dry run active — skipping jdupes step"
    elif [[ "${moved_anything_bool}" == false ]]; then
        log_info "No files moved — skipping jdupes step"
    fi
fi

[[ "${DRY_RUN:-no}" == "yes" ]] && log_info "Dry run active — skipping sending notifications"

# ==========================================================
#  RESTORE TURBO WRITE
# ==========================================================
if [[ "${FORCE_TURBO_WRITE:-no}" == "yes" && "${moved_anything_bool}" == true ]]; then
    set_status "Restoring Turbo Write Setting"
    log_step "Restoring turbo write setting"
    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "Dry run active — skipping restoring md_write_method to previous value"
        log_debug "DRY-RUN: skip turbo write restore"
    else
        turbo_mode_str="$(grep -Po 'md_write_method="\K[^"]+' "${ARRAY_STATE_FILE}" 2>/dev/null || echo "")"
        if [[ -n "${turbo_mode_str}" ]]; then
            case "${turbo_mode_str}" in
                0)    mode_name_str="read/modify/write" ;;
                1)    mode_name_str="reconstruct write" ;;
                auto) mode_name_str="auto" ;;
                *)    mode_name_str="unknown (${turbo_mode_str})" ;;
            esac
            logger "Restoring md_write_method to previous value: ${mode_name_str}"
            /usr/local/sbin/mdcmd set md_write_method "${turbo_mode_str}"
            log_info "Restored md_write_method to previous value: ${mode_name_str}"
            log_debug "Turbo write restored: ${mode_name_str} (${turbo_mode_str})"
        fi
    fi
fi

# ==========================================================
#  FILES MOVED LOG FINAL HANDLING
# ==========================================================
mkdir -p "$(dirname "${FILES_MOVED_LOG}")"

if [[ "${DRY_RUN:-no}" != "yes" ]]; then
    if [[ "${moved_anything_bool}" == true && -s "${FILES_MOVED_LOG}" ]]; then
        cp -f "${FILES_MOVED_LOG}" "${TMP_DIR}/files_moved_prev.log"
        log_debug "Files moved log backed up to files_moved_prev.log"
    else
        : > "${FILES_MOVED_LOG}"
        echo "No files moved for this run" >> "${FILES_MOVED_LOG}"
        log_debug "No files moved — reset files_moved.log"
    fi
fi

# ==========================================================
#  POST-MOVE SHARE CONFIG CLEANUP
# ==========================================================
if [[ "${moved_anything_bool}" == true && "${CLEANUP:-no}" != "no" ]]; then
    set_status "Checking Share Existence"
    log_debug "Checking share config existence post-move"
    while IFS= read -r cleanup_share_str; do
        [[ -z "${cleanup_share_str}" ]] && continue
        share_cfg_str="${SHARE_CFG_DIR}/${cleanup_share_str}.cfg"
        [[ -f "${share_cfg_str}" ]] || continue
        found_bool=false
        for mount_str in /mnt/*; do
            [[ -d "${mount_str}/${cleanup_share_str}" ]] && { found_bool=true; break; }
        done
        if [[ "${found_bool}" == false ]]; then
            rm -f "${share_cfg_str}"
            log_debug "Removed orphaned share config: ${share_cfg_str}"
        fi
    done < "${MOVED_SHARES_FILE}"
fi

# ==========================================================
#  SSD TRIM
# ==========================================================
if [[ "${SSD_TRIM:-no}" == "yes" && "${DRY_RUN:-no}" != "yes" && "${moved_anything_bool}" == true ]]; then
    log_step "Running SSD trim"
    set_status "Running ssd trim"
    if /usr/local/emhttp/plugins/dynamix/scripts/ssd_trim cron > /dev/null 2>&1; then
        log_info "Ssd trim finished"
        log_debug "SSD trim completed successfully"
    else
        log_error "Ssd trim failed"
    fi
elif [[ "${SSD_TRIM:-no}" == "yes" && "${DRY_RUN:-no}" == "yes" ]]; then
    log_info "Dry run active — skipping ssd trim"
    log_debug "DRY-RUN: skip SSD trim"
fi

# ==========================================================
#  SUMMARY NOTIFICATION + POST SCRIPT + DONE SIGNAL
# ==========================================================
if [[ "${_stop_requested_bool}" == true ]]; then
    log_info "Move stopped by user request"
    log_debug "Stop requested — skipping notifications and post-script"
else
    send_summary_notification

    if [[ "${PRE_AND_POST_SCRIPTS:-no}" == "yes" && -n "${POST_SCRIPT:-}" ]]; then
        log_step "Running post-move script: ${POST_SCRIPT}"
        log_info "Running post-move script: ${POST_SCRIPT}"
        if run_user_script "${POST_SCRIPT}" >> "${LAST_RUN_FILE}" 2>&1; then
            log_info "Post-move script completed successfully"
            log_debug "Post-move script OK: ${POST_SCRIPT}"
        else
            log_error "Post-move script failed: ${POST_SCRIPT}"
        fi
    fi
fi

log_session_end

mkdir -p "${TMP_LOGS_DIR}"
echo "done" > "${DONE_FILE}"
log_debug "Done signal written to ${DONE_FILE}"

# ==========================================================
#  EXIT
# ==========================================================
current_state_str="${STATE_COMPLETE}"
log_debug "Script completed successfully. state=${STATE_COMPLETE}"
cleanup 0