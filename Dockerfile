# syntax=docker/dockerfile:1

FROM alpine:edge

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    jq \
    rclone \
    tzdata

ENV TZ=Asia/Tokyo \
    BACKUP_TIME=03:00 \
    B2_REMOTE_PATH=b2:bucket-name \
    BACKUP_DIR=/var/backups \
    RCLONE_TRANSFERS=4 \
    RCLONE_CHECKERS=8 \
    RCLONE_LOG_LEVEL=INFO


# ---------------------------------------------------------------------------
# Backup script
# ---------------------------------------------------------------------------

RUN cat > /usr/local/bin/run-backup.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

LOG_FILE="$(mktemp)"
START_TIME="$(date +%s)"
PHASE="initializing"

cleanup() {
    rm -f "${LOG_FILE}"
}

notify_discord() {
    local result="$1"
    local exit_code="$2"
    local phase="$3"
    local duration="$4"
    local details="${5:-}"

    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
        echo "[$(date -Iseconds)] WARNING: DISCORD_WEBHOOK_URL is not set"
        return 0
    fi

    local title
    local color

    if [[ "${result}" == "success" ]]; then
        title="✅ Backblaze B2 backup succeeded"
        color=5763719
    else
        title="❌ Backblaze B2 backup failed"
        color=15548997
    fi

    # Discord Embedのサイズを抑える
    if (( ${#details} > 1500 )); then
        details="${details:0:1500}…"
    fi

    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local payload
    payload="$(
        jq -n \
            --arg title "${title}" \
            --arg source "${B2_REMOTE_PATH}" \
            --arg destination "${BACKUP_DIR}" \
            --arg phase "${phase}" \
            --arg duration "${duration}s" \
            --arg exit_code "${exit_code}" \
            --arg details "${details}" \
            --arg timestamp "${timestamp}" \
            --arg hostname "$(hostname)" \
            --argjson color "${color}" \
            '{
                username: "B2 Backup",
                allowed_mentions: {
                    parse: []
                },
                embeds: [
                    {
                        title: $title,
                        color: $color,
                        fields: [
                            {
                                name: "Source",
                                value: ("`" + $source + "`"),
                                inline: false
                            },
                            {
                                name: "Destination",
                                value: ("`" + $destination + "`"),
                                inline: false
                            },
                            {
                                name: "Phase",
                                value: $phase,
                                inline: true
                            },
                            {
                                name: "Duration",
                                value: $duration,
                                inline: true
                            },
                            {
                                name: "Exit code",
                                value: $exit_code,
                                inline: true
                            },
                            {
                                name: "Container",
                                value: $hostname,
                                inline: true
                            }
                        ]
                        +
                        (
                            if $details != "" then
                                [
                                    {
                                        name: "Log",
                                        value: ("```text\n" + $details + "\n```"),
                                        inline: false
                                    }
                                ]
                            else
                                []
                            end
                        ),
                        timestamp: $timestamp
                    }
                ]
            }'
    )"

    if ! curl \
        --fail \
        --silent \
        --show-error \
        --max-time 15 \
        --header 'Content-Type: application/json' \
        --data "${payload}" \
        "${DISCORD_WEBHOOK_URL}" \
        >/dev/null
    then
        echo "[$(date -Iseconds)] WARNING: Failed to send Discord notification" >&2
    fi
}

on_exit() {
    local exit_code=$?

    trap - EXIT

    local end_time
    local duration

    end_time="$(date +%s)"
    duration="$((end_time - START_TIME))"

    if [[ "${exit_code}" -eq 0 ]]; then
        notify_discord \
            "success" \
            "${exit_code}" \
            "completed" \
            "${duration}" \
            ""
    else
        local log_tail=""

        if [[ -f "${LOG_FILE}" ]]; then
            log_tail="$(tail -n 10 "${LOG_FILE}")"
        fi

        notify_discord \
            "failure" \
            "${exit_code}" \
            "${PHASE}" \
            "${duration}" \
            "${log_tail}"
    fi

    cleanup
    exit "${exit_code}"
}

trap on_exit EXIT

echo "[$(date -Iseconds)] Starting B2 backup"
echo "[$(date -Iseconds)] Source:      ${B2_REMOTE_PATH}"
echo "[$(date -Iseconds)] Destination: ${BACKUP_DIR}"


# ---------------------------------------------------------------------------
# 1. Incremental copy
# ---------------------------------------------------------------------------

PHASE="copy"

rclone copy \
    "${B2_REMOTE_PATH}" \
    "${BACKUP_DIR}" \
    --checksum \
    --create-empty-src-dirs \
    --fast-list \
    --transfers="${RCLONE_TRANSFERS}" \
    --checkers="${RCLONE_CHECKERS}" \
    --log-level="${RCLONE_LOG_LEVEL}" \
    --stats=30s \
    --stats-one-line \
    2>&1 | tee -a "${LOG_FILE}"

echo "[$(date -Iseconds)] Copy completed"
echo "[$(date -Iseconds)] Starting checksum verification"


# ---------------------------------------------------------------------------
# 2. Checksum verification
#
# --one-way:
#   B2側にあるファイルについてローカルとの整合性を検証。
#   ローカルにのみ残っている古いファイルは許容する。
# ---------------------------------------------------------------------------

PHASE="checksum verification"

rclone check \
    "${B2_REMOTE_PATH}" \
    "${BACKUP_DIR}" \
    --one-way \
    --checkers="${RCLONE_CHECKERS}" \
    --log-level="${RCLONE_LOG_LEVEL}" \
    2>&1 | tee -a "${LOG_FILE}"

PHASE="completed"

echo "[$(date -Iseconds)] Checksum verification succeeded"
echo "[$(date -Iseconds)] Backup completed successfully"
EOF

RUN chmod 0755 /usr/local/bin/run-backup.sh


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

RUN cat > /usr/local/bin/entrypoint.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail


# ---------------------------------------------------------------------------
# Validate timezone
# ---------------------------------------------------------------------------

if [[ ! -f "/usr/share/zoneinfo/${TZ}" ]]; then
    echo "ERROR: Invalid TZ: ${TZ}" >&2
    exit 1
fi

ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
echo "${TZ}" > /etc/timezone


# ---------------------------------------------------------------------------
# Validate configuration
# ---------------------------------------------------------------------------

if [[ ! "${BACKUP_TIME}" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    echo "ERROR: BACKUP_TIME must be HH:MM (example: 03:00)" >&2
    exit 1
fi

if [[ -z "${B2_REMOTE_PATH:-}" ]]; then
    echo "ERROR: B2_REMOTE_PATH is not set" >&2
    exit 1
fi

if [[ -z "${BACKUP_DIR:-}" ]]; then
    echo "ERROR: BACKUP_DIR is not set" >&2
    exit 1
fi

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    echo "ERROR: DISCORD_WEBHOOK_URL is not set" >&2
    exit 1
fi

HOUR="${BACKUP_TIME%:*}"
MINUTE="${BACKUP_TIME#*:}"

mkdir -p "${BACKUP_DIR}"


# ---------------------------------------------------------------------------
# Save environment for cron
# ---------------------------------------------------------------------------

ENV_FILE="/run/backup-env.sh"

: > "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

for name in $(compgen -e); do
    case "${name}" in
        RCLONE_*|TZ|BACKUP_TIME|B2_REMOTE_PATH|BACKUP_DIR|DISCORD_WEBHOOK_URL)
            printf 'export %s=%q\n' \
                "${name}" \
                "${!name}" \
                >> "${ENV_FILE}"
            ;;
    esac
done


# ---------------------------------------------------------------------------
# Create cron schedule
# ---------------------------------------------------------------------------

cat > /etc/crontabs/root <<EOF_CRON
${MINUTE} ${HOUR} * * * /bin/bash -c 'source /run/backup-env.sh && exec /usr/local/bin/run-backup.sh'
EOF_CRON

chmod 0600 /etc/crontabs/root


echo "B2 backup container started"
echo "  Timezone : ${TZ}"
echo "  Schedule : ${BACKUP_TIME} every day"
echo "  Source   : ${B2_REMOTE_PATH}"
echo "  Target   : ${BACKUP_DIR}"
echo "  Verify   : checksum"
echo "  Discord  : enabled"


# ---------------------------------------------------------------------------
# Initial backup
#
# BACKUP_DIR が完全に空の場合のみ、cronの時刻を待たずに即時実行する。
#
# - 通常の初回起動:
#       empty -> immediate backup
#
# - 2回目以降:
#       files exist -> skip
#
# findを使用することで、通常ファイルだけでなく
# .hidden-file 等の隠しファイルも検出する。
# ---------------------------------------------------------------------------

if [[ -z "$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "[$(date -Iseconds)] Backup directory is empty"
    echo "[$(date -Iseconds)] Running initial backup immediately"

    /usr/local/bin/run-backup.sh

    echo "[$(date -Iseconds)] Initial backup completed successfully"
else
    echo "[$(date -Iseconds)] Backup directory is not empty"
    echo "[$(date -Iseconds)] Skipping initial backup"
fi


# ---------------------------------------------------------------------------
# Start cron
# ---------------------------------------------------------------------------

echo "[$(date -Iseconds)] Starting cron scheduler"

exec crond -f -l 2
EOF

RUN chmod 0755 /usr/local/bin/entrypoint.sh

VOLUME ["/var/backups"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
