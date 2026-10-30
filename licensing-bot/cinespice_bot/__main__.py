import argparse
import asyncio
import json
import logging
import re
import uuid
from pathlib import Path
from datetime import datetime, timezone

from telegram import BotCommand, BotCommandScopeAllPrivateChats, BotCommandScopeChat, BotCommandScopeDefault, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ChatType, ChatMemberStatus
from telegram.error import BadRequest, Forbidden, RetryAfter, TelegramError
from telegram.ext import Application, CallbackQueryHandler, ChatMemberHandler, CommandHandler, MessageHandler, filters
from .config import ConfigurationError, Settings
from .protocol import NONCE, Signer, generate_key
from .service import AccessService, is_member
from .storage import Store

MESSAGES = {
    'authorized': 'Your Cinespice access is authorized. Return to the app to continue.',
    'unpaid': 'Your account has not been approved yet. Please contact us for access, then check again in Cinespice.',
    'not_started': 'Start this bot first, then check access in Cinespice.',
    'join_required': 'Please join the required community channels shown in Cinespice, then check access again.',
    'revoked': 'Your access was revoked by an administrator. Contact us for help.',
    'unavailable': 'Verification is temporarily unavailable. Please try again shortly.',
    'other_device': 'This account was activated on another device. Activate on this device to move access here.',
}


