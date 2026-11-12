#!/usr/bin/env python3
"""Opt-in, one-private-chat Telegram transport for fm-inbox.sh (stdlib only).

Usage: fm-telegram.py --home /absolute/FM_HOME <command> [options]
Run --help and <command> --help for setup, local approval and delivery recovery.
Configuration: config/telegram/{token,approval.json}, private and gitignored.
Transport journal: state/telegram/transport.sqlite3; no task queue or agent.
Only run/inspect use the network. No HTTP listener, service installation, shell
execution of text, transcript export, or automatic enrollment. See
../docs/telegram.md for the attended activation and privacy contract.
"""

import argparse
import contextlib
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
MAX_TEXT = 14000
PART_UNITS = 3500
MAX_PENDING = 256
MAX_RESPONSE = 2 * 1024 * 1024
LOCK_ROOT = Path("/tmp") / f"fm-telegram-{os.getuid()}"


class BridgeError(Exception):
    """Only fixed, non-secret diagnostics cross the CLI boundary."""


class APIError(BridgeError):
    def __init__(self, code=0, retry_after=0):
        self.code = code
        self.retry_after = min(max(retry_after, 1), 300)
        super().__init__(f"Telegram request failed (code {code}); no remote detail logged")


def private_dir(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise BridgeError("Telegram directory must be owned by this user with mode 0700")


def private_read(path, limit=65536, binary=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1):
            raise BridgeError("Telegram files must be single-link, owned by this user and mode 0600")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise BridgeError("Telegram local file exceeds its limit")
    return data if binary else data.decode("utf-8")


def private_write(path, text):
    private_dir(path.parent)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".new-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def positive_id(value):
    if type(value) is not int or not 0 < value < 2**52:
        raise BridgeError("Identity must be a positive numeric Telegram id")
    return value


def parts(text):
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT or "\x00" in text:
        raise BridgeError("Text must be nonempty, NUL-free and at most 14000 characters")
    result, chunk, units = [], [], 0
    for char in text:
        size = 2 if ord(char) > 0xFFFF else 1
        if units + size > PART_UNITS:
            result.append("".join(chunk))
            chunk, units = [], 0
        chunk.append(char)
        units += size
    return result + ["".join(chunk)]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a token-bearing URL to a redirect target.
        return None


class API:
    def __init__(self, token):
        self.token = token
        # Do not inherit HTTP(S)_PROXY: this is a credential-bearing connection.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, method, **payload):
        url = f"https://api.telegram.org/bot{self.token}/{method}"
        req = urllib.request.Request(url, json.dumps(payload).encode(),
                                     {"Content-Type": "application/json"}, method="POST")
        try:
            try:
                response = self.opener.open(req, timeout=40)
            except urllib.error.HTTPError as exc:
                response = exc
            with response:
                data = response.read(MAX_RESPONSE + 1)
            if len(data) > MAX_RESPONSE:
                raise APIError()
            doc = json.loads(data)
            if doc.get("ok") is not True:
                code = doc.get("error_code", 0)
                retry = doc.get("parameters", {}).get("retry_after", 1)
                raise APIError(code if type(code) is int else 0,
                               retry if type(retry) is int else 1)
            return doc["result"]
        except APIError:
            raise
        except Exception:
            # urllib exceptions and server descriptions can contain the token.
            raise APIError() from None


class Home:
    def __init__(self, path):
        self.path = Path(path).resolve(strict=True)
        self.config = self.path / "config" / "telegram"
        self.state = self.path / "state" / "telegram"
        self.approval_path = self.config / "approval.json"

    def approval(self):
        try:
            cfg = json.loads(private_read(self.approval_path))
        except FileNotFoundError:
            raise BridgeError("Telegram is disabled; complete local setup and approval first") from None
        if (cfg.get("enabled") is not True or cfg.get("home") != str(self.path)
                or positive_id(cfg.get("user_id")) != positive_id(cfg.get("chat_id"))):
            raise BridgeError("Telegram approval is disabled or belongs to another home/chat")
        positive_id(cfg.get("bot_id"))
        if type(cfg.get("since")) is not int:
            raise BridgeError("Invalid Telegram approval time")
        return cfg

    def token(self):
        value = os.environ.get("FM_TELEGRAM_BOT_TOKEN", "").strip()
        if not value:
            try:
                value = private_read(self.config / "token", 256).strip()
            except FileNotFoundError:
                raise BridgeError("No Telegram token configured; use local Vault injection or setup (never chat)") from None
        if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]{20,200}", value):
            raise BridgeError("Invalid local Telegram token format")
        return value

    def inbox(self, *args, text=None):
        env = os.environ.copy()
        env.update(FM_HOME=str(self.path), FM_STATE_OVERRIDE=str(self.path / "state"),
                   FM_DATA_OVERRIDE=str(self.path / "data"),
                   FM_CONFIG_OVERRIDE=str(self.path / "config"))
        # Never let a caller's preloaded-library marker skip inbox initialization.
        env.pop("FM_INBOX_WAKE_LIB", None)
        env.pop("FM_TELEGRAM_BOT_TOKEN", None)  # Vault credentials never reach the agent/inbox child
        with tempfile.TemporaryFile() as output:
            try:
                proc = subprocess.Popen(["bash", str(ROOT / "fm-inbox.sh"), *args],
                                        stdin=subprocess.PIPE, text=True, stdout=output,
                                        stderr=subprocess.DEVNULL, env=env, start_new_session=True,
                                        preexec_fn=lambda: resource.setrlimit(
                                            resource.RLIMIT_FSIZE, (MAX_RESPONSE, MAX_RESPONSE)))
                proc.communicate(input=text, timeout=25)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
                raise BridgeError("Inbox operation timed out; update remains unconfirmed") from None
            except BaseException:
                if 'proc' in locals() and proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=5)
                raise
            if output.tell() > MAX_RESPONSE:
                raise BridgeError("Inbox receipts exceed transport limit; update remains unconfirmed")
            output.seek(0)
            doc = json.load(output)
        if proc.returncode not in (0, 3):
            raise BridgeError("Inbox operation failed; update remains unconfirmed")
        return doc


