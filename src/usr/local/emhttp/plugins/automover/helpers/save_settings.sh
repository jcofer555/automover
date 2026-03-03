#!/bin/bash

readonly CONFIG="/boot/config/plugins/automover/settings.cfg"
readonly CONFIG_TMP="${CONFIG}.tmp"

# ------------------------------------------------------------------------------
# main() — explicit entrypoint, args alphabetized to match save_settings.php
# ------------------------------------------------------------------------------
main() {
    mkdir -p "$(dirname "$CONFIG")" || { echo '{"status":"error","message":"Failed to create config directory"}'; exit 1; }

    local AGE_BASED_FILTER="${1:-no}"
    local AGE_DAYS="${2:-1}"
    local ALLOW_DURING_PARITY="${3:-no}"
    local AUTOSTART="${4:-no}"
    local CONTAINER_NAMES_RAW="${5:-}"
    local CRON_EXPRESSION="${6:-}"
    local CRON_MODE="${7:-minutes}"
    local CUSTOM_CRON="${8:-}"
    local DAILY_TIME="${9:-}"
    local DRY_RUN="${10:-no}"
    local ENABLE_CLEANUP="${11:-no}"
    local ENABLE_JDUPES="${12:-no}"
    local ENABLE_NOTIFICATIONS="${13:-no}"
    local ENABLE_SCRIPTS="${14:-no}"
    local ENABLE_TRIM="${15:-no}"
    local EXCLUSIONS_ENABLED="${16:-no}"
    local FORCE_RECONSTRUCTIVE_WRITE="${17:-no}"
    local HASH_PATH="${18:-/mnt/user/appdata}"
    local HIDDEN_FILTER="${19:-no}"
    local HOURLY_FREQUENCY="${20:-}"
    local IO_PRIORITY="${21:-normal}"
    local MANUAL_MOVE="${22:-no}"
    local MINUTES_FREQUENCY="${23:-30}"
    local MONTHLY_DAY="${24:-}"
    local MONTHLY_TIME="${25:-}"
    local NOTIFICATION_SERVICE="${26:-}"
    local POOL_NAME="${27:-cache}"
    local POST_SCRIPT="${28:-}"
    local PRE_SCRIPT="${29:-}"
    local PRIORITIES="${30:-no}"
    local PROCESS_PRIORITY="${31:-0}"
    local PUSHOVER_USER_KEY="${32:-}"
    local QBITTORRENT_DAYS_FROM="${33:-0}"
    local QBITTORRENT_DAYS_TO="${34:-2}"
    local QBITTORRENT_HOST="${35:-}"
    local QBITTORRENT_PASSWORD="${36:-}"
    local QBITTORRENT_SCRIPT="${37:-no}"
    local QBITTORRENT_STATUS="${38:-completed}"
    local QBITTORRENT_USERNAME="${39:-}"
    local SIZE_BASED_FILTER="${40:-no}"
    local SIZE_MB="${41:-1}"
    local STOP_ALL_CONTAINERS="${42:-no}"
    local STOP_THRESHOLD="${43:-0}"
    local THRESHOLD="${44:-0}"
    local WEBHOOK_DISCORD="${45:-}"
    local WEBHOOK_GOTIFY="${46:-}"
    local WEBHOOK_NTFY="${47:-}"
    local WEBHOOK_PUSHOVER="${48:-}"
    local WEBHOOK_SLACK="${49:-}"
    local WEEKLY_DAY="${50:-}"
    local WEEKLY_TIME="${51:-}"

    # --------------------------------------------------------------------------
    # Normalize CONTAINER_NAMES
    # --------------------------------------------------------------------------
    local CONTAINER_NAMES=""
    if [[ -n "$CONTAINER_NAMES_RAW" ]]; then
        CONTAINER_NAMES=$(echo "$CONTAINER_NAMES_RAW" | sed 's/, */,/g' | xargs)
    fi

    # --------------------------------------------------------------------------
    # Atomic write — tmp then rename
    # --------------------------------------------------------------------------
    {
        echo "AGE_BASED_FILTER=\"$AGE_BASED_FILTER\""
        echo "AGE_DAYS=\"$AGE_DAYS\""
        echo "ALLOW_DURING_PARITY=\"$ALLOW_DURING_PARITY\""
        echo "AUTOSTART=\"$AUTOSTART\""
        echo "CONTAINER_NAMES=\"$CONTAINER_NAMES\""
        echo "CRON_EXPRESSION=\"$CRON_EXPRESSION\""
        echo "CRON_MODE=\"$CRON_MODE\""
        echo "CUSTOM_CRON=\"$CUSTOM_CRON\""
        echo "DAILY_TIME=\"$DAILY_TIME\""
        echo "DRY_RUN=\"$DRY_RUN\""
        echo "ENABLE_CLEANUP=\"$ENABLE_CLEANUP\""
        echo "ENABLE_JDUPES=\"$ENABLE_JDUPES\""
        echo "ENABLE_NOTIFICATIONS=\"$ENABLE_NOTIFICATIONS\""
        echo "ENABLE_SCRIPTS=\"$ENABLE_SCRIPTS\""
        echo "ENABLE_TRIM=\"$ENABLE_TRIM\""
        echo "EXCLUSIONS_ENABLED=\"$EXCLUSIONS_ENABLED\""
        echo "FORCE_RECONSTRUCTIVE_WRITE=\"$FORCE_RECONSTRUCTIVE_WRITE\""
        echo "HASH_PATH=\"$HASH_PATH\""
        echo "HIDDEN_FILTER=\"$HIDDEN_FILTER\""
        echo "HOURLY_FREQUENCY=\"$HOURLY_FREQUENCY\""
        echo "IO_PRIORITY=\"$IO_PRIORITY\""
        echo "MANUAL_MOVE=\"$MANUAL_MOVE\""
        echo "MINUTES_FREQUENCY=\"$MINUTES_FREQUENCY\""
        echo "MONTHLY_DAY=\"$MONTHLY_DAY\""
        echo "MONTHLY_TIME=\"$MONTHLY_TIME\""
        echo "NOTIFICATION_SERVICE=\"$NOTIFICATION_SERVICE\""
        echo "POOL_NAME=\"$POOL_NAME\""
        echo "POST_SCRIPT=\"$POST_SCRIPT\""
        echo "PRE_SCRIPT=\"$PRE_SCRIPT\""
        echo "PRIORITIES=\"$PRIORITIES\""
        echo "PROCESS_PRIORITY=\"$PROCESS_PRIORITY\""
        echo "PUSHOVER_USER_KEY=\"$PUSHOVER_USER_KEY\""
        echo "QBITTORRENT_DAYS_FROM=\"$QBITTORRENT_DAYS_FROM\""
        echo "QBITTORRENT_DAYS_TO=\"$QBITTORRENT_DAYS_TO\""
        echo "QBITTORRENT_HOST=\"$QBITTORRENT_HOST\""
        echo "QBITTORRENT_PASSWORD=\"$QBITTORRENT_PASSWORD\""
        echo "QBITTORRENT_SCRIPT=\"$QBITTORRENT_SCRIPT\""
        echo "QBITTORRENT_STATUS=\"$QBITTORRENT_STATUS\""
        echo "QBITTORRENT_USERNAME=\"$QBITTORRENT_USERNAME\""
        echo "SIZE_BASED_FILTER=\"$SIZE_BASED_FILTER\""
        echo "SIZE_MB=\"$SIZE_MB\""
        echo "STOP_ALL_CONTAINERS=\"$STOP_ALL_CONTAINERS\""
        echo "STOP_THRESHOLD=\"$STOP_THRESHOLD\""
        echo "THRESHOLD=\"$THRESHOLD\""
        echo "WEBHOOK_DISCORD=\"$WEBHOOK_DISCORD\""
        echo "WEBHOOK_GOTIFY=\"$WEBHOOK_GOTIFY\""
        echo "WEBHOOK_NTFY=\"$WEBHOOK_NTFY\""
        echo "WEBHOOK_PUSHOVER=\"$WEBHOOK_PUSHOVER\""
        echo "WEBHOOK_SLACK=\"$WEBHOOK_SLACK\""
        echo "WEEKLY_DAY=\"$WEEKLY_DAY\""
        echo "WEEKLY_TIME=\"$WEEKLY_TIME\""
    } > "$CONFIG_TMP" || { echo '{"status":"error","message":"Failed to write config"}'; exit 1; }

    mv "$CONFIG_TMP" "$CONFIG" || { echo '{"status":"error","message":"Failed to finalize config"}'; exit 1; }

    echo '{"status":"ok"}'
    exit 0
}

main "$@"