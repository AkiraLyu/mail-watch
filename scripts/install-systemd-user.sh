#!/bin/sh
set -eu

program=${0##*/}

usage() {
  cat <<'USAGE'
Usage: install-systemd-user.sh [options]

Install a user-level systemd service for running `mirador watch` with the
mail-watch Telegram hook. The installer creates the Telegram environment file,
creates a Mirador config from a backend template when missing, renders the
systemd unit, and enables the unit by default.

Options:
  --backend imap|jmap|maildir   Template copied when Mirador config is missing.
                                Default: imap
  --config PATH                 Mirador config path.
                                Default: ~/.config/mirador/config.toml
  --account NAME                Watch one named Mirador account.
  --accounts A,B                Watch multiple Mirador accounts with one
                                systemd unit per account.
  --env-file PATH               mail-watch env file path.
                                Default: ~/.config/mail-watch/mail-watch.env
  --mirador-bin PATH            Mirador binary path. Default: command -v mirador
                                or ~/.cargo/bin/mirador
  --service-name NAME           User service name. Default: mail-watch
  --telegram-bot-token TOKEN    Telegram bot token from BotFather.
  --telegram-chat-id ID         Target Telegram chat id.
  --telegram-api-base URL       Telegram Bot API base URL.
                                Default: https://api.telegram.org
  --telegram-message-prefix TXT Message title. Default: New mail
  --telegram-message-thread-id ID
                                Optional Telegram forum topic id.
  --mail-watch-account NAME     Optional account label shown in notifications.
  --dry-run true|false          Write MAIL_WATCH_DRY_RUN. Default: false
  --prompt-env                  Prompt for missing Telegram values.
  --no-prompt-env               Do not prompt; fail if required values are absent.
  --enable                      Enable the user service. Default behavior.
  --no-enable                   Install files without enabling the user service.
  --start                       Start the user service after installing it.
  --enable-linger               Run loginctl enable-linger for the current user.
  -h, --help                    Show this help.

Typical Raspberry Pi flow:

  scripts/install-systemd-user.sh --telegram-bot-token TOKEN --telegram-chat-id ID
  editor ~/.config/mirador/config.toml
  scripts/send-telegram-mail.sh --dry-run
  systemctl --user start mail-watch.service
USAGE
}

die() {
  printf '%s: %s\n' "$program" "$*" >&2
  exit 1
}

info() {
  printf '%s: %s\n' "$program" "$*" >&2
}

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

normalize_bool() {
  value=$(lower "${2:-}")
  case "$value" in
    1 | true | yes | y | on) printf 'true\n' ;;
    0 | false | no | n | off) printf 'false\n' ;;
    *) die "$1 must be true or false" ;;
  esac
}

is_placeholder_token() {
  case "${1:-}" in
    "" | "123456789:replace-with-your-token" | "replace-with-your-token")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_placeholder_chat_id() {
  case "${1:-}" in
    "" | "123456789" | "replace-with-your-chat-id")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_value() {
  prompt_label=$1
  default_value=${2:-}
  secret=${3:-false}
  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$prompt_label" "$default_value" >&2
  else
    printf '%s: ' "$prompt_label" >&2
  fi

  if [ "$secret" = true ] && command -v stty >/dev/null 2>&1 && [ -t 0 ]; then
    stty -echo
    IFS= read -r reply || reply=
    stty echo
    printf '\n' >&2
  else
    IFS= read -r reply || reply=
  fi

  if [ -n "$reply" ]; then
    printf '%s\n' "$reply"
  else
    printf '%s\n' "$default_value"
  fi
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_env_line() {
  key=$1
  value=$2
  printf '%s=' "$key"
  shell_quote "$value"
  printf '\n'
}

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

sed_replacement_escape() {
  printf '%s' "$1" | sed 's/[|&]/\\&/g'
}

validate_account_name() {
  case "${1:-}" in
    *[!A-Za-z0-9_.@-]* | "")
      die "account name contains unsupported characters: $1"
      ;;
  esac
}

