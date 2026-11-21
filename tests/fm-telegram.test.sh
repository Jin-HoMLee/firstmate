#!/usr/bin/env bash
# Telegram private transport: mock API only, real inbox in isolated temp homes.
# No live bot, credentials, endpoints, services, workers or lifecycle commands.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)
export TMPDIR="$TMP_ROOT" PYTHONDONTWRITEBYTECODE=1
unset FM_TELEGRAM_BOT_TOKEN
python3 - "$ROOT/bin/fm-telegram.py" <<'PY'
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('telegram_bridge', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.LOCK_ROOT = Path(tempfile.gettempdir()) / 'telegram-consumer-locks'
SCRIPT = str(Path(sys.argv[1]))
TOKEN = '1234:' + 'X' * 30  # synthetic; never usable


class MockAPI:
    def __init__(self):
        self.calls = []
        self.updates = []
        self.error = None
        self.webhook = ''
        self.destination = {'id': 55, 'type': 'private'}

    def call(self, method, **kw):
        self.calls.append((method, kw))
        if method == 'getMe':
            return {'id': 1234, 'is_bot': True, 'username': 'mock_bot'}
        if method == 'getWebhookInfo':
            return {'url': self.webhook}
        if method == 'getChat':
            return self.destination
        if method == 'getUpdates':
            if self.error:
                raise self.error
            return self.updates
        if method == 'sendMessage':
            if self.error:
                raise self.error
            return {'message_id': 600, 'chat': self.destination,
                    'from': {'id': 1234, 'is_bot': True}}
        raise AssertionError(method)


def update(uid=1, text='hello $(touch NEVER_EXECUTED)'):
    return {'update_id': uid, 'message': {
        'message_id': uid + 20, 'date': int(time.time()), 'text': text,
        'from': {'id': 55, 'is_bot': False}, 'chat': {'id': 55, 'type': 'private'}}}


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.home = m.Home(self.path)
        self.cfg = dict(enabled=True, home=str(self.path), bot_id=1234,
                        user_id=55, chat_id=55, since=int(time.time()) - 1)
        m.private_write(self.home.approval_path, json.dumps(self.cfg))
        self.api = MockAPI()
        self.bridge = m.Transport(self.home, self.cfg, self.api)
        self.addCleanup(lambda: self.bridge.db.close())
        self.sleeper = patch.object(m.time, 'sleep')
        self.sleeper.start()
        self.addCleanup(self.sleeper.stop)

    def note(self, uid=1):
        self.bridge.accept(update(uid))
        return self.bridge.db.execute('SELECT note FROM inbound WHERE update_id=?', (uid,)).fetchone()[0]

    def answer(self, note, body='actual authored answer'):
        self.home.inbox('reply', '--json', note, '-', text=body)

    def cli(self, *args):
        with patch.object(sys, 'argv', [SCRIPT, '--home', str(self.path), *args]):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                m.main()
                return out.getvalue()

    def test_private_identity_matrix(self):
        cases = []
        for field, value in [('id', 66), ('is_bot', True)]:
            u = update(); u['message']['from'][field] = value; cases.append(u)
        for field, value in [('id', 66), ('type', 'group'), ('type', 'supergroup'), ('type', 'channel')]:
            u = update(); u['message']['chat'][field] = value; cases.append(u)
        for field in ['forward_origin', 'forward_from', 'forward_sender_name', 'sender_chat', 'via_bot']:
            u = update(); u['message'][field] = {'id': 55}; cases.append(u)
        u = update(); u['message']['date'] = self.cfg['since'] - 1; cases.append(u)
        u = update(); u['edited_message'] = u.pop('message'); cases.append(u)
        for text in ['', '   ', 'x' * 4097, 'nul\x00text']:
            cases.append(update(text=text))
        u = update(); u['message'].pop('text'); u['message']['photo'] = [{}]; cases.append(u)
        for i, u in enumerate(cases, 1):
            u['update_id'] = i
            self.bridge.accept(u)
        self.assertEqual(self.bridge.status()['requests_captured'], 0)
        self.assertEqual(self.api.calls, [])
        self.assertEqual(int(self.bridge.meta('offset')), len(cases) + 1)

    def test_idempotent_capture_and_restart(self):
        note = self.note()
        self.bridge.accept(update())
        restarted = m.Transport(self.home, self.cfg, self.api)
        self.addCleanup(restarted.db.close)
        restarted.accept(update())
        receipts = self.home.inbox('receipts')
        self.assertEqual(len(receipts['pending']), 1)
        self.assertEqual(receipts['pending'][0]['id'], note)
        self.assertIn('$(touch NEVER_EXECUTED)', receipts['pending'][0]['body'])
        self.assertFalse((self.path / 'NEVER_EXECUTED').exists())
        self.assertEqual(len((self.path / 'state' / '.wake-queue').read_text().splitlines()), 1)

    def test_crash_after_inbox_save_before_mapping(self):
        original = self.home.inbox
        saved_note = []
        def save_then_crash(*args, **kwargs):
            doc = original(*args, **kwargs)
            saved_note.append(doc['id'])
            raise m.BridgeError('simulated crash')
        with patch.object(self.home, 'inbox', side_effect=save_then_crash):
            with self.assertRaises(m.BridgeError):
                self.bridge.accept(update())
        self.answer(saved_note[0])  # unusually fast answer before journal recovery
        self.api.updates = [update()]
        self.bridge.cycle()
        self.assertEqual(self.bridge.status()['requests_captured'], 1)
        self.assertEqual(self.bridge.status()['deliveries'], {'sent': 1})
        self.assertEqual(len(self.home.inbox('receipts')['pending']), 1)

    def test_saved_unannounced_not_acknowledged(self):
        real = self.home.inbox
        def fail_notification(*args, **kwargs):
            result = real(*args, **kwargs)
            result['announced'] = False
            return result
        with patch.object(self.home, 'inbox', side_effect=fail_notification):
            with self.assertRaises(m.BridgeError):
                self.bridge.accept(update())
        self.assertEqual(self.bridge.meta('offset'), '')
        self.bridge.accept(update())
        self.assertEqual(self.bridge.meta('offset'), '2')
        self.assertEqual(len(self.home.inbox('receipts')['pending']), 1)

    def test_foreign_reply_and_home_not_exported(self):
        self.note()
        other = self.home.inbox('note', '--request-id', 'unrelated', '--json', '-', text='private record')
        self.answer(other['id'], 'DO NOT EXPORT')
        self.bridge.collect()
        self.assertFalse(self.bridge.send())
        self.assertEqual(self.api.calls, [])
        wrong_cfg = dict(self.cfg, home='/different/home')
        with self.assertRaises(m.BridgeError):
            m.Transport(self.home, wrong_cfg, self.api)
        wrong_user = dict(self.cfg, user_id=77, chat_id=77)
        with self.assertRaises(m.BridgeError):
            m.Transport(self.home, wrong_user, self.api)

    def test_authored_reply_only_and_duplicate_collection(self):
        note = self.note()
        self.answer(note)
        self.bridge.collect(); self.bridge.collect()
        self.assertTrue(self.bridge.send())
        self.assertFalse(self.bridge.send())
        sent = self.api.calls[-1]
        self.assertEqual(sent[0], 'sendMessage')
        self.assertEqual(sent[1]['chat_id'], 55)
        self.assertEqual(sent[1]['text'], 'actual authored answer')
        self.assertNotIn('parse_mode', sent[1])
        self.assertEqual(sent[1]['reply_parameters']['message_id'], 21)
        self.assertEqual(self.bridge.status()['deliveries'], {'sent': 1})
        restarted = m.Transport(self.home, self.cfg, self.api)
        self.addCleanup(restarted.db.close)
        restarted.collect()
        self.assertFalse(restarted.send())

    def test_reply_cursor_pages_not_lost(self):
        for i in range(24):
            note = self.home.inbox('note', '--request-id', f'other-{i}', '--json', '-', text='unrelated')['id']
            self.answer(note, 'private')
        note = self.note()
        self.answer(note, 'only this answer')
        self.bridge.collect()
        self.assertFalse(self.bridge.send())  # first 20 are unrelated
        self.bridge.collect()
        self.assertTrue(self.bridge.send())
        self.assertEqual(self.api.calls[-1][1]['text'], 'only this answer')

    def test_decision_requires_scoped_note_and_is_explicit(self):
        note = self.note()
        with self.assertRaises(m.BridgeError):
            self.bridge.decision('foreign-note', 'private decision')
        self.bridge.decision(note, 'Explicit chat-safe question?')
        self.bridge.decision(note, 'Explicit chat-safe question?')
        self.assertEqual(self.bridge.status()['deliveries'], {'ready': 1})
        self.assertTrue(self.bridge.send())
        self.assertEqual(self.api.calls[-1][1]['text'], 'Explicit chat-safe question?')

    def test_ambiguous_network_not_retried_or_marked_sent(self):
        note = self.note(); self.answer(note); self.bridge.collect()
        self.api.error = m.APIError()
        with self.assertRaisesRegex(m.BridgeError, 'uncertain'):
            self.bridge.send()
        self.api.error = None
        restarted = m.Transport(self.home, self.cfg, self.api)
        self.addCleanup(restarted.db.close)
        with self.assertRaisesRegex(m.BridgeError, 'uncertain'):
            restarted.send()
        self.assertEqual(len(self.api.calls), 1)
        restarted.resolve(1, 'retry')
        restarted.send()
        self.assertEqual(restarted.status()['deliveries'], {'sent': 1})

    def test_interrupted_post_recovered_only_by_consumer(self):
        note = self.note(); self.answer(note); self.bridge.collect()
        with self.bridge.db:
            self.bridge.db.execute("UPDATE delivery SET state='sending'")
        observer = m.Transport(self.home, self.cfg, None, recover=False)
        self.addCleanup(observer.db.close)
        self.assertEqual(observer.status()['deliveries'], {'sending': 1})
        restarted = m.Transport(self.home, self.cfg, self.api)
        self.addCleanup(restarted.db.close)
        self.assertEqual(restarted.status()['deliveries'], {'uncertain': 1})
        restarted.resolve(1, 'sent')
        self.assertFalse(restarted.send())

    def test_explicit_rejection_and_rate_limit_bounded(self):
        note = self.note(); self.answer(note); self.bridge.collect()
        self.api.error = m.APIError(429, 9999999)
        for _ in range(3):
            self.assertTrue(self.bridge.send())
        with self.assertRaisesRegex(m.BridgeError, 'rejected'):
            self.bridge.send()
        self.assertEqual(len(self.api.calls), 4)
        self.bridge.resolve(1, 'retry')
        self.api.error = m.APIError(403)
        with self.assertRaisesRegex(m.BridgeError, 'rejected'):
            self.bridge.send()
        self.assertEqual(self.bridge.status()['deliveries'], {'rejected': 1})

    def test_validate_outbound_response(self):
        note = self.note(); self.answer(note); self.bridge.collect()
        self.api.destination = {'id': 66, 'type': 'private'}
        with self.assertRaisesRegex(m.BridgeError, 'destination'):
            self.bridge.send()
        self.assertEqual(self.bridge.status()['deliveries'], {'uncertain': 1})

    def test_split_unicode_and_partial_recovery(self):
        note = self.note(); self.answer(note, '\U0001f680' * 2500); self.bridge.collect()
        self.bridge.send()
        self.api.error = m.APIError()
        with self.assertRaises(m.BridgeError):
            self.bridge.send()
        self.assertEqual(len(self.api.calls[0][1]['text'].encode('utf-16-le')) // 2, 3500)
        self.bridge.resolve(1, 'sent')  # phone shows the second part arrived
        self.assertFalse(self.bridge.send())
        self.assertEqual(self.bridge.status()['deliveries'], {'sent': 1})

    def test_single_consumer_shared_across_homes(self):
        with m.consumer_lock(1234):
            with self.assertRaisesRegex(m.BridgeError, 'consumer'):
                with m.consumer_lock(1234):
                    self.fail('must not acquire twice')
            # Other bots are independent.
            with m.consumer_lock(5678):
                pass
            # Status/publication may coexist without mutating in-progress POSTs.
            self.assertIn('requests_captured', self.cli('status'))

    def test_existing_webhook_and_poll_conflict(self):
        self.api.webhook = 'https://example.invalid/never-contact'
        with self.assertRaisesRegex(m.BridgeError, 'webhook'):
            self.bridge.cycle()
        self.assertNotIn('getUpdates', [c[0] for c in self.api.calls])
        self.api.webhook = ''; self.api.error = m.APIError(409)
        m.private_write(self.home.config / 'token', TOKEN)
        with patch.object(m, 'API', return_value=self.api):
            with self.assertRaisesRegex(m.BridgeError, 'ownership conflict'):
                self.cli('run')
        self.assertFalse(any(c[0].startswith(('delete', 'set')) for c in self.api.calls))

    def test_inspect_never_enrolls_or_exports_text(self):
        self.home.approval_path.unlink()
        m.private_write(self.home.config / 'token', TOKEN)
        self.api.updates = [update(text='NEVER PRINT THIS')]
        with patch.object(m, 'API', return_value=self.api):
            result = self.cli('inspect')
        self.assertNotIn('NEVER PRINT', result)
        self.assertIn('55', result)
        self.assertFalse(self.home.approval_path.exists())
        self.assertNotIn('offset', self.api.calls[-1][1])
        self.assertEqual(self.bridge.status()['requests_captured'], 0)

    def test_no_historical_export_before_approval(self):
        old = update(); old['message']['date'] = self.cfg['since'] - 10
        self.bridge.accept(old)
        self.assertEqual(self.bridge.status()['requests_captured'], 0)

    def test_offline_missing_secret_and_default_off(self):
        self.home.approval_path.unlink()
        with patch.object(m, 'API', side_effect=AssertionError('must not contact API')):
            with self.assertRaisesRegex(m.BridgeError, 'disabled'):
                self.cli('run')
        m.private_write(self.home.approval_path, json.dumps(self.cfg))
        with patch.object(m, 'API', side_effect=AssertionError('must not contact API')):
            with self.assertRaisesRegex(m.BridgeError, 'No Telegram token'):
                self.cli('run')
        # Status does not read a secret or contact the network.
        self.assertIn('primary', json.loads(self.cli('status')))

    def test_config_permissions_and_local_approval(self):
        m.private_write(self.home.config / 'token', TOKEN)
        os.chmod(self.home.config / 'token', 0o644)
        with self.assertRaisesRegex(m.BridgeError, '0600'):
            self.home.token()
        (self.home.config / 'token').unlink()
        outside = self.path / 'outside'; outside.write_text(TOKEN)
        (self.home.config / 'token').symlink_to(outside)
        with self.assertRaises(OSError):
            self.home.token()
        with self.assertRaises(m.BridgeError):
            self.cli('approve', '--bot-id', '1234', '--user-id', '55', '--chat-id', '66')
        with self.assertRaises(m.BridgeError):
            self.cli('approve', '--bot-id', '1234', '--user-id', '55', '--chat-id', '55')

    def test_limits_backpressure_and_oversized_answer(self):
        with patch.object(m, 'MAX_PENDING', 1):
            note = self.note()
            with self.assertRaisesRegex(m.BridgeError, 'awaiting sent answers'):
                self.bridge.accept(update(2))
            self.assertEqual(self.bridge.meta('offset'), '2')
        self.answer(note, 'x' * (m.MAX_TEXT + 1))
        with self.assertRaises(m.BridgeError):
            self.bridge.collect()
        self.assertEqual(self.bridge.meta('reply_cursor'), '')
        self.assertEqual(self.api.calls, [])

    def test_api_errors_redacted_and_no_redirect(self):
        api = m.API(TOKEN)
        with patch.object(api.opener, 'open', side_effect=OSError('https://api.telegram.org/bot' + TOKEN)):
            with self.assertRaises(m.APIError) as caught:
                api.call('getMe')
        self.assertNotIn(TOKEN, str(caught.exception))
        self.assertIsNone(m.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://evil.invalid'))
        result = subprocess.run([sys.executable, SCRIPT, '--home', str(self.path), 'run'],
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(TOKEN, result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_vault_injected_secret_is_not_passed_to_inbox(self):
        with patch.dict(os.environ, {'FM_TELEGRAM_BOT_TOKEN': TOKEN}):
            self.assertEqual(self.home.token(), TOKEN)
            real_popen = m.subprocess.Popen
            def check_child(*args, **kwargs):
                self.assertNotIn('FM_TELEGRAM_BOT_TOKEN', kwargs['env'])
                return real_popen(*args, **kwargs)
            with patch.object(m.subprocess, 'Popen', side_effect=check_child):
                self.note()
        with patch.object(m.shutil, 'which', return_value='/mock/av'):
            self.assertIn('av save FM_TELEGRAM_BOT_TOKEN', self.cli('setup'))
        self.assertFalse((self.home.config / 'token').exists())

    def test_full_capture_still_drains_answers(self):
        note = self.note()
        self.answer(note)
        self.api.updates = [update(2)]
        with patch.object(m, 'MAX_PENDING', 1):
            self.bridge.cycle()
        self.assertEqual(self.bridge.status()['deliveries'], {'sent': 1})
        self.assertNotIn('getUpdates', [c[0] for c in self.api.calls])
        self.bridge.cycle()
        self.assertEqual(self.bridge.status()['requests_captured'], 2)
        self.assertEqual(self.bridge.meta('offset'), '3')

    def test_revocation_rechecked_both_directions(self):
        note = self.note(); self.answer(note); self.bridge.collect()
        self.cli('disable')
        with self.assertRaises(m.BridgeError):
            self.bridge.accept(update(2))
        with self.assertRaises(m.BridgeError):
            self.bridge.send()
        self.assertEqual(self.api.calls, [])

    def test_approval_new_home_is_local_and_needs_new_messages(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(sys, 'argv', [SCRIPT, '--home', folder, 'approve',
                                           '--bot-id', '1234', '--user-id', '55', '--chat-id', '55']):
                with contextlib.redirect_stdout(io.StringIO()):
                    m.main()
            cfg = m.Home(folder).approval()
            self.assertGreaterEqual(cfg['since'], int(time.time()))
            self.assertEqual((Path(folder) / 'config/telegram/approval.json').stat().st_mode & 0o777, 0o600)
            self.assertFalse((Path(folder) / 'state').exists())

    def test_poll_network_failure_bounded_and_offset_durable(self):
        self.note()
        self.api.error = m.APIError()
        m.private_write(self.home.config / 'token', TOKEN)
        with patch.object(m, 'API', return_value=self.api):
            with self.assertRaisesRegex(m.BridgeError, 'three polls'):
                self.cli('run')
        self.assertEqual(sum(c[0] == 'getUpdates' for c in self.api.calls), 3)
        self.assertEqual(self.bridge.meta('offset'), '2')

    def test_api_protocol_limits_and_redacted_server_description(self):
        api = m.API(TOKEN)
        remote = json.dumps({'ok': False, 'error_code': 429,
                             'description': 'secret URL: /bot' + TOKEN,
                             'parameters': {'retry_after': 999999}}).encode()
        with patch.object(api.opener, 'open', return_value=io.BytesIO(remote)):
            with self.assertRaises(m.APIError) as caught:
                api.call('sendMessage', chat_id=55, text='answer')
        self.assertEqual(caught.exception.code, 429)
        self.assertEqual(caught.exception.retry_after, 300)
        self.assertNotIn(TOKEN, str(caught.exception))
        with patch.object(api.opener, 'open', return_value=io.BytesIO(b'x' * (m.MAX_RESPONSE + 1))):
            with self.assertRaises(m.APIError):
                api.call('getUpdates')
        remote = json.dumps({'ok': True, 'result': {'id': 1234}}).encode()
        with patch.object(api.opener, 'open', return_value=io.BytesIO(remote)):
            self.assertEqual(api.call('getMe')['id'], 1234)

    def test_completed_retention_does_not_prune_pending(self):
        with self.bridge.db:
            for i in range(1002):
                self.bridge.db.execute('INSERT INTO inbound VALUES (?,?,?,?)',
                                       (i + 10, f'note-{i}', f'request-{i}', i + 1))
                self.bridge.db.execute("INSERT INTO delivery (note,kind,body,state) VALUES (?,'reply','','sent')",
                                       (f'note-{i}',))
            self.bridge.db.execute('INSERT INTO inbound VALUES (9999,?,?,99)', ('pending', 'pending-request'))
        self.bridge.cycle()
        self.assertEqual(self.bridge.status()['requests_captured'], 1001)
        self.assertEqual(self.bridge.status()['requests_without_collected_answer'], 1)
        self.assertTrue(self.bridge.db.execute("SELECT 1 FROM inbound WHERE note='pending'").fetchone())
        self.assertLessEqual((self.home.state / 'transport.sqlite3').stat().st_size, 16 * 1024 * 1024)

    def test_disable_no_network(self):
        self.cli('disable')
        with self.assertRaisesRegex(m.BridgeError, 'disabled'):
            self.home.approval()
        self.assertEqual(self.api.calls, [])


os.umask(0o077)
unittest.main(argv=['fm-telegram'], verbosity=1)
PY
pass "Telegram transport synthetic/private-home regression"
