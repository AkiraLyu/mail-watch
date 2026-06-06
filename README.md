# mail-watch

`mail-watch` is a small Raspberry Pi friendly glue project:

```text
IMAP IDLE / JMAP / Maildir
        |
        v
mirador watch
        |
        v
hooks.on-message-added.cmd
        |
        v
scripts/send-telegram-mail.sh
        |
        v
Telegram Bot API sendMessage
        |
        v
Telegram notification on your phone
```

The repository keeps secrets out of Git, gives Mirador ready-to-edit account
templates, and installs a user-level systemd service for long-running mail
watching on a Raspberry Pi.

## Layout

```text
config/
  mail-watch.env.example          # Telegram and notification settings
  mirador.*.example.toml          # IMAP, JMAP, and Maildir templates
scripts/
  send-telegram-mail.sh           # Mirador hook called on new messages
  install-systemd-user.sh         # Optional Raspberry Pi user-service install
systemd/
  mail-watch.service.template     # Rendered by the installer
tests/
  validate.sh                     # Local syntax and dry-run checks
```

## Quick Start

1. Install system dependencies on the Raspberry Pi:

   ```sh
   sudo apt update
   sudo apt install -y build-essential curl git pkg-config systemd
   ```

2. Install Rust and Mirador:

   ```sh
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   . "$HOME/.cargo/env"
   cargo install --locked --git https://github.com/pimalaya/mirador.git
   ```

3. Clone this repository:

   ```sh
   git clone git@github.com:AkiraLyu/mail-watch.git ~/mail-watch
   cd ~/mail-watch
   ```

4. Create a Telegram bot with BotFather, get the bot token, and find your
   target chat id.

5. Copy the environment example and fill in your real values:

   ```sh
   mkdir -p ~/.config/mail-watch
   cp config/mail-watch.env.example ~/.config/mail-watch/mail-watch.env
   chmod 600 ~/.config/mail-watch/mail-watch.env
   ```

6. Copy one Mirador template to `~/.config/mirador/config.toml`, edit the mail
   account settings, then test it:

   ```sh
   mkdir -p ~/.config/mirador
   cp config/mirador.imap.example.toml ~/.config/mirador/config.toml
   mirador -c ~/.config/mirador/config.toml check
   ```

7. Test the Telegram hook without sending a network request:

   ```sh
   MAIL_WATCH_DRY_RUN=true \
   sender='Akira <akira@example.com>' \
   subject='Hello from mail-watch' \
   mailbox=INBOX \
   id=test-message \
   scripts/send-telegram-mail.sh
   ```

8. Run the watcher:

   ```sh
   MAIL_WATCH_HOME="$PWD" mirador -c ~/.config/mirador/config.toml watch
   ```

## systemd User Service

After the environment and Mirador config files exist, install the user service:

```sh
scripts/install-systemd-user.sh
```

The installer writes `~/.config/systemd/user/mail-watch.service` and keeps
existing config files if they are already present. Start it after editing the
two config files:

```sh
systemctl --user enable --now mail-watch.service
journalctl --user -u mail-watch.service -f
```

For a headless Raspberry Pi that should keep watching after logout, enable
lingering once:

```sh
loginctl enable-linger "$USER"
```

You can also let the installer enable or start the service:

```sh
scripts/install-systemd-user.sh --enable --start
```

## Mirador Templates

- `config/mirador.imap.example.toml` watches an IMAP mailbox with IDLE.
- `config/mirador.jmap.example.toml` watches a JMAP mailbox id with
  EventSource push.
- `config/mirador.maildir.example.toml` watches a local Maildir tree.

All templates use:

```toml
hooks.on-message-added.cmd = 'MAIL_WATCH_ACCOUNT=personal "${MAIL_WATCH_HOME:-$HOME/mail-watch}/scripts/send-telegram-mail.sh"'
```

The systemd service sets `MAIL_WATCH_HOME` automatically. For manual runs from
another directory, export `MAIL_WATCH_HOME=/path/to/mail-watch`.

## Telegram Hook

`scripts/send-telegram-mail.sh` reads Mirador environment variables, formats a
short HTML message, and calls Telegram `sendMessage`. Its configuration comes
from `MAIL_WATCH_ENV_FILE`, `~/.config/mail-watch/mail-watch.env`,
`/etc/mail-watch/mail-watch.env`, or `config/mail-watch.env`, in that order.

Useful local checks:

```sh
scripts/send-telegram-mail.sh --help
scripts/send-telegram-mail.sh --dry-run
```

## Notes

- Mirador currently documents its `v0.1.x` schema as active development. The
  templates in this repository follow the current `imap.*`, `jmap.*`, and
  `maildir.*` account schema.
- Hook commands receive Mirador placeholders such as `subject`, `sender`,
  `sender_address`, `recipient`, `mailbox`, and `id` as environment variables.
- Telegram secrets should live in `~/.config/mail-watch/mail-watch.env` or an
  equivalent path passed through `MAIL_WATCH_ENV_FILE`, not in Git.