render_service() {
  account=$1

  if [ -n "$account" ]; then
    validate_account_name "$account"
    unit_name=$service_name@$account.service
    account_args="-a $account "
    service_account=$account
  else
    unit_name=$service_name.service
    account_args=
    service_account=${mail_watch_account:-}
  fi

  service_path=$systemd_user_dir/$unit_name
  account_escaped=$(sed_replacement_escape "$service_account")
  account_args_escaped=$(sed_replacement_escape "$account_args")

  sed \
    -e "s|{{MAIL_WATCH_HOME}}|$mail_watch_home_escaped|g" \
    -e "s|{{MAIL_WATCH_ENV_FILE}}|$env_file_escaped|g" \
    -e "s|{{MAIL_WATCH_ACCOUNT}}|$account_escaped|g" \
    -e "s|{{MIRADOR_CONFIG}}|$mirador_config_escaped|g" \
    -e "s|{{MIRADOR_BIN}}|$mirador_bin_escaped|g" \
    -e "s|{{MIRADOR_ACCOUNT_ARGS}}|$account_args_escaped|g" \
    "$project_dir/systemd/mail-watch.service.template" >"$service_path"

  chmod 600 "$service_path"
  rendered_units="$rendered_units $unit_name"
  info "installed $service_path"
}

template_for_backend() {
  case "$1" in
    imap) printf '%s/config/mirador.imap.example.toml\n' "$project_dir" ;;
    jmap) printf '%s/config/mirador.jmap.example.toml\n' "$project_dir" ;;
    maildir) printf '%s/config/mirador.maildir.example.toml\n' "$project_dir" ;;
    *) die "unsupported backend: $1" ;;
  esac
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

backend=imap
mirador_config=${MIRADOR_CONFIG:-"$HOME/.config/mirador/config.toml"}
accounts_raw=
env_file=${MAIL_WATCH_ENV_FILE:-"$HOME/.config/mail-watch/mail-watch.env"}
service_name=mail-watch
enable_service=true
start_service=false
enable_linger=false
mirador_bin=${MIRADOR_BIN:-}
prompt_env=auto
prompt_env_explicit=false

