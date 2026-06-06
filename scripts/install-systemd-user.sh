#!/bin/sh
set -eu

program=${0##*/}

usage() {
  cat <<'USAGE'
Usage: install-systemd-user.sh [options]

Install a user-level systemd service for running `mirador watch` with the
mail-watch Telegram hook.

Options:
  --backend imap|jmap|maildir   Template copied when Mirador config is missing.
                                Default: imap
  --config PATH                 Mirador config path.
                                Default: ~/.config/mirador/config.toml
  --env-file PATH               mail-watch env file path.
                                Default: ~/.config/mail-watch/mail-watch.env
  --mirador-bin PATH            Mirador binary path. Default: command -v mirador
                                or ~/.cargo/bin/mirador
  --service-name NAME           User service name. Default: mail-watch
  --enable                      Enable the user service after installing it.
  --start                       Start the user service after installing it.
  --enable-linger               Run loginctl enable-linger for the current user.
  -h, --help                    Show this help.

Typical Raspberry Pi flow:

  scripts/install-systemd-user.sh
  editor ~/.config/mail-watch/mail-watch.env
  editor ~/.config/mirador/config.toml
  scripts/send-telegram-mail.sh --dry-run
  systemctl --user enable --now mail-watch.service
USAGE
}

die() {
  printf '%s: %s\n' "$program" "$*" >&2
  exit 1
}

info() {
  printf '%s: %s\n' "$program" "$*" >&2
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
env_file=${MAIL_WATCH_ENV_FILE:-"$HOME/.config/mail-watch/mail-watch.env"}
service_name=mail-watch
enable_service=false
start_service=false
enable_linger=false
mirador_bin=${MIRADOR_BIN:-}

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
    --enable)
      enable_service=true
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
if [ ! -e "$env_file" ]; then
  install -m 600 "$project_dir/config/mail-watch.env.example" "$env_file"
  info "created $env_file from example; edit it with your Telegram values"
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
service_path=$systemd_user_dir/$service_name.service

mail_watch_home_escaped=$(sed_replacement_escape "$project_dir")
env_file_escaped=$(sed_replacement_escape "$env_file")
mirador_config_escaped=$(sed_replacement_escape "$mirador_config")
mirador_bin_escaped=$(sed_replacement_escape "$mirador_bin")

sed \
  -e "s|{{MAIL_WATCH_HOME}}|$mail_watch_home_escaped|g" \
  -e "s|{{MAIL_WATCH_ENV_FILE}}|$env_file_escaped|g" \
  -e "s|{{MIRADOR_CONFIG}}|$mirador_config_escaped|g" \
  -e "s|{{MIRADOR_BIN}}|$mirador_bin_escaped|g" \
  "$project_dir/systemd/mail-watch.service.template" >"$service_path"

chmod 600 "$service_path"
systemctl --user daemon-reload
info "installed $service_path"

if [ "$enable_linger" = true ]; then
  command -v loginctl >/dev/null 2>&1 || die "loginctl is required for --enable-linger"
  loginctl enable-linger "${USER:-$(id -un)}"
  info "enabled lingering for ${USER:-$(id -un)}"
fi

if [ "$enable_service" = true ]; then
  systemctl --user enable "$service_name.service"
  info "enabled $service_name.service"
fi

if [ "$start_service" = true ]; then
  systemctl --user restart "$service_name.service"
  info "started $service_name.service"
fi

cat <<EOF

Installed mail-watch user service.

Next checks:
  1. Edit $env_file
  2. Edit $mirador_config
  3. Run: $project_dir/scripts/send-telegram-mail.sh --dry-run
  4. Run: mirador -c $mirador_config check
  5. Run: systemctl --user enable --now $service_name.service
  6. Logs: journalctl --user -u $service_name.service -f
EOF
