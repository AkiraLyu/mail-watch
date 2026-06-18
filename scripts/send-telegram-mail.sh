#!/bin/sh
set -eu

program=${0##*/}

usage() {
  cat <<'USAGE'
Usage: send-telegram-mail.sh [--env-file PATH] [--dry-run]

Mirador hook for hooks.on-message-added.cmd. The script reads Mirador-provided
environment variables such as subject, sender, sender_address, mailbox, and id,
formats a short HTML message, and sends it through Telegram Bot API sendMessage.

Configuration is loaded from MAIL_WATCH_ENV_FILE when set, otherwise from the
first readable file among:

  $XDG_CONFIG_HOME/mail-watch/mail-watch.env
  $HOME/.config/mail-watch/mail-watch.env
  /etc/mail-watch/mail-watch.env
  ./config/mail-watch.env

Dry-run mode prints the Telegram message and skips network calls.
USAGE
}

die() {
  printf '%s: %s\n' "$program" "$*" >&2
  exit 1
}

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(lower "${1:-}")" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

bool_param() {
  if is_true "${1:-}"; then
    printf 'true'
  else
    printf 'false'
  fi
}

one_line() {
  printf '%s' "${1:-}" | tr '\r\n\t' '   ' | sed 's/[ ][ ]*/ /g; s/^ //; s/ $//'
}

truncate_text() {
  printf '%s' "${1:-}" | awk -v max="${2:-400}" '
    {
      text = text $0
    }
    END {
      if (max < 4) {
        max = 4
      }
      if (length(text) > max) {
        printf "%s...", substr(text, 1, max - 3)
      } else {
        printf "%s", text
      }
    }
  '
}

html_escape() {
  printf '%s' "${1:-}" \
    | sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g'
}

format_html_field() {
  cleaned=$(one_line "${1:-}")
  shortened=$(truncate_text "$cleaned" "${2:-400}")
  html_escape "$shortened"
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

cli_dry_run=false
env_file=${MAIL_WATCH_ENV_FILE:-}
service_account=${MAIL_WATCH_ACCOUNT:-}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      cli_dry_run=true
      ;;
    --env-file)
      shift
      [ "$#" -gt 0 ] || die "--env-file requires a path"
      env_file=$1
      ;;
    --env-file=*)
      env_file=${1#--env-file=}
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
  shift
done

if [ -z "$env_file" ]; then
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -r "$XDG_CONFIG_HOME/mail-watch/mail-watch.env" ]; then
    env_file=$XDG_CONFIG_HOME/mail-watch/mail-watch.env
  elif [ -n "${HOME:-}" ] && [ -r "$HOME/.config/mail-watch/mail-watch.env" ]; then
    env_file=$HOME/.config/mail-watch/mail-watch.env
  elif [ -r /etc/mail-watch/mail-watch.env ]; then
    env_file=/etc/mail-watch/mail-watch.env
  elif [ -r "$project_dir/config/mail-watch.env" ]; then
    env_file=$project_dir/config/mail-watch.env
  fi
fi

if [ -n "$env_file" ]; then
  [ -r "$env_file" ] || die "cannot read environment file: $env_file"
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
fi

if [ -n "$service_account" ]; then
  MAIL_WATCH_ACCOUNT=$service_account
fi

dry_run=${MAIL_WATCH_DRY_RUN:-false}
if [ "$cli_dry_run" = true ]; then
  dry_run=true
fi

prefix=${TELEGRAM_MESSAGE_PREFIX:-New mail}
prefix_html=$(format_html_field "$prefix" 80)

if [ -n "${sender:-}" ]; then
  sender_raw=$sender
elif [ -n "${sender_name:-}" ] && [ -n "${sender_address:-}" ]; then
  sender_raw="$sender_name <$sender_address>"
elif [ -n "${sender_address:-}" ]; then
  sender_raw=$sender_address
elif [ -n "${sender_name:-}" ]; then
  sender_raw=$sender_name
else
  sender_raw="Unknown sender"
fi

subject_raw=${subject:-}
[ -n "$subject_raw" ] || subject_raw="(no subject)"

mailbox_raw=${mailbox:-}
[ -n "$mailbox_raw" ] || mailbox_raw="unknown mailbox"

id_raw=${id:-}
[ -n "$id_raw" ] || id_raw="unknown id"

account_raw=${MAIL_WATCH_ACCOUNT:-}
recipient_raw=${recipient:-}

sender_html=$(format_html_field "$sender_raw" 300)
subject_html=$(format_html_field "$subject_raw" 700)
mailbox_html=$(format_html_field "$mailbox_raw" 160)
id_html=$(format_html_field "$id_raw" 220)

message="<b>$prefix_html</b>"

if [ -n "$account_raw" ]; then
  account_html=$(format_html_field "$account_raw" 120)
  message="$message
Account: <code>$account_html</code>"
fi

message="$message
From: $sender_html
Subject: $subject_html"

if [ -n "$recipient_raw" ]; then
  recipient_html=$(format_html_field "$recipient_raw" 300)
  message="$message
To: $recipient_html"
fi

message="$message
Mailbox: <code>$mailbox_html</code>
ID: <code>$id_html</code>"

if is_true "$dry_run"; then
  printf '%s\n' "$message"
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || die "TELEGRAM_BOT_TOKEN is required"
[ -n "${TELEGRAM_CHAT_ID:-}" ] || die "TELEGRAM_CHAT_ID is required"

timeout=${TELEGRAM_TIMEOUT_SECONDS:-15}
case "$timeout" in
  '' | *[!0-9]*)
    die "TELEGRAM_TIMEOUT_SECONDS must be a positive integer"
    ;;
  0)
    die "TELEGRAM_TIMEOUT_SECONDS must be greater than 0"
    ;;
esac

api_base=${TELEGRAM_API_BASE:-https://api.telegram.org}
api_base=$(printf '%s' "$api_base" | sed 's:/*$::')
api_url=$api_base/bot$TELEGRAM_BOT_TOKEN/sendMessage

disable_preview=$(bool_param "${TELEGRAM_DISABLE_WEB_PAGE_PREVIEW:-true}")
disable_notification=$(bool_param "${TELEGRAM_DISABLE_NOTIFICATION:-false}")
protect_content=$(bool_param "${TELEGRAM_PROTECT_CONTENT:-false}")
link_preview_options=$(printf '{"is_disabled":%s}' "$disable_preview")

if [ -n "${TELEGRAM_MESSAGE_THREAD_ID:-}" ]; then
  response=$(
    curl --silent --show-error --max-time "$timeout" --retry 2 --retry-delay 2 \
      --request POST \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$message" \
      --data "parse_mode=HTML" \
      --data "link_preview_options=$link_preview_options" \
      --data "disable_notification=$disable_notification" \
      --data "protect_content=$protect_content" \
      --data-urlencode "message_thread_id=$TELEGRAM_MESSAGE_THREAD_ID" \
      "$api_url"
  ) || die "Telegram request failed"
else
  response=$(
    curl --silent --show-error --max-time "$timeout" --retry 2 --retry-delay 2 \
      --request POST \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$message" \
      --data "parse_mode=HTML" \
      --data "link_preview_options=$link_preview_options" \
      --data "disable_notification=$disable_notification" \
      --data "protect_content=$protect_content" \
      "$api_url"
  ) || die "Telegram request failed"
fi

case "$response" in
  *'"ok":true'* | *'"ok": true'*)
    printf '%s: Telegram notification sent\n' "$program" >&2
    ;;
  *)
    short_response=$(truncate_text "$(one_line "$response")" 500)
    die "Telegram API rejected sendMessage: $short_response"
    ;;
esac