telegram_bot_token=${TELEGRAM_BOT_TOKEN:-}
telegram_bot_token_set=false
telegram_chat_id=${TELEGRAM_CHAT_ID:-}
telegram_chat_id_set=false
telegram_api_base=${TELEGRAM_API_BASE:-https://api.telegram.org}
telegram_api_base_set=false
telegram_message_prefix=${TELEGRAM_MESSAGE_PREFIX:-New mail}
telegram_message_prefix_set=false
telegram_disable_web_page_preview=${TELEGRAM_DISABLE_WEB_PAGE_PREVIEW:-true}
telegram_disable_web_page_preview_set=false
telegram_disable_notification=${TELEGRAM_DISABLE_NOTIFICATION:-false}
telegram_disable_notification_set=false
telegram_protect_content=${TELEGRAM_PROTECT_CONTENT:-false}
telegram_protect_content_set=false
telegram_timeout_seconds=${TELEGRAM_TIMEOUT_SECONDS:-15}
telegram_timeout_seconds_set=false
telegram_message_thread_id=${TELEGRAM_MESSAGE_THREAD_ID:-}
telegram_message_thread_id_set=false
mail_watch_account=${MAIL_WATCH_ACCOUNT:-}
mail_watch_account_set=false
mail_watch_dry_run=${MAIL_WATCH_DRY_RUN:-false}
mail_watch_dry_run_set=false
env_values_set=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend)
      shift
      [ "$#" -gt 0 ] || die "--backend requires a value"
      backend=$1
      ;;
    --backend=*)
      backend=${1#--backend=}
      ;;
    --config)
      shift
      [ "$#" -gt 0 ] || die "--config requires a path"
      mirador_config=$1
      ;;
    --config=*)
      mirador_config=${1#--config=}
      ;;
    --account)
      shift
      [ "$#" -gt 0 ] || die "--account requires a value"
      accounts_raw=$1
      ;;
    --account=*)
      accounts_raw=${1#--account=}
      ;;
    --accounts)
      shift
      [ "$#" -gt 0 ] || die "--accounts requires a value"
      accounts_raw=$1
      ;;
    --accounts=*)
      accounts_raw=${1#--accounts=}
      ;;
    --env-file)
      shift
      [ "$#" -gt 0 ] || die "--env-file requires a path"
      env_file=$1
      ;;
    --env-file=*)
      env_file=${1#--env-file=}
      ;;
    --mirador-bin)
      shift
      [ "$#" -gt 0 ] || die "--mirador-bin requires a path"
      mirador_bin=$1
      ;;
    --mirador-bin=*)
      mirador_bin=${1#--mirador-bin=}
      ;;
    --service-name)
      shift
      [ "$#" -gt 0 ] || die "--service-name requires a value"
      service_name=$1
      ;;
    --service-name=*)
      service_name=${1#--service-name=}
      ;;
    --telegram-bot-token)
      shift
      [ "$#" -gt 0 ] || die "--telegram-bot-token requires a value"
      telegram_bot_token=$1
      telegram_bot_token_set=true
      env_values_set=true
      ;;
    --telegram-bot-token=*)
      telegram_bot_token=${1#--telegram-bot-token=}
      telegram_bot_token_set=true
      env_values_set=true
      ;;
    --telegram-chat-id)
      shift
      [ "$#" -gt 0 ] || die "--telegram-chat-id requires a value"
      telegram_chat_id=$1
      telegram_chat_id_set=true
      env_values_set=true
      ;;
    --telegram-chat-id=*)
      telegram_chat_id=${1#--telegram-chat-id=}
      telegram_chat_id_set=true
      env_values_set=true
      ;;
    --telegram-api-base)
      shift
      [ "$#" -gt 0 ] || die "--telegram-api-base requires a value"
      telegram_api_base=$1
      telegram_api_base_set=true
      env_values_set=true
      ;;
    --telegram-api-base=*)
      telegram_api_base=${1#--telegram-api-base=}
      telegram_api_base_set=true
      env_values_set=true
      ;;
    --telegram-message-prefix)
      shift
      [ "$#" -gt 0 ] || die "--telegram-message-prefix requires a value"
      telegram_message_prefix=$1
      telegram_message_prefix_set=true
      env_values_set=true
      ;;
    --telegram-message-prefix=*)
      telegram_message_prefix=${1#--telegram-message-prefix=}
      telegram_message_prefix_set=true
      env_values_set=true
      ;;
    --telegram-disable-web-page-preview)
      shift
      [ "$#" -gt 0 ] || die "--telegram-disable-web-page-preview requires a value"
      telegram_disable_web_page_preview=$1
      telegram_disable_web_page_preview_set=true
      env_values_set=true
      ;;
    --telegram-disable-web-page-preview=*)
      telegram_disable_web_page_preview=${1#--telegram-disable-web-page-preview=}
      telegram_disable_web_page_preview_set=true
      env_values_set=true
      ;;
    --telegram-disable-notification)
      shift
      [ "$#" -gt 0 ] || die "--telegram-disable-notification requires a value"
      telegram_disable_notification=$1
      telegram_disable_notification_set=true
      env_values_set=true
      ;;
    --telegram-disable-notification=*)
      telegram_disable_notification=${1#--telegram-disable-notification=}
      telegram_disable_notification_set=true
      env_values_set=true
      ;;
    --telegram-protect-content)
      shift
      [ "$#" -gt 0 ] || die "--telegram-protect-content requires a value"
      telegram_protect_content=$1
      telegram_protect_content_set=true
      env_values_set=true
      ;;
    --telegram-protect-content=*)
      telegram_protect_content=${1#--telegram-protect-content=}
      telegram_protect_content_set=true
      env_values_set=true
      ;;
    --telegram-timeout-seconds)
      shift
      [ "$#" -gt 0 ] || die "--telegram-timeout-seconds requires a value"
      telegram_timeout_seconds=$1
      telegram_timeout_seconds_set=true
      env_values_set=true
      ;;
    --telegram-timeout-seconds=*)
      telegram_timeout_seconds=${1#--telegram-timeout-seconds=}
      telegram_timeout_seconds_set=true
      env_values_set=true
      ;;
    --telegram-message-thread-id)
      shift
      [ "$#" -gt 0 ] || die "--telegram-message-thread-id requires a value"
      telegram_message_thread_id=$1
      telegram_message_thread_id_set=true
      env_values_set=true
      ;;
    --telegram-message-thread-id=*)
      telegram_message_thread_id=${1#--telegram-message-thread-id=}
      telegram_message_thread_id_set=true
      env_values_set=true
      ;;
    --mail-watch-account)
      shift
      [ "$#" -gt 0 ] || die "--mail-watch-account requires a value"
      mail_watch_account=$1
      mail_watch_account_set=true
      env_values_set=true
      ;;
    --mail-watch-account=*)
      mail_watch_account=${1#--mail-watch-account=}
      mail_watch_account_set=true
      env_values_set=true
      ;;
    --dry-run)
      shift
      [ "$#" -gt 0 ] || die "--dry-run requires true or false"
      mail_watch_dry_run=$1
      mail_watch_dry_run_set=true
      env_values_set=true
      ;;
    --dry-run=*)
      mail_watch_dry_run=${1#--dry-run=}
      mail_watch_dry_run_set=true
      env_values_set=true
      ;;
    --prompt-env)
      prompt_env=true
      prompt_env_explicit=true
      ;;
    --no-prompt-env)
      prompt_env=false
      ;;
    --enable)
      enable_service=true
      ;;
    --no-enable)
      enable_service=false
      start_service=false
      ;;
    --start)
      start_service=true
      enable_service=true
      ;;
    --enable-linger)
      enable_linger=true
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