def build_application(settings, store, signer, *, request=None):
    service = AccessService(settings, store, signer)
    cooldown = {}
    welcome_cooldown = {}
    stop = asyncio.Event()
    worker = None
    membership_worker = None

    def links():
        rows = [[InlineKeyboardButton('Contact us for access', url=settings.contact_url)]]
        rows += [[InlineKeyboardButton('Join ' + c['title'], url=c['url'])] for c in settings.channels]
        return InlineKeyboardMarkup(rows)

    def welcome_links():
        rows = [[InlineKeyboardButton('Join chat group · More info & support', url=settings.chat_group_url or settings.contact_url)],
                [InlineKeyboardButton('Contact me', url=settings.contact_url)]]
        rows += [[InlineKeyboardButton('Join ' + c['title'] + ' · Updates', url=c['url'])] for c in settings.channels]
        return InlineKeyboardMarkup(rows)

    async def access(update, context):
        if not update.effective_chat or update.effective_chat.type != ChatType.PRIVATE or not update.effective_user:
            return
        uid = update.effective_user.id
        command = update.effective_message.text.split()[0].split('@')[0]
        nonce = context.args[0] if context.args else ''
        device = ''
        modern = re.fullmatch(r'cs2_([0-9a-f]{24})_([0-9a-f]{32})', nonce)
        if modern: device, nonce = modern.groups()
        elif command == '/check' and len(context.args) == 2 and re.fullmatch(r'[0-9a-f]{24}', context.args[1]):
            device = context.args[1]
        if command == '/start':
            store.start(uid)
            if nonce.startswith('cs_'): nonce = nonce[3:]
            if not nonce or nonce == 'welcome':
                await update.effective_message.reply_text(
                    'Welcome to Cinespice 🎬\n\nCinespice brings your Telegram channels and media together in one app. '
                    'Open the app and tap Activate to link your account and verify your membership.\n\n'
                    'Join our chat group for more info or help, contact me for access, and join the channel for updates.',
                    reply_markup=welcome_links())
                return
        if nonce and not NONCE.fullmatch(nonce):
            await update.effective_message.reply_text('Open Cinespice and tap Activate to create a new verification request.')
            return
        # Bound memory and per-account verification traffic. No raw messages/tokens are logged.
        import time
        now = time.monotonic()
        if now - cooldown.get(uid, -100) < 2:
            if nonce:
                token = signer.receipt(uid, nonce, 'unavailable', 60, device=device, revision=store.access_state(uid)[1])
                reply = await update.effective_message.reply_text(token, disable_notification=True)
                if device: store.remember_receipt(uid, nonce, reply.message_id, update.effective_message.message_id, 'unavailable')
            return
        if len(cooldown) > 10000: cooldown.clear()
        cooldown[uid] = now
        observed_revision = store.access_state(uid)[1]
        status, paid, missing = await service.requirements(context.bot, uid)
        # A membership change or manual revocation during the network calls may
        # make the answer stale; never sign that answer at the newer revision.
        if store.access_state(uid)[1] != observed_revision:
            status, paid, missing = 'unavailable', False, []
        if device and status == 'authorized' and not store.authorize_device(uid, device, transfer=(command == '/start')):
            status = 'other_device'
        if not device:
            await update.effective_message.reply_text('Verified ✅' if status == 'authorized' else MESSAGES[status], reply_markup=None if status == 'authorized' else links())
        if nonce:
            token = signer.receipt(uid, nonce, status, settings.ttl if status == 'authorized' else 60,
                                   device=device, revision=store.access_state(uid)[1], paid=paid, missing=missing,
                                   persistent=bool(device and status == 'authorized'))
            reply = await update.effective_message.reply_text(token, disable_notification=True)
            if device: store.remember_receipt(uid, nonce, reply.message_id, update.effective_message.message_id, status)

    async def verified(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or len(context.args) != 1 or not NONCE.fullmatch(context.args[0]): return
        uid, nonce = update.effective_user.id, context.args[0]
        pending = store.pending_receipt(uid, nonce)
        if not pending: return
        message_id, request_id, status, revision = pending
        if store.access_state(uid)[0]: status = 'revoked'
        elif store.access_state(uid)[1] != revision: status = 'unavailable'
        # Only replace the receipt after the app verifies and acknowledges it. Never
        # use a timer: deleting before an offline client receives it races delivery.
        try:
            await context.bot.edit_message_text('Verified ✅' if status == 'authorized' else MESSAGES[status], chat_id=uid, message_id=message_id)
        except BadRequest:
            # It may already have been edited/deleted by another device. No grant is issued here.
            pass
        for message in (request_id, update.effective_message.message_id):
            try: await context.bot.delete_message(uid, message)
            except TelegramError: pass
        store.forget_receipt(uid, nonce)

    async def revoke(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or update.effective_user.id not in settings.admins: return
        if len(context.args) != 1 or not context.args[0].isdigit() or not 0 < int(context.args[0]) <= 2**63-1:
            await update.effective_message.reply_text('Use /revoke <numeric user ID> or /restore <numeric user ID>.'); return
        uid = int(context.args[0])
        revoked = update.effective_message.text.split()[0].split('@')[0] == '/revoke'
        store.access_changed(uid, revoked=revoked)
        await update.effective_message.reply_text('Access revoked. Devices will lock once they verify the update.' if revoked else 'Manual revocation removed. Paid-group membership is still required.')

    async def membership_changed(update, context):
        event = update.chat_member
        required = {settings.paid_group}
        if not event or event.chat.id not in required or event.new_chat_member.user.is_bot: return
        if is_member(event.old_chat_member) != is_member(event.new_chat_member):
            store.access_changed(event.new_chat_member.user.id)
            if event.chat.id == settings.paid_group:
                store.observe_paid_membership(event.new_chat_member.user.id, is_member(event.new_chat_member))
        await welcome(update, context)

    async def bot_contact_changed(update, context):
        event = update.my_chat_member
        if not event or event.chat.type != ChatType.PRIVATE:
            return
        old, new = event.old_chat_member.status, event.new_chat_member.status
        if (old, new) not in {(ChatMemberStatus.MEMBER, ChatMemberStatus.BANNED),
                              (ChatMemberStatus.BANNED, ChatMemberStatus.MEMBER)}:
            return
        blocked = new == ChatMemberStatus.BANNED
        if store.record_bot_contact_event(update.update_id, event.chat.id, blocked, int(event.date.timestamp())):
            logging.getLogger('cinespice').info('User %s %s the bot.', event.chat.id, 'blocked' if blocked else 'unblocked')

    async def help_command(update, context):
        if update.effective_chat.type != ChatType.PRIVATE: return
        text = 'Cinespice help 🎬\n\nHaving an issue or a question? Join our chat group and ask there.\n/start — About Cinespice and useful links\n/help — Support'
        if update.effective_user.id in settings.admins:
            text += '\n\nAdmin only: reply to a text/photo/GIF with /broadcast to publish; reply to an announcement with /clear to remove just that broadcast; /clearall removes all app notifications. Also: /stats; /botblocks; /id; /revoke <user ID>; /restore <user ID>.'
        await update.effective_message.reply_text(text, reply_markup=welcome_links())

    async def identity(update, context):
        if update.effective_user.id in settings.admins:
            await update.effective_message.reply_text(f'Your account ID: {update.effective_user.id}\nThis chat ID: {update.effective_chat.id}')

    async def welcome(update, context):
        event = update.chat_member
        if not event or event.chat.id != settings.paid_group or not is_member(event.new_chat_member) or is_member(event.old_chat_member):
            return
        user = event.new_chat_member.user
        if user.is_bot: return
        # Bots cannot privately contact someone who has never started them.
        import time
        now = time.monotonic()
        if now - welcome_cooldown.get(user.id, -1000) < 300: return
        if len(welcome_cooldown) > 10000: welcome_cooldown.clear()
        welcome_cooldown[user.id] = now
        await context.bot.send_message(event.chat.id, f'Welcome, {user.first_name}! Open Cinespice and tap Activate.',
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('Start access bot', url=f'https://t.me/{settings.username}?start=welcome')]]))

    async def stats(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or update.effective_user.id not in settings.admins: return
        users, states = store.stats()
        await update.effective_message.reply_text(f'Activated bot accounts: {users}\nBroadcast delivery states: {json.dumps(states, sort_keys=True)}')

    async def bot_blocks(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or update.effective_user.id not in settings.admins: return
        events = store.recent_bot_contact_events()
        lines = [f"{datetime.fromtimestamp(at, timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} — {uid}: {'blocked' if blocked else 'unblocked'}"
                 for uid, blocked, at in events]
        await update.effective_message.reply_text('Recent bot block/unblock events:\n' + ('\n'.join(lines) if lines else 'No events recorded.'))

    async def broadcast(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or update.effective_user.id not in settings.admins: return
        message = update.effective_message.reply_to_message
        if not message or not (message.text or message.photo or message.animation):
            await update.effective_message.reply_text('Reply to a text, photo or GIF/animation with /broadcast. Send one item per announcement; albums are not supported yet.')
            return
        campaign = uuid.uuid4().hex
        # One pending preview per admin; publishing consumes it so duplicate clicks cannot enqueue twice.
        context.user_data['broadcast'] = (campaign, message.chat_id, message.message_id)
        await context.bot.copy_message(update.effective_chat.id, message.chat_id, message.message_id,
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('Cinespice announcement preview', callback_data='notice-preview:1:' + campaign)]]))
        await update.effective_message.reply_text('Publish this announcement to currently authorized members who started the bot?',
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('Publish', callback_data='publish:' + campaign), InlineKeyboardButton('Cancel', callback_data='cancel:' + campaign)]]))

    async def publish(update, context):
        query = update.callback_query
        if query.from_user.id not in settings.admins or query.message.chat.type != ChatType.PRIVATE:
            await query.answer(); return
        preview = context.user_data.get('broadcast')
        if not preview or query.data.split(':', 1)[1] != preview[0]:
            await query.answer('This preview expired. Create a new one.'); return
        del context.user_data['broadcast']
        await query.answer()
        if query.data.startswith('cancel:'):
            await query.edit_message_text('Broadcast cancelled.'); return
        count = store.queue(*preview)
        await query.edit_message_text(f'Broadcast queued for up to {count} accounts. Membership is checked before each delivery. Use /stats for progress. To remove only this announcement: /clear {preview[0]}')

    async def clear_notifications(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or update.effective_user.id not in settings.admins: return
        count = store.clear_notifications(uuid.uuid4().hex)
        await update.effective_message.reply_text(f'Clearing app announcement history for {count} accounts. Old pending broadcasts were cancelled. New broadcasts will still appear. Telegram chat copies remain readable.')

    async def clear_selected(update, context):
        if update.effective_chat.type != ChatType.PRIVATE or update.effective_user.id not in settings.admins: return
        candidates = []
        if len(context.args) == 1 and re.fullmatch(r'[0-9a-f]{32}', context.args[0]):
            candidates = [context.args[0]] if store.campaign_active(context.args[0]) else []
        elif not context.args and update.effective_message.reply_to_message:
            message = update.effective_message.reply_to_message
            # A copied bot announcement/preview carries its exact campaign ID. Never trust forwarded content.
            if message.from_user and message.from_user.id == settings.bot_id and not message.forward_origin and message.reply_markup:
                candidates = [b.callback_data.rsplit(':',1)[1] for row in message.reply_markup.inline_keyboard for b in row
                              if b.callback_data and re.fullmatch(r'(?:notice|notice-preview):1:[0-9a-f]{32}', b.callback_data)
                              and store.campaign_active(b.callback_data.rsplit(':',1)[1])]
            if not candidates:
                candidates = store.campaigns_for(message.chat_id, message.message_id)
        if not candidates:
            await update.effective_message.reply_text('Reply to a published announcement (or its original message) with /clear. You can also use /clear <broadcast ID> from the publish confirmation. /clearall removes all app notifications.')
            return
        # A source can have been broadcast more than once: always choose one campaign explicitly.
        rows = [[InlineKeyboardButton('Delete announcement ' + campaign[-8:], callback_data='delete-notice:' + campaign)] for campaign in list(dict.fromkeys(candidates))[:20]]
        rows.append([InlineKeyboardButton('Cancel', callback_data='keep-notice:' + candidates[0])])
        await update.effective_message.reply_text('Remove only this announcement from app notifications?' if len(candidates) == 1 else 'This message was broadcast more than once. Select the announcement to remove:', reply_markup=InlineKeyboardMarkup(rows))

    async def delete_selected(update, context):
        query = update.callback_query
        if query.from_user.id not in settings.admins or query.message.chat.type != ChatType.PRIVATE:
            await query.answer(); return
        await query.answer()
        if query.data.startswith('keep-notice:'):
            await query.edit_message_text('Notification removal cancelled.'); return
        count = store.delete_notification(query.data.split(':', 1)[1])
        await query.edit_message_text('This announcement was already cleared.' if count is None else
            f'Removing this announcement from app notifications for {count} accounts. Other announcements remain. Telegram chat copies remain readable.')

    async def deliver(app):
        while not stop.is_set():
            clear = store.next_notice_clear()
            if clear:
                uid, campaign = clear
                try:
                    await app.bot.send_message(uid, 'Cinespice announcement history was cleared.', disable_notification=True,
                        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('Cinespice notifications', callback_data='notice-clear:1:' + campaign)]]))
                    store.finish_notice_clear(uid, campaign)
                except Forbidden: store.finish_notice_clear(uid, campaign, 3600)
                except RetryAfter as exc:
                    seconds = exc.retry_after.total_seconds() if hasattr(exc.retry_after, 'total_seconds') else exc.retry_after
                    store.finish_notice_clear(uid, campaign, int(seconds) + 1)
                except TelegramError: store.finish_notice_clear(uid, campaign, 30)
                await asyncio.sleep(0.2)
            deletion = store.next_notice_delete()
            if deletion:
                uid, campaign = deletion
                try:
                    await app.bot.send_message(uid, 'A Cinespice announcement was removed.', disable_notification=True,
                        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('Cinespice notifications', callback_data='notice-delete:1:' + campaign)]]))
                    store.finish_notice_delete(uid, campaign)
                except Forbidden: store.finish_notice_delete(uid, campaign, 3600)
                except RetryAfter as exc:
                    seconds = exc.retry_after.total_seconds() if hasattr(exc.retry_after, 'total_seconds') else exc.retry_after
                    store.finish_notice_delete(uid, campaign, int(seconds) + 1)
                except TelegramError: store.finish_notice_delete(uid, campaign, 30)
                await asyncio.sleep(0.2)
            event = store.next_access_event()
            if event:
                uid, revision = event
                try:
                    text = 'Your access has been revoked.' if store.access_state(uid)[0] else 'Your membership changed. Cinespice will update your access.'
                    await app.bot.send_message(uid, text, disable_notification=True,
                        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton('Update access', callback_data=f'access:1:{revision}')]]))
                    store.finish_access_event(uid, revision)
                except Forbidden: store.finish_access_event(uid, revision)
                except TelegramError: store.finish_access_event(uid, revision, retry=True)
                await asyncio.sleep(0.2)
            row = store.next_delivery()
            if not row:
                try: await asyncio.wait_for(stop.wait(), timeout=1)
                except asyncio.TimeoutError: pass
                continue
            campaign, uid, chat, message, attempts = row
            if store.notice_clear_pending(uid):
                store.delay_delivery(campaign, uid, 30)
                continue
            try:
                status = await service.eligibility(app.bot, uid, propagate_rate_limit=True)
                if status == 'unavailable': raise TelegramError('Membership unavailable')
                if status != 'authorized':
                    store.delivered(campaign, uid, 'ineligible'); continue
                if not store.delivery_pending(campaign, uid): continue
                markup = InlineKeyboardMarkup([[InlineKeyboardButton('Cinespice update', callback_data='notice:1:' + campaign)]])
                await app.bot.copy_message(uid, chat, message, reply_markup=markup)
                store.delivered(campaign, uid)
                await asyncio.sleep(0.2)  # At most 5 deliveries/s; membership lookups also consume API budget.
            except Forbidden:
                store.delivered(campaign, uid, 'blocked')
            except RetryAfter as exc:
                seconds = exc.retry_after.total_seconds() if hasattr(exc.retry_after, 'total_seconds') else exc.retry_after
                store.retry(campaign, uid, int(seconds) + 1)
                try: await asyncio.wait_for(stop.wait(), timeout=float(seconds) + 1)
                except asyncio.TimeoutError: pass
            except TelegramError:
                if attempts >= 8: store.delivered(campaign, uid, 'failed')
                else: store.retry(campaign, uid, min(3600, 2 ** (attempts + 2)))

    async def reconcile_memberships(app):
        while not stop.is_set():
            row = store.next_membership_check()
            if row:
                uid, previous, revision = row
                try:
                    member = is_member(await app.bot.get_chat_member(settings.paid_group, uid))
                    store.complete_membership_check(uid, previous, revision, member)
                    delay = 0.2
                except RetryAfter as exc:
                    seconds = exc.retry_after.total_seconds() if hasattr(exc.retry_after, 'total_seconds') else exc.retry_after
                    store.retry_membership_check(uid, int(seconds) + 1)
                    delay = min(float(seconds) + 1, 30)
                except TelegramError as exc:
                    # An unreachable API is not evidence that the user left.
                    logging.getLogger('cinespice').warning('Membership check failed (%s); retrying.', type(exc).__name__)
                    store.retry_membership_check(uid, 30)
                    delay = 1
            else:
                delay = 1
            try: await asyncio.wait_for(stop.wait(), timeout=delay)
            except asyncio.TimeoutError: pass

    async def supervise_worker(name, run, app):
        while not stop.is_set():
            try:
                await run(app)
                if stop.is_set(): return
                logging.getLogger('cinespice').error('%s worker stopped unexpectedly; restarting.', name)
            except Exception as exc:
                # Exception details can include Telegram credentials or message contents.
                logging.getLogger('cinespice').error('%s worker failed (%s); restarting.', name, type(exc).__name__)
            try: await asyncio.wait_for(stop.wait(), timeout=5)
            except asyncio.TimeoutError: pass

    async def channel_announcement(update, context):
        message = update.channel_post
        if not message or not settings.announcement_channel or message.chat.id != settings.announcement_channel:
            return
        if not (message.text or message.photo or message.animation):
            return
        # Stable identity prevents duplicate Telegram updates from re-queueing a post.
        campaign = uuid.uuid5(uuid.NAMESPACE_URL, f'cinespice-channel:{message.chat.id}:{message.message_id}').hex
        if not store.campaign_exists(campaign):
            store.queue(campaign, message.chat.id, message.message_id)

    async def notice_clicked(update, context):
        await update.callback_query.answer('Open Cinespice to read this update.')

    async def startup(app):
        nonlocal worker, membership_worker
        async def checked_request(request, message):
            try:
                return await request
            except (BadRequest, Forbidden):
                # Provider descriptions may contain secrets; report only fixed setup context.
                raise ConfigurationError(message) from None

        me = await checked_request(app.bot.get_me(), 'Telegram rejected the bot identity check. Verify BOT_TOKEN belongs to your configured bot.')
        if me.id != settings.bot_id or me.username.lower() != settings.username.lower():
            raise ConfigurationError('BOT_USER_ID or BOT_USERNAME does not match the bot identified by BOT_TOKEN')
        paid = await checked_request(app.bot.get_chat(settings.paid_group),
            'Cannot open PAID_GROUP_ID. Check its exact negative numeric chat ID and add the bot as an administrator in that private group.')
        if paid.type not in {ChatType.GROUP, ChatType.SUPERGROUP} or paid.username or getattr(paid, 'active_usernames', None):
            raise ConfigurationError('PAID_GROUP_ID must identify a private paid-members group')
        chats = [('PAID_GROUP_ID', settings.paid_group)]
        for field, chat in chats:
            member = await checked_request(app.bot.get_chat_member(chat, me.id),
                f'Cannot check bot membership for {field}. Check the numeric chat ID and add the bot as an administrator there.')
            if member.status not in {ChatMemberStatus.ADMINISTRATOR, ChatMemberStatus.OWNER}:
                raise ConfigurationError(f'Make the bot an administrator in the chat configured by {field}')
        # Long polling requires no webhook. Explicitly switch modes without dropping pending updates.
        await checked_request(app.bot.delete_webhook(drop_pending_updates=False),
            'Telegram rejected deleteWebhook while enabling polling. Verify BOT_TOKEN and your bot webhook settings.')
        public_commands = [BotCommand('start', 'About Cinespice'), BotCommand('help', 'Get help in our chat group')]
        # Telegram menus are scoped for discoverability; handlers still enforce numeric admin IDs.
        await app.bot.set_my_commands([], scope=BotCommandScopeDefault())
        await app.bot.set_my_commands(public_commands, scope=BotCommandScopeAllPrivateChats())
        admin_commands = public_commands + [BotCommand(name, description) for name, description in (
            ('broadcast', 'Reply to publish an announcement'), ('clear', 'Reply to remove one announcement'),
            ('clearall', 'Clear all app announcements'), ('stats', 'Broadcast delivery progress'),
            ('botblocks', 'Recent bot block events'),
            ('id', 'Show account and chat IDs'), ('revoke', 'Revoke a user license'), ('restore', 'Remove a manual revocation'))]
        for uid in settings.admins:
            # Telegram cannot open a private chat until its owner starts the bot.
            try: await app.bot.set_my_commands(admin_commands, scope=BotCommandScopeChat(uid))
            except BadRequest: pass
        store.schedule_membership_reconciliation()
        worker = asyncio.create_task(supervise_worker('Delivery', deliver, app))
        membership_worker = asyncio.create_task(supervise_worker('Membership', reconcile_memberships, app))
        logging.getLogger('cinespice').info('Bot initialized; starting polling and membership checks.')

    async def shutdown(app):
        stop.set()
        if worker:
            worker.cancel()
            try: await worker
            except asyncio.CancelledError: pass
        if membership_worker:
            membership_worker.cancel()
            try: await membership_worker
            except asyncio.CancelledError: pass
        store.close()
        logging.getLogger('cinespice').info('Bot stopped.')

    async def error_handler(update, context):
        # PTB/HTTP logs can contain token-bearing URLs or private message contents.
        logging.getLogger('cinespice').warning('Bot operation failed (%s); check connectivity and bot permissions.', type(context.error).__name__)

    builder = Application.builder().token(settings.token).concurrent_updates(False).post_init(startup).post_stop(shutdown)
    if request is not None: builder = builder.request(request)
    app = builder.build()
    app.add_handler(MessageHandler(filters.UpdateType.CHANNEL_POST, channel_announcement))
    app.add_handler(CommandHandler(['start', 'check'], access, filters=filters.ChatType.PRIVATE))
    app.add_handler(CommandHandler('verified', verified, filters=filters.ChatType.PRIVATE))
    app.add_handler(CommandHandler(['revoke', 'restore'], revoke, filters=filters.ChatType.PRIVATE))
    app.add_handler(CallbackQueryHandler(notice_clicked, pattern=r'^notice-clear:1:'))
    app.add_handler(CommandHandler('help', help_command))
    app.add_handler(CommandHandler('id', identity))
    app.add_handler(CommandHandler('stats', stats))
    app.add_handler(CommandHandler('botblocks', bot_blocks))
    app.add_handler(CommandHandler('broadcast', broadcast))
    app.add_handler(CommandHandler('clearall', clear_notifications, filters=filters.ChatType.PRIVATE))
    app.add_handler(CommandHandler(['clear', 'clear_notifications'], clear_selected, filters=filters.ChatType.PRIVATE))
    app.add_handler(CallbackQueryHandler(delete_selected, pattern=r'^(delete-notice|keep-notice):[0-9a-f]{32}$'))
    app.add_handler(CallbackQueryHandler(notice_clicked, pattern=r'^notice-delete:1:[0-9a-f]{32}$'))
    app.add_handler(CallbackQueryHandler(publish, pattern=r'^(publish|cancel):[0-9a-f]{32}$'))
    app.add_handler(CallbackQueryHandler(notice_clicked, pattern=r'^access:1:[0-9]+$'))
    app.add_handler(CallbackQueryHandler(notice_clicked, pattern=r'^(notice|notice-preview):1:[0-9a-f]{32}$'))
    app.add_handler(ChatMemberHandler(membership_changed, ChatMemberHandler.CHAT_MEMBER))
    app.add_handler(ChatMemberHandler(bot_contact_changed, ChatMemberHandler.MY_CHAT_MEMBER))
    app.add_error_handler(error_handler)
    return app


