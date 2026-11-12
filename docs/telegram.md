# Private Telegram chat

`bin/fm-telegram.py` is an optional, default-off text transport to **this existing Firstmate home**, not another assistant.
It receives requests through the existing captain inbox and returns deliberately authored inbox answers to one locally approved private chat.
It uses Python 3's standard library on macOS/Linux, outbound HTTPS long polling, and no listening HTTP endpoint or persistent service.
The host and the foreground bridge must be running; Firstmate itself must be available to answer.

**Telegram bot private chats are not end-to-end encrypted.**
Telegram and the bot host can access their contents, so do not use this for credentials or sensitive documents.
There is no automatic export of previous conversations, local records, transcripts, status tails, or decisions from other chats/homes.

## Attended setup

Do this in a trusted terminal on the host, not in an assistant conversation.
The examples assume the repository is the current directory and `FM_HOME` is the existing home's absolute path.
Do not point it at a different home merely because that home contains the same repository.

1. In Telegram, open the verified **@BotFather**, use `/newbot`, and create a dedicated bot for this home.
   Do not reuse a bot with a webhook, another polling program, another Firstmate home, or an existing integration.
   Do not grant group/channel administrator permissions or add it to groups.
   Disable group joining through BotFather if available.
2. Keep the BotFather token out of chat, shell history, visible command arguments, screenshots and source control.
   The preferred supported secret path is the locally installed Automic Vault CLI (`av`, sometimes called Atomic Vault).
   `python3 bin/fm-telegram.py --home "$FM_HOME" setup` gives Vault instructions when `av` is installed, without reading any saved secrets.
   Use the local Vault save prompt, then explicit named-key injection:

   ```sh
   av save FM_TELEGRAM_BOT_TOKEN
   av inject +FM_TELEGRAM_BOT_TOKEN -- python3 bin/fm-telegram.py --home "$FM_HOME" inspect
   ```

   Accept any required Vault review/consent locally; the bridge does not bless scripts, bypass Vault policy, or read a Vault database.
   The injected value is process memory/environment only and is removed from the inbox child's environment.
   Do not type the value as an environment assignment on a command line.
3. If Vault injection is not supported on this host, use the explicit fallback:

   ```sh
   python3 bin/fm-telegram.py --home "$FM_HOME" setup --local-file
   ```

   This prompts without echo and writes only `config/telegram/token` at mode `0600` in a `0700` directory under this gitignored home.
   It will not overwrite an existing token.
   This command does not contact Telegram, approve an identity or start anything.
   With the file fallback, omit the `av inject ... --` prefix in subsequent examples.
4. On your own phone, open the exact bot username from BotFather and send a harmless message in its **one-to-one private chat**.
   Run `inspect` again in the terminal.
   It prints the bot's identity and untrusted candidate numeric **user/chat IDs only**, never message bodies.
   It does not enroll candidates, advance the update offset, or send a reply.
   Confirm the bot ID and username against your BotFather record.
   Independently verify your own numeric Telegram user ID using an account/client identity source you trust; do not trust a display name, username, forwarded sender, arbitrary ID bot, or the first stranger to contact this bot.
   For this private-user bridge the positive numeric user and private-chat IDs must be identical.
5. Approve those exact numbers locally (replace these sample numbers):

   ```sh
   python3 bin/fm-telegram.py --home "$FM_HOME" approve \
     --bot-id 123456789 --user-id 987654321 --chat-id 987654321
   ```

   This creates a private, home-bound approval and its start time but sends nothing.
   It never approves a first contact automatically.
   Wait at least one second, then send a **new** message from your phone after approval; messages timestamped before the approval's first full second are ignored, so pairing/history is not imported as requests.
   Keep the host clock correct.
6. Start the foreground transport:

   ```sh
   av inject +FM_TELEGRAM_BOT_TOKEN -- python3 bin/fm-telegram.py --home "$FM_HOME" run
   ```

   Keep it in a dedicated terminal and stop it with **Ctrl-C** (or terminate this exact process).
   No launch agent, daemon, bot registration, service installation or deployment is performed by these commands.
   Restart the same command to resume the existing correlation journal.
   Never delete its journal to retry an answer.

A webhook or Telegram polling conflict stops the bridge rather than resetting someone else's configuration.
A host/user-scoped bot lock also prevents local overlapping consumers across homes.
Telegram has no API that proves an idle remote poller does not exist: manually establish exclusive bot ownership, and stop other consumers rather than trying to win polling races.
The bridge never calls `setWebhook` or `deleteWebhook`, and never drops pending updates to claim ownership.

## Answers and decisions

Requests are authenticated **text**, not executable shell commands or blanket permission to merge, delete, change credentials or perform destructive actions.
Existing Firstmate decision and approval rules still apply.
Only the approved numeric sender in the approved private chat qualifies; groups, channels, edited messages, forwarded/via-bot messages, files, voice and other media are ignored.

Firstmate handles each accepted message as an ordinary inbox note and must publish its actual answer with the existing `fm-inbox.sh reply <note-id> -` interface.
Acknowledging a note is not answering it, and answering it is not confirming phone delivery.
The bridge sends only replies correlated to requests it captured in this home, not every inbox reply.
There is one authored inbox answer per request, as defined by [`fm-inbox.sh`](../bin/fm-inbox.sh).
Do not publish private internal reasoning or records as an inbox answer intended for this chat.

