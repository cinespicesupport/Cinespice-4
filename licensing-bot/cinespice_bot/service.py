from telegram.error import TelegramError, RetryAfter


def is_member(member) -> bool:
    return member.status in {'creator', 'administrator', 'member'} or (member.status == 'restricted' and bool(getattr(member, 'is_member', False)))


class AccessService:
    def __init__(self, settings, store, signer):
        self.settings = settings; self.store = store; self.signer = signer

    async def eligibility(self, bot, uid: int, *, propagate_rate_limit=False) -> str:
        if self.store.access_state(uid)[0]:
            return 'revoked'
        if not self.store.started(uid):
            return 'not_started'
        try:
            if not is_member(await bot.get_chat_member(self.settings.paid_group, uid)):
                return 'unpaid'
            for channel in self.settings.channels:
                if not is_member(await bot.get_chat_member(channel['id'], uid)):
                    return 'join_required'
        except RetryAfter:
            if propagate_rate_limit: raise
            return 'unavailable'
        except TelegramError:
            # An unavailable membership check is never interpreted as access approval.
            return 'unavailable'
        return 'authorized'

    async def requirements(self, bot, uid: int):
        if self.store.access_state(uid)[0]: return 'revoked', False, []
        if not self.store.started(uid): return 'not_started', False, []
        try:
            paid = not is_member(await bot.get_chat_member(self.settings.paid_group, uid))
            missing = []
            for index, channel in enumerate(self.settings.channels):
                if not is_member(await bot.get_chat_member(channel['id'], uid)): missing.append(index)
            return ('unpaid' if paid else 'join_required' if missing else 'authorized'), paid, missing
        except TelegramError:
            return 'unavailable', False, []

    async def receipt(self, bot, uid: int, nonce: str):
        status = await self.eligibility(bot, uid)
        token = self.signer.receipt(uid, nonce, status, self.settings.ttl if status == 'authorized' else 60)
        return status, token
