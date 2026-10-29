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
        bot.get_chat_member.side_effect = [NS(status='member'), NS(status='left')]
        self.assertEqual(await self.service.eligibility(bot, 7), 'join_required')
        bot.get_chat_member.side_effect = [NS(status='administrator'), NS(status='restricted', is_member=True)]
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