For a later decision request, Firstmate can explicitly author a **chat-safe** message against the original Telegram inbox note:

```sh
printf '%s\n' 'The change is ready. Do you approve this specific action?' |
  python3 bin/fm-telegram.py --home "$FM_HOME" decision --note-id <original-note-id>
```

This local command records transport output; it does not send immediately, make the decision, or automatically expose an existing decision record.
It rejects unrelated inbox notes and other homes' correlations.
It can be used while the foreground bridge is running and does not need a token.
The phone user's answer arrives as another authenticated inbox note; Firstmate must reconcile it with the actual outstanding decision under its normal rules.
The example is illustrative, not permission for any particular action.

## Status, limits and delivery recovery

```sh
python3 bin/fm-telegram.py --home "$FM_HOME" status
```

This is local, network-free and secret-free, and can run while polling.
It reports retained captured-request counts, requests awaiting a sent answer, requests with no answer collected by the transport yet, per-delivery counts, the last successful update poll time, and the existing read-only inbox `ready` projection.
Pending-delivery details include the delivery ID, original note ID, state, confirmed-part count and total-part count, never text.
“Captured” means durably queued, not answered; “ready” delivery means authored output awaiting a send.
“Sent” means Telegram accepted all parts, or an operator explicitly confirmed an ambiguous part on the phone; it does not mean the human read it.
The last poll time is not a promise that the process is currently running.
An unavailable Firstmate can still have a durable inbox note awaiting its next start; the bridge does not invent an answer.
A missing or unknown readiness observation is not healthy-by-assumption.

Telegram retains unreceived bot updates for **no more than 24 hours**; a stopped host cannot guarantee capture beyond that window.
Once a request is saved in the inbox it survives bridge/Firstmate restarts.
Only after a correlated note and its notification are durable does the bridge advance its local offset, and a crash before that point uses the inbox request ID to replay/repair the same note.
There is no generic second task queue.

Inbound text is limited to 4096 characters.
Replies/decision messages are limited to 14000 characters and split into at most eight plain-text parts, each at most 3500 UTF-16 units, with link previews disabled and content protection requested.
An oversized authored reply stops collection for local correction rather than silently truncating it.
There are at most 256 requests awaiting delivered answers, 256 pending explicit decision publications, and eight distinct decision publications per request.
When capture is full, pending incoming updates stay unconfirmed while existing answers can still drain.
The transport retains at most 1000 completed request bindings plus pending work, clears sent bodies, caps its SQLite database at 16 MiB, and limits each API/inbox response to 2 MiB.
This retention is separate from the existing inbox's durable note/reply retention.
A full journal stops safely rather than discarding accepted requests.

Sending is **not exactly once** across a connection failure or process crash.
An interrupted/ambiguous POST is recorded as `uncertain` and stops automatic sending, rather than resending blindly or claiming delivery.
An explicit non-rate-limit 4xx rejection is `rejected`; explicit 429 responses get at most three automatic retries with waits capped at 300 seconds.
Polling gets at most three consecutive transient failures before stopping; authentication/ownership conflicts stop immediately.
Errors never print Bot API URLs, tokens, remote descriptions or message text.

If a delivery stops, first stop the foreground bridge and inspect the phone and local `status` output.
The diagnostic identifies the numeric delivery record; status details identify its original request and already-confirmed parts.
The next part is the current not-yet-confirmed part.
Confirm whether the current not-yet-confirmed part arrived before choosing one of:

```sh
python3 bin/fm-telegram.py --home "$FM_HOME" resolve --delivery 1 --outcome sent
python3 bin/fm-telegram.py --home "$FM_HOME" resolve --delivery 1 --outcome retry
```

Choose **one**, not both.
`sent` attests that this current part is visible on the phone; it does not skip subsequent parts.
`retry` explicitly accepts the risk of duplicating the current part and resets its retry budget.
Neither command sends anything; restart `run` after resolving the concrete problem.
Do not mark a rejected part as sent unless you have actual delivery evidence.

For permanent local revocation, stop the process first, then run `disable`.
It disables the approval without deleting the inbox, secret or correlation evidence.
There is intentionally no automatic identity rebinding or fresh-approval-over-old-journal shortcut.
For token compromise, revoke/rotate through BotFather locally and stop this process; do not paste a replacement into assistant chat.

## Verification and supported boundary

Run the synthetic regression with `bash bin/fm-test-run.sh tests/fm-telegram.test.sh`.
It uses a mock Bot API and temporary homes only, exercising identity rejection, correlation isolation, duplicate/restart recovery, scoped publication, delivery uncertainty, bounded retries/Unicode splitting, secret redaction, ownership and offline startup.
The inbox is the existing harness/backend-independent integration surface; this feature does not launch, steer or change any worker runtime.

**Real phone-to-Firstmate-to-phone setup has not been verified.**
BotFather creation, account identity verification, Vault consent, real Telegram permissions/rate limits and mobile delivery require later attended activation.
No real token stores or Telegram chats are needed by the tests.

Official references: [Bot API](https://core.telegram.org/bots/api), [getUpdates](https://core.telegram.org/bots/api#getupdates), [sendMessage](https://core.telegram.org/bots/api#sendmessage), [BotFather introduction](https://core.telegram.org/bots#botfather), and [Telegram encryption FAQ](https://core.telegram.org/techfaq).
The executable's header and `--help` own command syntax; this page owns setup and the operator-facing privacy/delivery boundaries.