@contextlib.contextmanager
def consumer_lock(bot_id):
    # Also excludes two homes using this bot on this host/user. Never unlink a
    # locked inode; remote pollers remain Telegram's 409 conflict to report.
    folder = LOCK_ROOT
    private_dir(folder)
    fd = os.open(folder / f"{bot_id}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1):
            raise BridgeError("Unsafe Telegram consumer lock permissions")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BridgeError("Another local consumer owns this Telegram bot; stop it first") from None
        yield
    finally:
        os.close(fd)


class Transport:
    def __init__(self, home, cfg, api, recover=True):
        self.home, self.cfg, self.api = home, cfg, api
        private_dir(home.state)
        dbpath = home.state / "transport.sqlite3"
        if dbpath.exists():
            private_read(dbpath, 16 * 1024 * 1024, binary=True)
        self.db = sqlite3.connect(dbpath, timeout=5)
        os.chmod(dbpath, 0o600)
        self.db.executescript("""
            PRAGMA synchronous=FULL;
            PRAGMA max_page_count=4096;
            PRAGMA journal_size_limit=65536;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS inbound (
                update_id INTEGER PRIMARY KEY, note TEXT UNIQUE NOT NULL,
                request TEXT UNIQUE NOT NULL, message_id INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS delivery (
                id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL, kind TEXT NOT NULL,
                body TEXT NOT NULL, part INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL DEFAULT 'ready', attempts INTEGER NOT NULL DEFAULT 0,
                UNIQUE(note, kind));
        """)
        binding = json.dumps(cfg, sort_keys=True)
        old = self.meta("binding")
        if old and old != binding:
            self.db.close()
            raise BridgeError("Transport journal belongs to another approval; do not reuse or erase it")
        with self.db:
            if not old:
                self.setmeta("binding", binding)
            # Only the consumer-lock holder may recover an interrupted POST.
            if recover:
                self.db.execute("UPDATE delivery SET state='uncertain' WHERE state='sending'")

    def meta(self, key, default=""):
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else default

    def setmeta(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, str(value)))

    def check_approval(self):
        if self.home.approval() != self.cfg:
            raise BridgeError("Telegram approval changed or was revoked; no new operation started")

    def pending_count(self):
        return self.db.execute("SELECT count(*) FROM inbound i WHERE NOT EXISTS "
                               "(SELECT 1 FROM delivery d WHERE d.note=i.note "
                               "AND d.kind='reply' AND d.state='sent')").fetchone()[0]

    def check_remote(self):
        self.check_approval()
        bot = self.api.call("getMe")
        if bot.get("id") != self.cfg["bot_id"] or bot.get("is_bot") is not True:
            raise BridgeError("Token does not belong to the locally approved bot")
        if self.api.call("getWebhookInfo").get("url"):
            raise BridgeError("Bot has an existing webhook; nothing changed; use a dedicated unused bot")
        chat = self.api.call("getChat", chat_id=self.cfg["chat_id"])
        if chat.get("id") != self.cfg["chat_id"] or chat.get("type") != "private":
            raise BridgeError("Approved destination is not the expected private chat")

    def accept(self, update):
        self.check_approval()
        uid = update.get("update_id")
        if type(uid) is not int or uid < 0:
            raise BridgeError("Invalid Telegram update id; not acknowledged")
        offset = int(self.meta("offset", "0"))
        if uid < offset:
            return
        msg = update.get("message", {})
        sender, chat = msg.get("from", {}), msg.get("chat", {})
        text = msg.get("text")
        allowed = (type(sender.get("id")) is int and type(chat.get("id")) is int
                   and sender.get("id") == self.cfg["user_id"]
                   and sender.get("is_bot") is False
                   and chat.get("id") == self.cfg["chat_id"]
                   and chat.get("type") == "private"
                   and not msg.get("sender_chat") and not any(k.startswith("forward_") for k in msg)
                   and not msg.get("is_automatic_forward") and not msg.get("via_bot")
                   and type(msg.get("date")) is int and msg["date"] >= self.cfg["since"]
                   and type(msg.get("message_id")) is int and msg["message_id"] > 0
                   and isinstance(text, str) and text.strip()
                   and len(text) <= 4096 and "\x00" not in text)
        if allowed:
            if self.pending_count() >= MAX_PENDING:
                raise BridgeError("256 requests awaiting sent answers; update left unconfirmed until replies are sent")
            request = f"telegram:{self.cfg['bot_id']}:{self.cfg['chat_id']}:{uid}"
            body = ("Telegram private request (authenticated text, not command execution; "
                    "existing approval rules still apply). Publish the answer with fm-inbox.sh reply "
                    "against this note; only that authored answer returns to the approved private chat.\n\n" + text)
            note = self.home.inbox("note", "--request-id", request, "--json", "-", text=body)
            if not note.get("saved") or note.get("request_id") != request:
                raise BridgeError("Inbox did not confirm the correlated note; Telegram update not acknowledged")
            with self.db:
                self.db.execute("INSERT OR IGNORE INTO inbound VALUES (?,?,?,?)",
                                (uid, note["id"], request, msg["message_id"]))
                if not note.get("announced") and not note.get("acknowledged"):
                    # Replay repairs announcement on the next iteration/restart.
                    raise BridgeError("Request saved but not announced; retry will repair its inbox notification")
                self.setmeta("offset", uid + 1)
        else:
            # No enrollment, rejection message, or reply to unauthorized senders.
            with self.db:
                self.setmeta("offset", uid + 1)

    def collect(self):
        cursor = self.meta("reply_cursor")
        receipts = self.home.inbox("receipts", "--after", cursor)
        with self.db:
            for reply in receipts["replies"]:
                note = reply["id"]
                if self.db.execute("SELECT 1 FROM inbound WHERE note=?", (note,)).fetchone():
                    parts(reply["body"])
                    self.db.execute("INSERT OR IGNORE INTO delivery (note,kind,body) VALUES (?,'reply',?)",
                                    (note, reply["body"]))
            self.setmeta("reply_cursor", receipts["reply_cursor"])

    def decision(self, note, text):
        parts(text)
        if not self.db.execute("SELECT 1 FROM inbound WHERE note=?", (note,)).fetchone():
            raise BridgeError("Decision requires a request received by this approved Telegram chat/home")
        # A stable content key makes a repeated local publication idempotent.
        kind = "decision:" + hashlib.sha256(text.encode()).hexdigest()
        with self.db:
            if self.db.execute("SELECT 1 FROM delivery WHERE note=? AND kind=?", (note, kind)).fetchone():
                return
            count = self.db.execute("SELECT count(*) FROM delivery WHERE state!='sent'").fetchone()[0]
            decisions = self.db.execute("SELECT count(*) FROM delivery WHERE note=? AND kind!='reply'",
                                        (note,)).fetchone()[0]
            if count >= MAX_PENDING or decisions >= 8:
                raise BridgeError("Telegram delivery limit reached (256 pending, eight decisions per request)")
            self.db.execute("INSERT OR IGNORE INTO delivery (note,kind,body) VALUES (?,?,?)", (note, kind, text))

    def send(self):
        self.check_approval()
        row = self.db.execute("SELECT id,note,body,part,attempts,state FROM delivery "
                              "WHERE state!='sent' ORDER BY id LIMIT 1").fetchone()
        if not row:
            return False
        did, note, body, index, attempts, state = row
        if state != "ready":
            raise BridgeError(f"Delivery {did} is {state}; inspect status and resolve locally before retrying")
        message = self.db.execute("SELECT message_id FROM inbound WHERE note=?", (note,)).fetchone()
        if not message:
            raise BridgeError("Missing private request binding; refusing outbound delivery")
        chunks = parts(body)
        with self.db:
            self.db.execute("UPDATE delivery SET state='sending' WHERE id=?", (did,))
        try:
            sent = self.api.call("sendMessage", chat_id=self.cfg["chat_id"], text=chunks[index],
                                 reply_parameters={"message_id": message[0], "allow_sending_without_reply": True},
                                 link_preview_options={"is_disabled": True}, protect_content=True)
        except APIError as exc:
            # Only explicit 429 proves rejection and permits automatic retry.
            state = "ready" if exc.code == 429 and attempts < 3 else (
                "rejected" if 400 <= exc.code < 500 else "uncertain")
            with self.db:
                self.db.execute("UPDATE delivery SET state=?,attempts=attempts+1 WHERE id=?", (state, did))
            if state == "ready":
                time.sleep(exc.retry_after)
                return True
            raise BridgeError(f"Delivery {did} is {state}; no automatic resend; resolve locally") from None
        if (not isinstance(sent, dict) or sent.get("chat", {}).get("id") != self.cfg["chat_id"]
                or sent.get("chat", {}).get("type") != "private"
                or sent.get("from", {}).get("id") != self.cfg["bot_id"]
                or sent.get("from", {}).get("is_bot") is not True
                or type(sent.get("message_id")) is not int):
            with self.db:
                self.db.execute("UPDATE delivery SET state='uncertain' WHERE id=?", (did,))
            raise BridgeError("Send response did not confirm the approved private destination; delivery uncertain")
        with self.db:
            complete = index + 1 == len(chunks)
            self.db.execute("UPDATE delivery SET part=?,state=?,attempts=0,body=? WHERE id=?",
                            (index + 1, "sent" if complete else "ready", "" if complete else body, did))
        time.sleep(1.1)  # below Telegram's single-chat rate, including split replies
        return True

    def resolve(self, delivery, outcome):
        row = self.db.execute("SELECT body,part,state FROM delivery WHERE id=?", (delivery,)).fetchone()
        if not row or row[2] not in ("uncertain", "rejected"):
            raise BridgeError("Only an uncertain or rejected delivery can be resolved")
        index = row[1] + (1 if outcome == "sent" else 0)
        state = "sent" if index >= len(parts(row[0])) else "ready"
        with self.db:
            self.db.execute("UPDATE delivery SET part=?,state=?,attempts=0,body=? WHERE id=?",
                            (index, state, "" if state == "sent" else row[0], delivery))

    def status(self):
        pending = self.db.execute("SELECT id,note,kind,body,part,state FROM delivery "
                                  "WHERE state!='sent' ORDER BY id LIMIT 21").fetchall()
        details = [{"delivery": did, "note": note,
                    "kind": "reply" if kind == "reply" else "decision",
                    "sent_parts": index, "total_parts": len(parts(body)), "state": state}
                   for did, note, kind, body, index, state in pending[:20]]
        return {"requests_captured": self.db.execute("SELECT count(*) FROM inbound").fetchone()[0],
                "requests_awaiting_sent_answer": self.pending_count(),
                "requests_without_collected_answer": self.db.execute(
                    "SELECT count(*) FROM inbound i WHERE NOT EXISTS "
                    "(SELECT 1 FROM delivery d WHERE d.note=i.note AND d.kind='reply')").fetchone()[0],
                "pending_delivery_details": details, "more_pending_details": len(pending) > 20,
                "deliveries": dict(self.db.execute("SELECT state,count(*) FROM delivery GROUP BY state")),
                "next_update": self.meta("offset"), "last_poll": self.meta("last_poll"),
                "meaning": "counts are retained records, not lifetime totals; captured is queued, not answered; sent means API-confirmed or locally attested delivery of every part"}

    def cycle(self):
        # Recheck every poll; never reset a webhook or drop pending updates.
        self.check_remote()
        full = self.pending_count() >= MAX_PENDING
        payload = {"timeout": 25, "limit": 20, "allowed_updates": ["message"]}
        if self.meta("offset"):
            payload["offset"] = int(self.meta("offset"))
        # Backpressure never prevents draining already-authored answers, and
        # never acknowledges an update that could not be saved locally.
        updates = [] if full else self.api.call("getUpdates", **payload)
        if not isinstance(updates, list):
            raise BridgeError("Invalid Telegram update response")
        if not full:
            with self.db:
                self.setmeta("last_poll", int(time.time()))
        for update in sorted(updates, key=lambda u: u["update_id"]):
            if self.pending_count() >= MAX_PENDING:
                break
            self.accept(update)
        # Capture/replay mappings before advancing the global reply cursor: a
        # crash after inbox save must not make an unusually fast answer vanish.
        self.collect()
        for _ in range(8):
            if not self.send():
                break
        if full:
            time.sleep(5)
        with self.db:
            # Retain at most 1000 completed request bindings plus pending work.
            old = self.db.execute("SELECT i.note FROM inbound i WHERE EXISTS "
                                  "(SELECT 1 FROM delivery d WHERE d.note=i.note AND d.kind='reply' AND d.state='sent') "
                                  "AND NOT EXISTS (SELECT 1 FROM delivery d WHERE d.note=i.note AND d.state!='sent') "
                                  "ORDER BY i.update_id DESC LIMIT -1 OFFSET 1000").fetchall()
            for (note,) in old:
                self.db.execute("DELETE FROM delivery WHERE note=?", (note,))
                self.db.execute("DELETE FROM inbound WHERE note=?", (note,))


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--home", default=os.environ.get("FM_HOME"), help="explicit existing Firstmate home")
    commands = p.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("setup", help="Vault setup guidance, or hidden local-file fallback; no enable")
    setup.add_argument("--local-file", action="store_true",
                       help="explicit 0600 file fallback when Vault injection is unsupported")
    commands.add_parser("inspect", help="network: show bot and private candidate numeric IDs only; never enroll")
    approve = commands.add_parser("approve", help="offline local approval after manual identity verification")
    for field in ("bot-id", "user-id", "chat-id"):
        approve.add_argument("--" + field, required=True, type=int)
    commands.add_parser("disable", help="offline: disable future polls/sends (stop run with Ctrl-C first)")
    commands.add_parser("status", help="offline: transport counts and inbox readiness, no text or secrets")
    commands.add_parser("run", help="foreground long polling; Ctrl-C stops; no persistent service installed")
    decision = commands.add_parser("decision", help="explicitly publish a chat-safe decision; body on stdin")
    decision.add_argument("--note-id", required=True, help="original Telegram inbox note; rejects other notes")
    resolve = commands.add_parser("resolve", help="offline: verify current part in phone before sent/retry")
    resolve.add_argument("--delivery", type=int, required=True)
    resolve.add_argument("--outcome", choices=["sent", "retry"], required=True,
                         help="sent confirms current part; retry can duplicate an ambiguously accepted part")
    return p


