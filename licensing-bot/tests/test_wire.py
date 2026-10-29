"""Exercise actual PTB update parsing, command routing and API serialization without a network."""
import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from telegram import Update
from telegram.request import BaseRequest
from cinespice_bot.__main__ import build_application
from cinespice_bot.config import ConfigurationError, Settings
from cinespice_bot.protocol import Signer, generate_key
from cinespice_bot.storage import Store


class SyntheticAPI(BaseRequest):
    def __init__(self):
        super().__init__(); self.calls=[]; self.delivered=asyncio.Event(); self.retry=True
    @property
    def read_timeout(self): return 5
    async def initialize(self): pass
    async def shutdown(self): pass
    async def do_request(self,url,method,request_data=None,**kwargs):
        name=url.rsplit('/',1)[-1]; args=request_data.parameters if request_data else {}
        self.calls.append((name,args))
        if getattr(self, 'failure', None) == (name, args.get('chat_id')):
            return getattr(self, 'failure_code', 400), json.dumps({'ok': False, 'description': 'Synthetic private detail: 123456:synthetic-token', 'error_code': getattr(self, 'failure_code', 400)}).encode()
        if name=='getMe': value={'id':123457 if getattr(self,'wrong_identity',False) else 123456,'is_bot':True,'first_name':'Access','username':'synthetic_bot'}
        elif name=='getChat': value={'id':-1001,'type':'supergroup','title':'Private paid group','accent_color_id':0,'max_reaction_count':11,**({'username':'public_paid_group'} if getattr(self,'public_group',False) else {})}
        elif name=='getChatMember':
            uid=int(args['user_id'])
            if uid != 123456 and getattr(self,'on_member_lookup',None): self.on_member_lookup()
            status = 'creator' if uid == 123456 else 'left' if uid == 8 else 'member'
            if uid == 123456 and args.get('chat_id') == getattr(self, 'non_admin_chat', None):
                status = 'member'
            value={'is_anonymous':False,'status':status,'user':{'id':uid,'is_bot':uid==123456,'first_name':'Synthetic'}}
        elif name=='copyMessage':
            if int(args['chat_id'])==7:
                if self.retry:
                    self.retry=False
                    return 429,json.dumps({'ok':False,'error_code':429,'description':'Too Many Requests','parameters':{'retry_after':1}}).encode()
                self.delivered.set()
            value={'message_id':99}
        elif name in {'sendMessage','editMessageText'}:
            value={'message_id':99,'date':1800000000,'chat':{'id':int(args['chat_id']),'type':'private'},'text':args.get('text','')}
        elif name in {'deleteWebhook','answerCallbackQuery','deleteMessage','setMyCommands'}: value=True
        else: raise AssertionError(name)
        return 200,json.dumps({'ok':True,'result':value}).encode()


class WireTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory(); p=Path(self.temp.name); generate_key(p/'key')
        self.store=Store(p/'db'); self.api=SyntheticAPI()
        self.settings=Settings('123456:synthetic-token','synthetic_bot',123456,-1001,frozenset({42}),'https://t.me/contact',({'id':-1002,'title':'Channel','url':'https://t.me/channel'},),p/'key',p/'db',60)
        self.app=build_application(self.settings,self.store,Signer(p/'key'),request=self.api)
        await self.app.initialize(); await self.app.start(); await self.app.post_init(self.app)
    async def asyncTearDown(self):
        await self.app.stop(); await self.app.post_stop(self.app); await self.app.shutdown(); self.temp.cleanup()
    async def message(self,uid,text,reply=None):
        data={'update_id':1,'message':{'message_id':20,'date':1800000000,'chat':{'id':uid,'type':'private'},'from':{'id':uid,'is_bot':False,'first_name':'Synthetic'},'text':text,'entities':[{'type':'bot_command','offset':0,'length':len(text.split()[0])}]}}
        if reply: data['message']['reply_to_message']=reply
        await self.app.process_update(Update.de_json(data,self.app.bot))
    async def test_real_command_routing_and_confirmed_broadcast_with_retry(self):
        await self.message(7,'/start cs_'+'a'*32)
        replies=[a['text'] for name,a in self.api.calls if name=='sendMessage' and int(a['chat_id'])==7]
        self.assertTrue(any(t.startswith('CSP1.') for t in replies)); self.assertTrue(self.store.started(7))
        self.store.start(8) # unpaid recipients must be excluded by the worker
        source={'message_id':50,'date':1800000000,'chat':{'id':42,'type':'private'},'text':'Hello members','entities':[{'type':'bold','offset':0,'length':5}]}
        await self.message(42,'/broadcast',source)
        campaign=self.app.user_data[42]['broadcast'][0]
        preview=next(args for name,args in reversed(self.api.calls) if name=='copyMessage')
        self.assertIn('notice-preview:1:'+campaign,str(preview['reply_markup']))
        self.assertNotIn('notice:1:',str(preview['reply_markup']))
        query={'update_id':2,'callback_query':{'id':'confirm','from':{'id':42,'is_bot':False,'first_name':'Owner'},'chat_instance':'synthetic','data':'publish:'+campaign,'message':{'message_id':99,'date':1800000000,'chat':{'id':42,'type':'private'},'text':'Publish?'}}}
        await self.app.process_update(Update.de_json(query,self.app.bot))
        await asyncio.wait_for(self.api.delivered.wait(),timeout=8)
        # Let the same worker finish its SQLite acknowledgement and ineligible recipient.
        for _ in range(50):
            if self.store.stats()[1].get('ineligible')==1: break
            await asyncio.sleep(.02)
        self.assertEqual(self.store.stats(),(2,{'ineligible':1,'sent':1}))
        deliveries=[a for name,a in self.api.calls if name=='copyMessage' and int(a['chat_id'])==7]
        self.assertEqual(len(deliveries),2) # RetryAfter then successful copy
        self.assertEqual(int(deliveries[-1]['from_chat_id']),42)
        self.assertIn('notice:1:'+campaign,str(deliveries[-1]['reply_markup']))
        self.assertFalse(any(name=='copyMessage' and int(a['chat_id'])==8 for name,a in self.api.calls))
        # Reusing the confirmation cannot enqueue a second campaign.
        await self.app.process_update(Update.de_json(query,self.app.bot))
        self.assertEqual(self.store.stats()[0],2)
    async def test_new_paid_member_gets_group_welcome_with_start_button(self):
        user={'id':7,'is_bot':False,'first_name':'Buyer'}
        update={'update_id':3,'chat_member':{'chat':{'id':-1001,'type':'supergroup','title':'Paid'},'from':{'id':42,'is_bot':False,'first_name':'Owner'},'date':1800000000,'old_chat_member':{'user':user,'status':'left'},'new_chat_member':{'user':user,'status':'member'}}}
        await self.app.process_update(Update.de_json(update,self.app.bot))
        welcomes=[a for name,a in self.api.calls if name=='sendMessage' and int(a['chat_id'])==-1001]
        self.assertEqual(len(welcomes),1); self.assertIn('start=welcome',str(welcomes[0]['reply_markup']))
        await self.app.process_update(Update.de_json(update,self.app.bot))
        self.assertEqual(len([1 for name,a in self.api.calls if name=='sendMessage' and int(a['chat_id'])==-1001]),1)

    async def test_public_paid_group_is_rejected(self):
        self.api.public_group = True
        with self.assertRaises(ValueError): await self.app.post_init(self.app)

    async def test_rejected_startup_requests_identify_configuration_without_private_details(self):
        for code in (400, 403):
            self.api.failure_code = code
            for name, chat, field in [('getMe', None, 'BOT_TOKEN'), ('getChat', -1001, 'PAID_GROUP_ID'),
                                      ('getChatMember', -1001, 'PAID_GROUP_ID'),
                                      ('getChatMember', -1002, 'REQUIRED_CHANNELS entry 1'),
                                      ('deleteWebhook', None, 'deleteWebhook')]:
                with self.subTest(code=code, operation=name, field=field):
                    self.api.failure = (name, chat)
                    self.api.calls.clear()
                    with self.assertRaises(ConfigurationError) as caught:
                        await self.app.post_init(self.app)
                    self.assertIn(field, str(caught.exception))
                    self.assertNotIn('synthetic-token', str(caught.exception))
                    self.assertNotIn('Synthetic private detail', str(caught.exception))
                    if name != 'deleteWebhook':
                        self.assertFalse(any(operation == 'deleteWebhook' for operation, _ in self.api.calls))

    async def test_non_admin_chat_is_named_and_startup_stops(self):
        for chat, field in [(-1001, 'PAID_GROUP_ID'), (-1002, 'REQUIRED_CHANNELS entry 1')]:
            with self.subTest(field=field):
                self.api.non_admin_chat = chat
                self.api.calls.clear()
                with self.assertRaises(ConfigurationError) as caught:
                    await self.app.post_init(self.app)
                self.assertIn(field, str(caught.exception))
                self.assertIn('administrator', str(caught.exception))
                self.assertFalse(any(operation == 'deleteWebhook' for operation, _ in self.api.calls))

    async def test_identity_mismatch_is_named_and_stops_before_chat_requests(self):
        self.api.wrong_identity = True
        self.api.calls.clear()
        with self.assertRaises(ConfigurationError) as caught:
            await self.app.post_init(self.app)
        self.assertIn('BOT_USER_ID or BOT_USERNAME', str(caught.exception))
        self.assertFalse(any(operation == 'getChat' for operation, _ in self.api.calls))

    async def test_device_activation_ack_hides_receipt_and_deletes_commands(self):
        import base64
        nonce, device = 'b'*32, 'c'*24
        await self.message(7, '/start cs2_' + device + '_' + nonce)
        replies = [a for name,a in self.api.calls if name == 'sendMessage' and a['chat_id'] == 7]
        self.assertEqual(len(replies), 1)
        self.assertTrue(replies[0]['disable_notification'])
        payload = json.loads(base64.urlsafe_b64decode(replies[0]['text'].split('.')[1] + '=='))
        self.assertEqual((payload['uid'], payload['device'], payload['revision'], payload['status']), ('7',device,0,'authorized'))
        self.assertEqual((payload['paid'],payload['missing']), (False,[]))
        # Another user cannot acknowledge or erase this account's receipt.
        await self.message(8, '/verified ' + nonce)
        self.assertIsNotNone(self.store.pending_receipt(7, nonce))
        await self.message(7, '/verified ' + nonce)
        self.assertIsNone(self.store.pending_receipt(7, nonce))
        edits = [a for name,a in self.api.calls if name == 'editMessageText']
        self.assertEqual(edits[-1]['text'], 'Verified ✅')
        self.assertTrue(any(name == 'deleteMessage' and a['chat_id'] == 7 for name,a in self.api.calls))

    async def test_missing_requirements_and_admin_revocation(self):
        import base64
        await self.message(8, '/start cs2_' + 'c'*24 + '_' + 'd'*32)
        text = [a['text'] for name,a in self.api.calls if name == 'sendMessage' and a['chat_id'] == 8][-1]
        value = json.loads(base64.urlsafe_b64decode(text.split('.')[1] + '=='))
        self.assertEqual((value['status'],value['paid'],value['missing']), ('unpaid',True,[0]))
        await self.message(7, '/revoke 8')
        self.assertEqual(self.store.access_state(8), (False,0))
        await self.message(42, '/revoke 8')
        self.assertEqual(self.store.access_state(8), (True,1))
        await self.message(42, '/restore 8')
        self.assertEqual(self.store.access_state(8), (False,2))

    async def test_channel_departure_ban_and_return_emit_durable_events(self):
        self.store.start(7)
        user={'id':7,'is_bot':False,'first_name':'Buyer'}
        for old,new in [('member','left'),('left','member'),('member','kicked')]:
            update={'update_id':4,'chat_member':{'chat':{'id':-1002,'type':'channel','title':'Required'},'from':{'id':42,'is_bot':False,'first_name':'Owner'},'date':1800000000,
                'old_chat_member':{'user':user,'status':old,'until_date':0},'new_chat_member':{'user':user,'status':new,'until_date':0}}}
            await self.app.process_update(Update.de_json(update,self.app.bot))
        self.assertEqual(self.store.access_state(7),(False,3))
        self.assertEqual(self.store.next_access_event(),(7,3))
        # Worker eventually sends an authenticated bot-chat invalidation, not an access grant.
        for _ in range(100):
            if any(name=='sendMessage' and 'access:1:3' in str(a.get('reply_markup')) for name,a in self.api.calls): break
            await asyncio.sleep(.02)
        self.assertTrue(any(name=='sendMessage' and 'access:1:3' in str(a.get('reply_markup')) for name,a in self.api.calls))

    async def test_ack_after_revoke_does_not_claim_verified(self):
        nonce = 'e'*32
        await self.message(7, '/start cs2_' + 'c'*24 + '_' + nonce)
        await self.message(42, '/revoke 7')
        await self.message(7, '/verified ' + nonce)
        edits = [a for name,a in self.api.calls if name=='editMessageText']
        self.assertIn('revoked', edits[-1]['text'])

    async def test_clear_notifications_is_admin_only_and_sends_durable_clear_marker(self):
        self.store.start(7)
        await self.message(7,'/clearall')
        self.assertIsNone(self.store.next_notice_clear())
        await self.message(42,'/clearall')
        self.assertTrue(self.store.notice_clear_pending(7))
        for _ in range(100):
            if any(name=='sendMessage' and a['chat_id']==7 and 'notice-clear:1:' in str(a.get('reply_markup')) for name,a in self.api.calls): break
            await asyncio.sleep(.02)
        clears=[a for name,a in self.api.calls if name=='sendMessage' and a['chat_id']==7 and 'notice-clear:1:' in str(a.get('reply_markup'))]
        self.assertEqual(len(clears),1)
        self.assertTrue(clears[0]['disable_notification'])
        self.assertFalse(self.store.notice_clear_pending(7))

    async def test_failed_clear_retries_before_any_new_broadcast(self):
        self.store.start(7)
        self.api.failure=('sendMessage',7)
        self.api.failure_code=403
        self.store.clear_notifications('a'*32)
        self.store.queue('new',42,50)
        for _ in range(100):
            if self.store.db.execute('SELECT next_try FROM notice_clears WHERE user_id=7').fetchone()[0] > 0: break
            await asyncio.sleep(.02)
        self.assertTrue(self.store.notice_clear_pending(7))
        self.assertFalse(any(name=='copyMessage' for name,_ in self.api.calls))
        self.assertEqual(self.store.db.execute("SELECT attempts FROM deliveries WHERE campaign='new' AND user_id=7").fetchone()[0],0)
        self.api.failure=None
        with self.store.db:
            self.store.db.execute('UPDATE notice_clears SET next_try=0')
            self.store.db.execute('UPDATE deliveries SET next_try=0')
        self.api.retry=False
        await asyncio.wait_for(self.api.delivered.wait(),timeout=5)
        self.assertFalse(self.store.notice_clear_pending(7))
        # A successfully completed clear removes the durable gate before copyMessage.
        self.assertTrue(any(name=='sendMessage' and 'notice-clear:1:' in str(args.get('reply_markup')) for name,args in self.api.calls))

    async def callback(self, uid, data):
        query={'update_id':5,'callback_query':{'id':'select','from':{'id':uid,'is_bot':False,'first_name':'Synthetic'},'chat_instance':'synthetic','data':data,'message':{'message_id':99,'date':1800000000,'chat':{'id':uid,'type':'private'},'text':'Confirm?'}}}
        await self.app.process_update(Update.de_json(query,self.app.bot))

    async def test_normal_start_and_help_show_public_welcome_without_verification(self):
        self.api.calls.clear()
        await self.message(7, '/start')
        await self.message(7, '/help')
        replies=[args for name,args in self.api.calls if name=='sendMessage']
        self.assertEqual(len(replies),2)
        self.assertIn('Welcome to Cinespice',replies[0]['text'])
        self.assertIn('chat group',replies[1]['text'])
        for reply in replies:
            self.assertIn('Join chat group',str(reply['reply_markup']))
            self.assertIn('Contact me',str(reply['reply_markup']))
            self.assertIn('https://t.me/channel',str(reply['reply_markup']))
            self.assertNotIn('/broadcast',reply['text'])
            self.assertNotIn('CSP1.',reply['text'])
        self.assertFalse(any(name=='getChatMember' for name,args in self.api.calls))
        self.assertTrue(self.store.started(7))

    async def test_menu_scopes_and_admin_command_guards(self):
        menus=[args for name,args in self.api.calls if name=='setMyCommands']
        public=next(args for args in menus if args['scope']['type']=='all_private_chats')
        admin=next(args for args in menus if args['scope']['type']=='chat')
        self.assertEqual([c['command'] for c in public['commands']],['start','help'])
        self.assertIn('clearall',[c['command'] for c in admin['commands']])
        self.assertEqual(admin['scope']['chat_id'],42)
        self.api.calls.clear()
        for command in ['/clear','/clear_notifications','/clearall','/broadcast','/stats','/id','/revoke 7','/restore 7']:
            await self.message(7,command)
        self.assertFalse(any(name=='sendMessage' for name,args in self.api.calls))

    async def test_clear_reply_selects_one_campaign_and_enforces_callback_admin(self):
        # Future retry deadlines keep copies out of the background worker while commands are exercised.
        self.store.start(7)
        first, second = 'd'*32, 'e'*32
        self.store.queue(first,42,50); self.store.queue(second,42,51)
        self.store.retry(first,7,3600); self.store.retry(second,7,3600)
        source={'message_id':50,'date':1800000000,'chat':{'id':42,'type':'private'},'text':'First announcement'}
        await self.message(42,'/clear',source)
        reply=next(args for name,args in reversed(self.api.calls) if name=='sendMessage' and args['chat_id']==42)
        self.assertIn('delete-notice:'+first,str(reply['reply_markup']))
        self.assertNotIn(second,str(reply['reply_markup']))
        await self.callback(7,'delete-notice:'+first)
        self.assertTrue(self.store.campaign_active(first))
        await self.callback(42,'delete-notice:'+first)
        self.assertFalse(self.store.campaign_active(first)); self.assertTrue(self.store.campaign_active(second))
        self.assertTrue(self.store.delivery_pending(second,7)); self.assertFalse(self.store.delivery_pending(first,7))
        for _ in range(100):
            sent=[args for name,args in self.api.calls if name=='sendMessage' and args['chat_id']==7 and 'notice-delete:1:'+first in str(args.get('reply_markup'))]
            if sent: break
            await asyncio.sleep(.02)
        self.assertTrue(sent); self.assertTrue(sent[0]['disable_notification'])

    async def test_clear_alias_needs_selection_and_handles_repeated_broadcast_source(self):
        first, second = 'd'*32, 'e'*32
        self.store.queue(first,42,50); self.store.queue(second,42,50)
        await self.message(42,'/clear_notifications')
        self.assertTrue(self.store.campaign_active(first)); self.assertTrue(self.store.campaign_active(second))
        source={'message_id':50,'date':1800000000,'chat':{'id':42,'type':'private'},'text':'Same source'}
        await self.message(42,'/clear',source)
        reply=next(args for name,args in reversed(self.api.calls) if name=='sendMessage')
        self.assertIn('delete-notice:'+first,str(reply['reply_markup'])); self.assertIn('delete-notice:'+second,str(reply['reply_markup']))
        await self.callback(42,'keep-notice:'+first)
        self.assertTrue(self.store.campaign_active(first))
        # A copied bot announcement can also be selected by its campaign marker.
        source.update(message_id=60, **{'from':{'id':123456,'is_bot':True,'first_name':'Cinespice'},
            'reply_markup':{'inline_keyboard':[[{'text':'Update','callback_data':'notice:1:'+first}]]}})
        await self.message(42,'/clear',source)
        reply=next(args for name,args in reversed(self.api.calls) if name=='sendMessage')
        self.assertIn('delete-notice:'+first,str(reply['reply_markup'])); self.assertNotIn('delete-notice:'+second,str(reply['reply_markup']))

    async def test_clearing_during_membership_lookup_prevents_copy(self):
        campaign='f'*32
        self.store.start(7); self.store.queue(campaign,42,50)
        def clear_during_lookup():
            self.api.on_member_lookup=None
            self.store.delete_notification(campaign)
        self.api.on_member_lookup=clear_during_lookup
        for _ in range(100):
            if not self.store.campaign_active(campaign): break
            await asyncio.sleep(.02)
        self.assertFalse(self.store.campaign_active(campaign))
        await asyncio.sleep(.05)
        self.assertFalse(any(name=='copyMessage' and args['chat_id']==7 for name,args in self.api.calls))
