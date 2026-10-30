import json
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from dotenv import dotenv_values


class ConfigurationError(ValueError):
    """An operator-facing error containing only fixed configuration field names."""


def public_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != 'https' or parsed.hostname != 't.me' or not parsed.path.strip('/') or parsed.query or parsed.fragment or parsed.username or parsed.port:
        raise ValueError('Use an HTTPS t.me link without query parameters')
    return value


@dataclass(frozen=True)
class Settings:
    token: str
    username: str
    bot_id: int
    paid_group: int
    admins: frozenset[int]
    contact_url: str
    channels: tuple[dict, ...]
    key_path: Path
    database: Path
    ttl: int
    chat_group_url: str = ""
    announcement_channel: int = 0

    @classmethod
    def load(cls):
        # Read only the working directory's file; terminal/service settings take precedence.
        # Disable interpolation so secrets containing ${...} remain literal text.
        try:
            env = {**dotenv_values(Path('.env'), encoding='utf-8-sig', interpolate=False), **os.environ}
        except (OSError, UnicodeError):
            raise ConfigurationError('Cannot read .env in the current working directory; check its permissions and UTF-8 encoding') from None
        required = ('BOT_TOKEN', 'BOT_USERNAME', 'BOT_USER_ID', 'PAID_GROUP_ID', 'ADMIN_IDS', 'CONTACT_URL')
        missing = [name for name in required if not (env.get(name) or '').strip()]
        if missing:
            raise ConfigurationError(
                'Missing or empty environment variables: ' + ', '.join(missing) +
                '. Add them to .env in the licensing-bot working directory or set them in the terminal. '
                'See licensing-bot/README.md.'
            )
        username = env['BOT_USERNAME'].lstrip('@')
        import re
        if not re.fullmatch(r'[A-Za-z0-9_]{5,32}', username) or not username.lower().endswith('bot'):
            raise ValueError('BOT_USERNAME must be the bot username')
        channels = json.loads(env.get('REQUIRED_CHANNELS', '[]'))
        if not isinstance(channels, list) or len(channels) > 10:
            raise ValueError('REQUIRED_CHANNELS must be an array of at most 10 channels')
        for channel in channels:
            if not isinstance(channel, dict) or not {'id', 'title', 'url'} <= channel.keys():
                raise ConfigurationError('Every REQUIRED_CHANNELS entry must be an object with id, title and url fields')
            if type(channel['id']) is not int or channel['id'] >= 0 or not isinstance(channel['title'], str) or not channel['title'].strip():
                raise ValueError('Every channel needs a negative numeric ID and a title')
            public_url(channel['url'])
        admins = frozenset(int(x.strip()) for x in env['ADMIN_IDS'].split(',') if x.strip())
        if not admins or any(x <= 0 for x in admins):
            raise ValueError('ADMIN_IDS must contain numeric user IDs')
        ttl = int(env.get('ACCESS_TTL_SECONDS', '3600'))
        if not 60 <= ttl <= 86400:
            raise ValueError('ACCESS_TTL_SECONDS must be between 60 and 86400')
        bot_id = int(env['BOT_USER_ID']); group = int(env['PAID_GROUP_ID'])
        if bot_id <= 0 or group >= 0:
            raise ValueError('BOT_USER_ID must be positive and PAID_GROUP_ID negative')
        if group in {x['id'] for x in channels}:
            raise ValueError('Keep the private paid group separate from required community channels')
        announcement = int(env.get('ANNOUNCEMENT_CHANNEL_ID') or 0)
        if announcement and announcement not in {x['id'] for x in channels}:
            raise ValueError('ANNOUNCEMENT_CHANNEL_ID must identify a configured updates channel')
        return cls(env['BOT_TOKEN'], username, bot_id, group, admins,
                   public_url(env['CONTACT_URL']), tuple(channels),
                   Path(env.get('SIGNING_KEY', 'state/signing-key.pem')),
                   Path(env.get('DATABASE', 'state/bot.sqlite3')), ttl,
                   public_url(env['CHAT_GROUP_URL']) if env.get('CHAT_GROUP_URL') else '', announcement)
