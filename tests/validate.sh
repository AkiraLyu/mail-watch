#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

fail() {
  printf 'validate: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

contains() {
  haystack=$1
  needle=$2
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

cd "$root_dir"

git diff --check
pass "git diff whitespace check"

sh -n scripts/send-telegram-mail.sh
sh -n scripts/install-systemd-user.sh
pass "shell syntax"

for template in config/mirador.imap.example.toml \
  config/mirador.jmap.example.toml \
  config/mirador.maildir.example.toml; do
  grep -F 'hooks.on-message-added.cmd' "$template" >/dev/null \
    || fail "$template does not define on-message-added hook"
  grep -F 'send-telegram-mail.sh' "$template" >/dev/null \
    || fail "$template does not call send-telegram-mail.sh"
done
pass "Mirador hook templates"

dry_run_output=$(
  HOME=/nonexistent \
  MAIL_WATCH_DRY_RUN=true \
  TELEGRAM_MESSAGE_PREFIX='Mail <Watch>' \
  MAIL_WATCH_ACCOUNT=personal \
  sender='Alice & Bob <alice@example.org>' \
  recipient='Akira <akira@example.org>' \
  subject='Hello <Pi> & Telegram' \
  mailbox=INBOX \
  id='msg<42>&x' \
  scripts/send-telegram-mail.sh
)

contains "$dry_run_output" '<b>Mail &lt;Watch&gt;</b>' \
  || fail "dry-run output did not escape prefix"
contains "$dry_run_output" 'From: Alice &amp; Bob &lt;alice@example.org&gt;' \
  || fail "dry-run output did not escape sender"
contains "$dry_run_output" 'Subject: Hello &lt;Pi&gt; &amp; Telegram' \
  || fail "dry-run output did not escape subject"
contains "$dry_run_output" 'ID: <code>msg&lt;42&gt;&amp;x</code>' \
  || fail "dry-run output did not escape id"
pass "Telegram hook dry-run formatting"

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

fake_bin=$tmp_dir/bin
fake_home=$tmp_dir/home
systemctl_log=$tmp_dir/systemctl.log
mkdir -p "$fake_bin" "$fake_home"

account_env=$tmp_dir/account.env
printf "MAIL_WATCH_DRY_RUN='true'\nMAIL_WATCH_ACCOUNT='personal'\n" >"$account_env"
account_output=$(
  MAIL_WATCH_ENV_FILE=$account_env \
  MAIL_WATCH_ACCOUNT=work \
  subject=test \
  sender=test@example.org \
  mailbox=INBOX \
  id=test \
  scripts/send-telegram-mail.sh
)
contains "$account_output" 'Account: <code>work</code>' \
  || fail "service account env did not override env-file account"
pass "Telegram hook account override"

cat >"$fake_bin/mirador" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$fake_bin/mirador"

cat >"$fake_bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MAIL_WATCH_TEST_SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$fake_bin/systemctl"

HOME=$fake_home \
USER=mailwatch-test \
PATH=$fake_bin:$PATH \
MAIL_WATCH_TEST_SYSTEMCTL_LOG=$systemctl_log \
  scripts/install-systemd-user.sh \
    --backend maildir \
    --mirador-bin "$fake_bin/mirador" \
    --telegram-bot-token "987654321:test-token" \
    --telegram-chat-id "-1001234567890" \
    --telegram-message-prefix "Pi's mail watch" \
    --mail-watch-account "personal" \
    --accounts personal,work \
    --service-name mail-watch-test >/dev/null

service_file=$fake_home/.config/systemd/user/mail-watch-test@personal.service
work_service_file=$fake_home/.config/systemd/user/mail-watch-test@work.service
env_file=$fake_home/.config/mail-watch/mail-watch.env
mirador_config=$fake_home/.config/mirador/config.toml

[ -f "$service_file" ] || fail "installer did not render personal service file"
[ -f "$work_service_file" ] || fail "installer did not render work service file"
[ -f "$env_file" ] || fail "installer did not create env file"
[ -f "$mirador_config" ] || fail "installer did not create Mirador config"

grep -F "MAIL_WATCH_HOME=$root_dir" "$service_file" >/dev/null \
  || fail "service file does not include rendered MAIL_WATCH_HOME"
grep -F "MAIL_WATCH_ENV_FILE=$env_file" "$service_file" >/dev/null \
  || fail "service file does not include rendered env file"
grep -F "MAIL_WATCH_ACCOUNT=personal" "$service_file" >/dev/null \
  || fail "personal service file does not include account env"
grep -F "ExecStart=$fake_bin/mirador -c $mirador_config -a personal watch" "$service_file" >/dev/null \
  || fail "personal service file does not include account ExecStart"
grep -F "MAIL_WATCH_ACCOUNT=work" "$work_service_file" >/dev/null \
  || fail "work service file does not include account env"
grep -F "ExecStart=$fake_bin/mirador -c $mirador_config -a work watch" "$work_service_file" >/dev/null \
  || fail "work service file does not include account ExecStart"
grep -F '{{' "$service_file" >/dev/null \
  && fail "service file still contains template placeholders"
grep -F '{{' "$work_service_file" >/dev/null \
  && fail "work service file still contains template placeholders"
grep -F 'maildir.root' "$mirador_config" >/dev/null \
  || fail "installer did not copy requested Maildir template"
grep -F "TELEGRAM_BOT_TOKEN='987654321:test-token'" "$env_file" >/dev/null \
  || fail "installer did not write Telegram bot token"
grep -F "TELEGRAM_CHAT_ID='-1001234567890'" "$env_file" >/dev/null \
  || fail "installer did not write Telegram chat id"
env_values=$(
  env -i sh -c '. "$1"; printf "%s\n%s\n%s\n%s\n" "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$TELEGRAM_MESSAGE_PREFIX" "$MAIL_WATCH_ACCOUNT"' sh "$env_file"
)
contains "$env_values" '987654321:test-token' \
  || fail "generated env file cannot load Telegram bot token"
contains "$env_values" '-1001234567890' \
  || fail "generated env file cannot load Telegram chat id"
contains "$env_values" "Pi's mail watch" \
  || fail "installer did not write Telegram message prefix"
contains "$env_values" 'personal' \
  || fail "installer did not write mail-watch account"
grep -F -- '--user daemon-reload' "$systemctl_log" >/dev/null \
  || fail "installer did not reload user systemd manager"
grep -F -- '--user enable mail-watch-test@personal.service' "$systemctl_log" >/dev/null \
  || fail "installer did not enable personal user service"
grep -F -- '--user enable mail-watch-test@work.service' "$systemctl_log" >/dev/null \
  || fail "installer did not enable work user service"
pass "systemd installer dry run"

printf 'validate: all checks passed\n'