def main():
    parser = argparse.ArgumentParser(description='Cinespice access bot')
    sub = parser.add_subparsers(dest='command', required=True)
    gen = sub.add_parser('keygen'); gen.add_argument('--out', type=Path, default=Path('state/signing-key.pem'))
    sub.add_parser('run')
    export = sub.add_parser('export-config'); export.add_argument('--out', type=Path, default=Path('../access-config.local.json'))
    args = parser.parse_args()
    if args.command == 'keygen':
        generate_key(args.out); print('Created signing key. Keep it private and back it up.'); return
    settings = Settings.load()
    try:
        signer = Signer(settings.key_path)
    except FileNotFoundError:
        raise ConfigurationError(
            'Signing key file not found. Set SIGNING_KEY in .env to your existing private key file '
            '(default: state/signing-key.pem, relative to the current working directory). '
            'Restore the original key used for your app build; access-config.local.json contains only the public key. '
            'Do not generate a replacement key for an already configured app.'
        ) from None
    if args.command == 'export-config':
        data = {'botUsername': settings.username, 'botUserID': str(settings.bot_id), 'publicKey': signer.public_key(),
                'contactURL': settings.contact_url, 'channels': [{'title': c['title'], 'url': c['url']} for c in settings.channels]}
        with args.out.open('x') as handle: json.dump(data, handle, indent=2)
        print('Exported public app configuration. This file contains no bot token or private key.'); return
    logging.basicConfig(level=logging.CRITICAL)
    logging.getLogger('cinespice').setLevel(logging.INFO)
    store = Store(settings.database)
    app = build_application(settings, store, signer)
    try:
        app.run_polling(allowed_updates=['message', 'channel_post', 'callback_query', 'chat_member', 'my_chat_member'], drop_pending_updates=False)
    finally:
        # Also covers failed startup before post_stop can run.
        store.close()


if __name__ == '__main__':
    try: main()
    except KeyboardInterrupt: pass
    except ConfigurationError as exc:
        raise SystemExit(f'Bot configuration error: {exc}') from None
    except Exception as exc:
        # Avoid token-bearing transport URLs in uncaught exception tracebacks.
        raise SystemExit(f'Bot stopped ({type(exc).__name__}). Check environment, connectivity, bot identity and chat administrator permissions.') from None
