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
    --service-name mail-watch-test >/dev/null

service_file=$fake_home/.config/systemd/user/mail-watch-test.service
env_file=$fake_home/.config/mail-watch/mail-watch.env
mirador_config=$fake_home/.config/mirador/config.toml

[ -f "$service_file" ] || fail "installer did not render service file"
[ -f "$env_file" ] || fail "installer did not create env file"
[ -f "$mirador_config" ] || fail "installer did not create Mirador config"

grep -F "MAIL_WATCH_HOME=$root_dir" "$service_file" >/dev/null \
  || fail "service file does not include rendered MAIL_WATCH_HOME"
grep -F "MAIL_WATCH_ENV_FILE=$env_file" "$service_file" >/dev/null \
  || fail "service file does not include rendered env file"
grep -F "ExecStart=$fake_bin/mirador -c $mirador_config watch" "$service_file" >/dev/null \
  || fail "service file does not include rendered ExecStart"
grep -F '{{' "$service_file" >/dev/null \
  && fail "service file still contains template placeholders"
grep -F 'maildir.root' "$mirador_config" >/dev/null \
  || fail "installer did not copy requested Maildir template"
grep -F -- '--user daemon-reload' "$systemctl_log" >/dev/null \
  || fail "installer did not reload user systemd manager"
pass "systemd installer dry run"

printf 'validate: all checks passed\n'