case "$service_name" in
  *[!A-Za-z0-9_.@-]* | "")
    die "service name contains unsupported characters: $service_name"
    ;;
esac

mirador_config=$(expand_path "$mirador_config")
env_file=$(expand_path "$env_file")

if [ -r "$env_file" ]; then
  # shellcheck disable=SC1090
  . "$env_file"
  [ "$telegram_bot_token_set" = true ] || telegram_bot_token=${TELEGRAM_BOT_TOKEN:-$telegram_bot_token}
  [ "$telegram_chat_id_set" = true ] || telegram_chat_id=${TELEGRAM_CHAT_ID:-$telegram_chat_id}
  [ "$telegram_api_base_set" = true ] || telegram_api_base=${TELEGRAM_API_BASE:-$telegram_api_base}
  [ "$telegram_message_prefix_set" = true ] || telegram_message_prefix=${TELEGRAM_MESSAGE_PREFIX:-$telegram_message_prefix}
  [ "$telegram_disable_web_page_preview_set" = true ] || telegram_disable_web_page_preview=${TELEGRAM_DISABLE_WEB_PAGE_PREVIEW:-$telegram_disable_web_page_preview}
  [ "$telegram_disable_notification_set" = true ] || telegram_disable_notification=${TELEGRAM_DISABLE_NOTIFICATION:-$telegram_disable_notification}
  [ "$telegram_protect_content_set" = true ] || telegram_protect_content=${TELEGRAM_PROTECT_CONTENT:-$telegram_protect_content}
  [ "$telegram_timeout_seconds_set" = true ] || telegram_timeout_seconds=${TELEGRAM_TIMEOUT_SECONDS:-$telegram_timeout_seconds}
  [ "$telegram_message_thread_id_set" = true ] || telegram_message_thread_id=${TELEGRAM_MESSAGE_THREAD_ID:-$telegram_message_thread_id}
  [ "$mail_watch_account_set" = true ] || mail_watch_account=${MAIL_WATCH_ACCOUNT:-$mail_watch_account}
  [ "$mail_watch_dry_run_set" = true ] || mail_watch_dry_run=${MAIL_WATCH_DRY_RUN:-$mail_watch_dry_run}
fi

if [ "$prompt_env" = auto ]; then
  if [ -t 0 ] && {
    is_placeholder_token "$telegram_bot_token" || is_placeholder_chat_id "$telegram_chat_id"
  }; then
    prompt_env=true
  else
    prompt_env=false
  fi
fi

if [ "$prompt_env" = true ]; then
  if is_placeholder_token "$telegram_bot_token"; then
    telegram_bot_token=$(prompt_value "Telegram bot token" "" true)
    env_values_set=true
  fi
  if is_placeholder_chat_id "$telegram_chat_id"; then
    telegram_chat_id=$(prompt_value "Telegram chat id" "" false)
    env_values_set=true
  fi
  if [ "$prompt_env_explicit" = true ]; then
    telegram_api_base=$(prompt_value "Telegram API base" "$telegram_api_base" false)
    telegram_message_prefix=$(prompt_value "Telegram message prefix" "$telegram_message_prefix" false)
    env_values_set=true
  fi
fi

is_placeholder_token "$telegram_bot_token" \
  && die "Telegram bot token is required; pass --telegram-bot-token or run interactively"
is_placeholder_chat_id "$telegram_chat_id" \
  && die "Telegram chat id is required; pass --telegram-chat-id or run interactively"

telegram_disable_web_page_preview=$(normalize_bool "TELEGRAM_DISABLE_WEB_PAGE_PREVIEW" "$telegram_disable_web_page_preview")
telegram_disable_notification=$(normalize_bool "TELEGRAM_DISABLE_NOTIFICATION" "$telegram_disable_notification")
telegram_protect_content=$(normalize_bool "TELEGRAM_PROTECT_CONTENT" "$telegram_protect_content")
mail_watch_dry_run=$(normalize_bool "MAIL_WATCH_DRY_RUN" "$mail_watch_dry_run")

