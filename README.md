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

5. Run the installer. It writes the Telegram env file, creates a Mirador config
   from the selected backend template when missing, renders the user systemd
   unit, and enables it:

   ```sh
   scripts/install-systemd-user.sh --backend imap
   ```

   If you omit the Telegram arguments in an interactive terminal, the installer
   prompts for them. For a headless Raspberry Pi that should keep watching after
   logout, add `--enable-linger`. For non-interactive setup, pass
   `--telegram-bot-token TOKEN --telegram-chat-id CHAT_ID`.

6. Edit the generated Mirador config and test it:

   ```sh
   editor ~/.config/mirador/config.toml
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

8. Start the watcher:

   ```sh
   systemctl --user start mail-watch.service
   journalctl --user -u mail-watch.service -f
   ```

## systemd User Service

The installer is the recommended deployment path:

```sh
scripts/install-systemd-user.sh --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID
```

It creates or updates `~/.config/mail-watch/mail-watch.env`, creates
`~/.config/mirador/config.toml` from the selected template when it is missing,
writes `~/.config/systemd/user/mail-watch.service`, reloads the user systemd
manager, and enables the unit by default. Start it after editing the mail
account settings:

```sh
systemctl --user start mail-watch.service
journalctl --user -u mail-watch.service -f
```

For a headless Raspberry Pi that should keep watching after logout, enable
lingering once:

```sh
loginctl enable-linger "$USER"
```

You can also let the installer start the service immediately:

```sh
scripts/install-systemd-user.sh --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID --start
```

Useful installer options:

```sh
scripts/install-systemd-user.sh --help
scripts/install-systemd-user.sh --no-enable
scripts/install-systemd-user.sh --backend maildir --telegram-bot-token TOKEN --telegram-chat-id CHAT_ID
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
tests/validate.sh
```

## Notes

- Mirador currently documents its `v0.1.x` schema as active development. The
  templates in this repository follow the current `imap.*`, `jmap.*`, and
  `maildir.*` account schema.
- Hook commands receive Mirador placeholders such as `subject`, `sender`,
  `sender_address`, `recipient`, `mailbox`, and `id` as environment variables.
- Telegram secrets should live in `~/.config/mail-watch/mail-watch.env` or an
  equivalent path passed through `MAIL_WATCH_ENV_FILE`, not in Git.
