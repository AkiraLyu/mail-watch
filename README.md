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

1. Install Mirador:

   ```sh
   cargo install --locked --git https://github.com/pimalaya/mirador.git
   ```

2. Create a Telegram bot with BotFather, get the bot token, and find your
   target chat id.

3. Copy the environment example and fill in your real values:

   ```sh
   mkdir -p ~/.config/mail-watch
   cp config/mail-watch.env.example ~/.config/mail-watch/mail-watch.env
   chmod 600 ~/.config/mail-watch/mail-watch.env
   ```

4. Copy one Mirador template to `~/.config/mirador/config.toml`, edit the mail
   account settings, then test it:

   ```sh
   mkdir -p ~/.config/mirador
   cp config/mirador.imap.example.toml ~/.config/mirador/config.toml
   mirador -c ~/.config/mirador/config.toml check
   ```

5. Run the watcher:

   ```sh
   mirador -c ~/.config/mirador/config.toml watch
   ```

The systemd installer added later in this repository automates steps 3-5 for
the default user-service path.

## Notes

- Mirador currently documents its `v0.1.x` schema as active development. The
  templates in this repository follow the current `imap.*`, `jmap.*`, and
  `maildir.*` account schema.
- Hook commands receive Mirador placeholders such as `subject`, `sender`,
  `sender_address`, `recipient`, `mailbox`, and `id` as environment variables.
- Telegram secrets should live in `~/.config/mail-watch/mail-watch.env` or an
  equivalent path passed through `MAIL_WATCH_ENV_FILE`, not in Git.