case "$telegram_timeout_seconds" in
  '' | *[!0-9]*)
    die "TELEGRAM_TIMEOUT_SECONDS must be a positive integer"
    ;;
  0)
    die "TELEGRAM_TIMEOUT_SECONDS must be greater than 0"
    ;;
esac

if [ -z "$mirador_bin" ]; then
  if command -v mirador >/dev/null 2>&1; then
    mirador_bin=$(command -v mirador)
  elif [ -x "$HOME/.cargo/bin/mirador" ]; then
    mirador_bin=$HOME/.cargo/bin/mirador
  else
    die "mirador not found; install it or pass --mirador-bin PATH"
  fi
fi

mirador_bin=$(expand_path "$mirador_bin")
[ -x "$mirador_bin" ] || die "mirador binary is not executable: $mirador_bin"

command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

install -d -m 700 "$(dirname "$env_file")"
if [ ! -e "$env_file" ] || [ "$env_values_set" = true ]; then
  env_tmp=$env_file.tmp.$$
  {
    printf '# Generated by %s. Keep this file private.\n' "$program"
    write_env_line TELEGRAM_BOT_TOKEN "$telegram_bot_token"
    write_env_line TELEGRAM_CHAT_ID "$telegram_chat_id"
    write_env_line TELEGRAM_API_BASE "$telegram_api_base"
    write_env_line TELEGRAM_MESSAGE_PREFIX "$telegram_message_prefix"
    write_env_line TELEGRAM_DISABLE_WEB_PAGE_PREVIEW "$telegram_disable_web_page_preview"
    write_env_line TELEGRAM_DISABLE_NOTIFICATION "$telegram_disable_notification"
    write_env_line TELEGRAM_PROTECT_CONTENT "$telegram_protect_content"
    write_env_line TELEGRAM_TIMEOUT_SECONDS "$telegram_timeout_seconds"
    if [ -n "$telegram_message_thread_id" ]; then
      write_env_line TELEGRAM_MESSAGE_THREAD_ID "$telegram_message_thread_id"
    fi
    if [ -n "$mail_watch_account" ]; then
      write_env_line MAIL_WATCH_ACCOUNT "$mail_watch_account"
    fi
    write_env_line MAIL_WATCH_DRY_RUN "$mail_watch_dry_run"
  } >"$env_tmp"
  chmod 600 "$env_tmp"
  mv "$env_tmp" "$env_file"
  info "wrote $env_file with Telegram settings"
else
  chmod 600 "$env_file"
  info "kept existing $env_file"
fi

install -d -m 700 "$(dirname "$mirador_config")"
if [ ! -e "$mirador_config" ]; then
  install -m 600 "$(template_for_backend "$backend")" "$mirador_config"
  info "created $mirador_config from $backend example; edit it with your mail account"
else
  chmod 600 "$mirador_config"
  info "kept existing $mirador_config"
fi

systemd_user_dir=$HOME/.config/systemd/user
install -d -m 700 "$systemd_user_dir"
rendered_units=

mail_watch_home_escaped=$(sed_replacement_escape "$project_dir")
env_file_escaped=$(sed_replacement_escape "$env_file")
mirador_config_escaped=$(sed_replacement_escape "$mirador_config")
mirador_bin_escaped=$(sed_replacement_escape "$mirador_bin")

if [ -n "$accounts_raw" ]; then
  old_ifs=$IFS
  IFS=,
  for account in $accounts_raw; do
    IFS=$old_ifs
    render_service "$account"
    IFS=,
  done
  IFS=$old_ifs
else
  render_service ""
fi

systemctl --user daemon-reload

if [ "$enable_linger" = true ]; then
  command -v loginctl >/dev/null 2>&1 || die "loginctl is required for --enable-linger"
  loginctl enable-linger "${USER:-$(id -un)}"
  info "enabled lingering for ${USER:-$(id -un)}"
fi

if [ "$enable_service" = true ]; then
  for unit in $rendered_units; do
    systemctl --user enable "$unit"
    info "enabled $unit"
  done
fi

if [ "$start_service" = true ]; then
  for unit in $rendered_units; do
    systemctl --user restart "$unit"
    info "started $unit"
  done
fi

cat <<EOF

Installed mail-watch user service.
Units:$rendered_units

Next checks:
  1. Edit $env_file if you need to adjust Telegram options
  2. Edit $mirador_config
  3. Run: $project_dir/scripts/send-telegram-mail.sh --dry-run
  4. Run: mirador -c $mirador_config check
  5. Run: systemctl --user start UNIT_NAME
  6. Logs: journalctl --user -u UNIT_NAME -f
EOF