def main():
    args = parser().parse_args()
    if not args.home or not Path(args.home).is_absolute():
        raise BridgeError("An explicit absolute --home or FM_HOME is required")
    os.umask(0o077)
    home = Home(args.home)
    if args.command == "setup":
        if shutil.which("av") and not args.local_file:
            print("Vault is available. Run locally: av save FM_TELEGRAM_BOT_TOKEN")
            print("Then prefix inspect/run with: av inject +FM_TELEGRAM_BOT_TOKEN --")
            print("No secret read or written here; no transport started. Local approval is required.")
            return
        if not sys.stdin.isatty():
            raise BridgeError("Token setup needs a local terminal (never pass tokens in arguments or chat)")
        token = getpass.getpass("Telegram bot token (hidden, stored locally only): ")
        if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]{20,200}", token):
            raise BridgeError("Invalid token format")
        if (home.config / "token").exists():
            raise BridgeError("Token already exists; rotate deliberately while stopped, not through setup")
        private_write(home.config / "token", token + "\n")
        print("Token stored at mode 0600; no transport started. Local approval is required.")
        return
    if args.command == "approve":
        bot, user, chat = map(positive_id, (args.bot_id, args.user_id, args.chat_id))
        if user != chat:
            raise BridgeError("For this private-user bridge user and chat ids must match")
        if home.approval_path.exists() or (home.state / "transport.sqlite3").exists():
            raise BridgeError("Approval already exists; no automatic rebinding or historical export")
        cfg = dict(enabled=True, home=str(home.path), bot_id=bot, user_id=user,
                   chat_id=chat, since=int(time.time()) + 1)
        private_write(home.approval_path, json.dumps(cfg) + "\n")
        print("Locally approved. Only new messages qualify; nothing started or sent.")
        return
    if args.command == "inspect":
        api = API(home.token())
        bot = api.call("getMe")
        bot_id = positive_id(bot["id"])
        with consumer_lock(bot_id):
            if api.call("getWebhookInfo").get("url"):
                raise BridgeError("Existing bot webhook; nothing reset; use a dedicated unused bot")
            candidates = set()
            for update in api.call("getUpdates", timeout=0, limit=20, allowed_updates=["message"]):
                msg = update.get("message", {})
                if (msg.get("chat", {}).get("type") == "private" and not msg.get("forward_origin")
                        and msg.get("from", {}).get("is_bot") is False):
                    candidates.add((positive_id(msg["from"]["id"]), positive_id(msg["chat"]["id"])))
        print(json.dumps({"bot_id": bot_id, "bot_username": bot.get("username"),
                          "untrusted_private_candidates_user_chat": sorted(candidates),
                          "warning": "Candidates are not identity proof. Verify manually; no enrollment occurred."}))
        return
    cfg = home.approval()
    if args.command == "disable":
        cfg["enabled"] = False
        private_write(home.approval_path, json.dumps(cfg) + "\n")
        print("Disabled. Stop the foreground process; no new operations will start after configuration reload.")
        return
    if args.command == "run":
        api = API(home.token())  # no secret access for status/decision/resolve
        with consumer_lock(cfg["bot_id"]):
            bridge = Transport(home, cfg, api)
            errors = 0
            try:
                while True:
                    if home.approval() != cfg:
                        raise BridgeError("Telegram approval changed; stopped without rebinding")
                    try:
                        bridge.cycle()
                        errors = 0
                    except APIError as exc:
                        if exc.code in (401, 403, 409):
                            raise BridgeError("Bot authentication/ownership conflict; stopped; no webhook or consumer reset") from None
                        errors += 1
                        if errors >= 3:
                            raise BridgeError("Telegram unavailable after three polls; stopped; saved requests remain queued") from None
                        time.sleep(exc.retry_after if exc.code == 429 else 5 * errors)
            finally:
                bridge.db.close()
    else:
        # Publication/status may coexist with polling; only the lock holder
        # may turn a previous process's interrupted POST into 'uncertain'.
        lock = consumer_lock(cfg["bot_id"]) if args.command == "resolve" else contextlib.nullcontext()
        with lock:
            bridge = Transport(home, cfg, None, recover=args.command == "resolve")
            try:
                if args.command == "decision":
                    text = sys.stdin.read(MAX_TEXT + 1)
                    bridge.decision(args.note_id, text)
                    print("Chat-safe decision recorded for this private request; not yet sent.")
                elif args.command == "resolve":
                    bridge.resolve(args.delivery, args.outcome)
                    print("Current delivery part resolved locally; nothing sent by this command.")
                else:
                    print(json.dumps({**bridge.status(), "primary": home.inbox("ready")}))
            finally:
                bridge.db.close()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        main()
    except KeyboardInterrupt:
        print("Telegram bridge stopped; accepted inbox requests remain durable.", file=sys.stderr)
    except BridgeError as error:
        print(f"fm-telegram: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        # No traceback: paths, HTTP exceptions and payloads can contain secrets.
        print("fm-telegram: local operation failed; no sensitive detail logged; check private setup/permissions", file=sys.stderr)
        sys.exit(1)
