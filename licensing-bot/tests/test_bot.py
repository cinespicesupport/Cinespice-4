import asyncio
import base64
import json
from pathlib import Path
from types import SimpleNamespace as NS
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from telegram.error import TelegramError, RetryAfter
from cinespice_bot.config import Settings
from cinespice_bot.protocol import Signer, generate_key
from cinespice_bot.service import AccessService, is_member
from cinespice_bot.storage import Store
from cinespice_bot.__main__ import build_application


class BotTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.path = Path(self.temp.name)
        generate_key(self.path/'key.pem'); self.signer = Signer(self.path/'key.pem')
        self.store = Store(self.path/'bot.db')
        self.settings = Settings('123456:synthetic-test-token', 'synthetic_bot', 123456, -1001, frozenset({42}),
            'https://t.me/contact_group', ({'id': -1002, 'title': 'Community', 'url': 'https://t.me/community'},), self.path/'key.pem', self.path/'bot.db', 3600)
        self.service = AccessService(self.settings, self.store, self.signer)
    def tearDown(self):
        self.store.close(); self.temp.cleanup()
    async def test_all_membership_requirements_and_fail_closed(self):
        bot = NS(get_chat_member=AsyncMock(return_value=NS(status='member')))
        self.assertEqual(await self.service.eligibility(bot, 7), 'not_started'); bot.get_chat_member.assert_not_called()
        self.store.start(7)
        bot.get_chat_member.side_effect = [NS(status='left')]
        self.assertEqual(await self.service.eligibility(bot, 7), 'unpaid')
        bot.get_chat_member.side_effect = [NS(status='member')]
        self.assertEqual(await self.service.eligibility(bot, 7), 'authorized')
        bot.get_chat_member.side_effect = [NS(status='administrator')]
        self.assertEqual(await self.service.eligibility(bot, 7), 'authorized')
        bot.get_chat_member.side_effect = TelegramError('synthetic outage')
        self.assertEqual(await self.service.eligibility(bot, 7), 'unavailable')
        bot.get_chat_member.side_effect = RetryAfter(7)
        self.assertEqual(await self.service.eligibility(bot, 7), 'unavailable')
        with self.assertRaises(RetryAfter): await self.service.eligibility(bot, 7, propagate_rate_limit=True)
        self.assertFalse(is_member(NS(status='restricted', is_member=False)))
        self.assertFalse(is_member(NS(status='kicked')))
    def test_signature_is_real_and_account_bound(self):
        token = self.signer.receipt(7, 'a'*32, 'authorized', 3600, now=1800000000)
        prefix, payload, signature = token.split('.')
        raw = base64.urlsafe_b64decode(signature+'='*(-len(signature)%4))
        key = serialization.load_der_public_key(base64.b64decode(self.signer.public_key()))
        key.verify(raw, (prefix+'.'+payload).encode(), ec.ECDSA(hashes.SHA256()))
        with self.assertRaises(InvalidSignature): key.verify(raw, (prefix+'.'+payload+'x').encode(), ec.ECDSA(hashes.SHA256()))
        value = json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
        self.assertEqual((value['uid'],value['nonce'],value['exp']),('7','a'*32,1800003600))
        with self.assertRaises(ValueError): self.signer.receipt(7, 'a'*32, 'revoked', 60, device='b'*24, persistent=True)
        for args in [(0,'a'*32,'authorized',3600),(7,'wrong','authorized',3600),(7,'a'*32,'bad',3600),(7,'a'*32,'authorized',86401)]:
            with self.assertRaises(ValueError): self.signer.receipt(*args)
        with self.assertRaises(FileExistsError): generate_key(self.path/'key.pem')
    def test_broadcast_queue_survives_restart_and_is_idempotent(self):
        self.store.start(7); self.store.start(8)
        self.assertEqual(self.store.queue('campaign',42,99),2); self.assertEqual(self.store.queue('campaign',42,99),2)
        self.store.delivered('campaign',7); self.store.retry('campaign',8,100)
        self.store.close(); self.store = Store(self.path/'bot.db')
        self.assertIsNone(self.store.next_delivery()); self.assertEqual(self.store.stats(),(2,{'pending':1,'sent':1}))
        self.store.retry('campaign',8,0); self.assertEqual(self.store.next_delivery(),('campaign',8,42,99,2))
    def callbacks(self):
        app = build_application(self.settings,self.store,self.signer)
        return {command: handler.callback for handler in app.handlers[0] for command in getattr(handler,'commands',[])}, app
    def update(self, uid=7, text='/start cs_'+'a'*32, chat_type='private'):
        message=NS(text=text,reply_text=AsyncMock(),reply_to_message=None)
        return NS(effective_chat=NS(type=chat_type,id=uid),effective_user=NS(id=uid),effective_message=message)
    async def test_start_signs_actual_sender_not_supplied_id(self):
        callbacks,_=self.callbacks(); update=self.update()
        context=NS(args=['cs_'+'a'*32],bot=NS(get_chat_member=AsyncMock(return_value=NS(status='member'))))
        await callbacks['start'](update,context)
        self.assertTrue(self.store.started(7)); self.assertFalse(self.store.started(42))
        token=update.effective_message.reply_text.call_args_list[-1].args[0]
        value=json.loads(base64.urlsafe_b64decode(token.split('.')[1]+'=='))
        self.assertEqual(value['uid'],'7'); self.assertEqual(value['status'],'authorized')
    async def test_paid_member_can_activate_and_transfer_one_device(self):
        async def request(command, device, nonce):
            callbacks, _ = self.callbacks()  # independent command cooldown
            update = self.update(text='/' + command)
            update.effective_message.message_id = 123
            update.effective_message.reply_text.return_value = NS(message_id=456)
            args = ['cs2_' + device + '_' + nonce] if command == 'start' else [nonce, device]
            bot = NS(get_chat_member=AsyncMock(return_value=NS(status='member')))
            await callbacks[command](update, NS(args=args, bot=bot))
            token = update.effective_message.reply_text.call_args_list[-1].args[0]
            return json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '=='))
        first = await request('start', 'a'*24, '1'*32)
        self.assertEqual((first['status'], first['persistent'], first['device']), ('authorized', True, 'a'*24))
        second = await request('start', 'b'*24, '2'*32)
        self.assertEqual((second['status'], second['revision']), ('authorized', 1))
        self.assertEqual(self.store.next_access_event(), (7, 1))
        old = await request('check', 'a'*24, '3'*32)
        self.assertEqual(old['status'], 'other_device')
        self.assertNotIn('persistent', old)
        same = await request('check', 'b'*24, '4'*32)
        self.assertEqual((same['status'], same['revision']), ('authorized', 1))
        self.store.close(); self.store = Store(self.path/'bot.db')
        self.assertFalse(self.store.authorize_device(7, 'a'*24, transfer=False))

    async def test_membership_change_during_verification_cannot_sign_stale_grant(self):
        callbacks, _ = self.callbacks()
        update = self.update(text='/start')
        update.effective_message.message_id = 123
        update.effective_message.reply_text.return_value = NS(message_id=456)
        async def lookup(chat, uid):
            if chat == -1002: self.store.access_changed(uid)
            return NS(status='member')
        await callbacks['start'](update, NS(args=['cs2_' + 'a'*24 + '_' + 'b'*32],
                                           bot=NS(get_chat_member=AsyncMock(side_effect=lookup))))
        token = update.effective_message.reply_text.call_args_list[-1].args[0]
        value = json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '=='))
        self.assertEqual(value['status'], 'unavailable')
        self.assertIsNone(self.store.db.execute('SELECT device FROM active_devices WHERE user_id=7').fetchone())

    async def test_optional_channel_does_not_block_activation(self):
        self.store.start(7)
        bot = NS(get_chat_member=AsyncMock(side_effect=[NS(status='member'), NS(status='left')]))
        self.assertEqual(await self.service.requirements(bot, 7), ('authorized', False, [0]))
        bot.get_chat_member.side_effect = [NS(status='member'), TelegramError('channel unavailable')]
        self.assertEqual(await self.service.requirements(bot, 7), ('authorized', False, []))

    async def test_invalid_nonce_and_group_chat_never_issue_receipt(self):
        callbacks,_=self.callbacks()
        for update,args in [(self.update(),['42']), (self.update(chat_type='group'),['cs_'+'a'*32])]:
            await callbacks['start'](update,NS(args=args))
            self.assertFalse(any(str(call.args[0]).startswith('CSP1.') for call in update.effective_message.reply_text.call_args_list))
    async def test_admin_broadcast_and_stats_are_restricted(self):
        callbacks,_=self.callbacks(); update=self.update(text='/broadcast')
        await callbacks['broadcast'](update,NS()); await callbacks['stats'](update,NS())
        update.effective_message.reply_text.assert_not_called()
    async def test_welcome_parameter_is_valid_without_nonce(self):
        callbacks,_=self.callbacks(); update=self.update(text='/start welcome')
        await callbacks['start'](update,NS(args=['welcome'],bot=NS(get_chat_member=AsyncMock(return_value=NS(status='left')))))
        self.assertTrue(self.store.started(7)); self.assertEqual(update.effective_message.reply_text.call_count,1)
    def test_config_rejects_public_contact_as_paid_channel(self):
        env={'BOT_TOKEN':'synthetic','BOT_USERNAME':'sample_bot','BOT_USER_ID':'123','PAID_GROUP_ID':'-1001','ADMIN_IDS':'42','CONTACT_URL':'https://t.me/contact_group','REQUIRED_CHANNELS':'[{"id":-1001,"title":"Bad","url":"https://t.me/community"}]'}
        with patch.dict('os.environ',env,clear=True),self.assertRaises(ValueError): Settings.load()

    async def test_revocation_survives_restart_and_rejoin_does_not_restore_it(self):
        self.store.start(7)
        self.store.access_changed(7, revoked=True)
        self.store.access_changed(7)  # group membership update
        self.store.close(); self.store = Store(self.path/'bot.db')
        self.service = AccessService(self.settings, self.store, self.signer)
        bot = NS(get_chat_member=AsyncMock(return_value=NS(status='member')))
        self.assertEqual(await self.service.requirements(bot,7), ('revoked',False,[]))
        bot.get_chat_member.assert_not_called()
        self.assertEqual(self.store.next_access_event(), (7,2))
        self.store.finish_access_event(7,1)  # stale delivery cannot swallow newer revocation
        self.assertEqual(self.store.next_access_event(), (7,2))
        self.store.finish_access_event(7,2,retry=True)
        self.assertIsNone(self.store.next_access_event())
        self.store.access_changed(7, revoked=False)
        self.assertEqual(await self.service.requirements(bot,7), ('authorized',False,[]))

    async def test_requirements_collect_all_missing_and_fail_closed(self):
        self.store.start(7)
        bot = NS(get_chat_member=AsyncMock(side_effect=[NS(status='left'),NS(status='kicked')]))
        self.assertEqual(await self.service.requirements(bot,7), ('unpaid',True,[0]))
        bot.get_chat_member.side_effect = TelegramError('outage')
        self.assertEqual(await self.service.requirements(bot,7), ('unavailable',False,[]))

    def test_membership_reconciliation_detects_changes_after_restart(self):
        self.store.start(7)
        self.store.observe_paid_membership(7, True)
        self.store.schedule_membership_reconciliation()
        uid, old, revision = self.store.next_membership_check()
        self.store.complete_membership_check(uid, old, revision, False)
        self.assertEqual(self.store.next_access_event(), (7, 1))
        self.store.finish_access_event(7, 1)
        self.store.close(); self.store = Store(self.path/'bot.db')
        self.store.schedule_membership_reconciliation()
        uid, old, revision = self.store.next_membership_check()
        self.assertEqual(old, 0)
        self.store.complete_membership_check(uid, old, revision, True)
        self.assertEqual(self.store.next_access_event(), (7, 2))
        self.store.finish_access_event(7, 2)
        self.store.schedule_membership_reconciliation()
        uid, old, revision = self.store.next_membership_check()
        self.store.complete_membership_check(uid, old, revision, True)
        self.assertIsNone(self.store.next_access_event())

    def test_membership_reconciliation_handles_unknown_and_inflight_update(self):
        self.store.start(7)
        self.store.schedule_membership_reconciliation()
        uid, old, revision = self.store.next_membership_check()
        # A group event arrives while the lookup is awaiting Telegram.
        self.store.access_changed(7)
        self.store.observe_paid_membership(7, False)
        self.store.complete_membership_check(uid, old, revision, True)
        self.assertEqual(self.store.next_access_event(), (7, 1))
        self.assertEqual(self.store.next_membership_check(), (7, 0, 1))
        self.store.finish_access_event(7, 1)
        uid, old, revision = self.store.next_membership_check()
        self.store.complete_membership_check(uid, old, revision, False)
        self.assertIsNone(self.store.next_access_event())
        self.store.start(8)
        self.store.schedule_membership_reconciliation()
        self.store.complete_membership_check(*self.store.next_membership_check(), False)
        uid, old, revision = self.store.next_membership_check()
        self.assertEqual((uid, old), (8, None))
        self.store.complete_membership_check(uid, old, revision, True)
        self.assertEqual(self.store.next_access_event(), (8, 1))

    def test_membership_retry_preserves_known_status_and_restart_retries(self):
        self.store.start(7); self.store.observe_paid_membership(7, True)
        self.store.schedule_membership_reconciliation()
        self.store.retry_membership_check(7, 30)
        self.assertIsNone(self.store.next_membership_check())
        self.assertIsNone(self.store.next_access_event())
        self.store.close(); self.store=Store(self.path/'bot.db')
        self.store.schedule_membership_reconciliation()
        self.assertEqual(self.store.next_membership_check(), (7, 1, 0))

    def test_clear_queue_survives_restart_and_cancels_only_old_pending_broadcasts(self):
        self.store.start(7); self.store.start(8)
        self.store.queue('old',42,99); self.store.delivered('old',7)
        self.assertEqual(self.store.clear_notifications('clear1'),2)
        self.assertIsNone(self.store.next_delivery())
        self.assertEqual(self.store.stats(),(2,{'cleared':1,'sent':1}))
        self.store.queue('new',42,100)
        self.store.close(); self.store = Store(self.path/'bot.db')
        self.assertEqual(self.store.next_notice_clear(),(7,'clear1'))
        self.assertTrue(self.store.notice_clear_pending(7))
        self.store.clear_notifications('clear2')
        self.store.finish_notice_clear(7,'clear1')
        self.assertEqual(self.store.next_notice_clear(),(7,'clear2'))
        self.store.finish_notice_clear(7,'clear2',30)
        self.assertEqual(self.store.next_notice_clear(),(8,'clear2'))
        self.assertTrue(self.store.notice_clear_pending(7))
        self.store.finish_notice_clear(8,'clear2')
        self.assertFalse(self.store.notice_clear_pending(8))

    def test_selected_delete_is_durable_idempotent_and_does_not_cancel_other_campaigns(self):
        self.store.start(7); self.store.start(8)
        self.store.queue('first',42,99); self.store.queue('second',42,100)
        self.store.delivered('first',7)
        self.assertEqual(self.store.delete_notification('first'),2)
        self.assertIsNone(self.store.delete_notification('first'))
        self.assertEqual(self.store.queue('first',42,99),0)
        self.assertTrue(self.store.campaign_active('second'))
        self.assertEqual(self.store.campaigns_for(42,99),[])
        self.store.finish_notice_delete(7,'first',3600)
        self.store.close(); self.store=Store(self.path/'bot.db')
        self.assertEqual(self.store.next_notice_delete(),(8,'first'))
        self.store.finish_notice_delete(8,'first')
        self.assertIsNone(self.store.next_notice_delete())
        self.store.start(7)
        self.assertEqual(self.store.next_notice_delete(),(7,'first'))
        self.assertTrue(self.store.delivery_pending('second',7))

    def test_campaign_catalog_migrates_existing_database(self):
        self.store.start(7); self.store.queue('old',42,99)
        self.store.db.execute('DROP TABLE campaigns'); self.store.db.commit()
        self.store.close(); self.store=Store(self.path/'bot.db')
        self.assertEqual(self.store.campaigns_for(42,99),['old'])
        self.assertEqual(self.store.delete_notification('old'),1)

if __name__ == '__main__': unittest.main()
