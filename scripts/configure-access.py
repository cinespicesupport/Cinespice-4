#!/usr/bin/env python3
"""Copy only validated public access settings into an app resource (no dependencies)."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]


def validate(data):
    if set(data) != {'botUsername', 'botUserID', 'publicKey', 'contactURL', 'channels'}:
        raise ValueError('Export public app configuration using the access bot; unknown/missing fields are rejected')
    if not isinstance(data['botUsername'], str) or not re.fullmatch(r'[A-Za-z0-9_]{5,32}', data['botUsername']) or not data['botUsername'].lower().endswith('bot'):
        raise ValueError('Invalid bot username')
    if not isinstance(data['botUserID'], str) or not re.fullmatch(r'[1-9][0-9]{0,18}', data['botUserID']) or int(data['botUserID']) > 2**63-1:
        raise ValueError('Invalid numeric bot ID')
    key = base64.b64decode(data['publicKey'], validate=True)
    # Canonical SubjectPublicKeyInfo for id-ecPublicKey / prime256v1 + uncompressed point.
    if len(key) != 91 or key[:27] != bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004'):
        raise ValueError('Expected an exported P-256 public key (never a private key)')
    prime = 2**256 - 2**224 + 2**192 + 2**96 - 1
    curve_b = int('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', 16)
    x, y = int.from_bytes(key[27:59], 'big'), int.from_bytes(key[59:91], 'big')
    if x >= prime or y >= prime or (y*y - (x*x*x - 3*x + curve_b)) % prime:
        raise ValueError('Public key is not on the P-256 curve')
    def link(text):
        url = urlparse(text)
        if url.scheme != 'https' or url.netloc != 't.me' or len(url.path) < 2 or url.query or url.fragment:
            raise ValueError('Use HTTPS t.me links without query/fragment')
    link(data['contactURL'])
    if not isinstance(data['channels'], list) or len(data['channels']) > 10:
        raise ValueError('Expected at most ten channels')
    for channel in data['channels']:
        if set(channel) != {'title', 'url'} or not isinstance(channel['title'], str) or not channel['title'].strip():
            raise ValueError('Each channel requires title and URL')
        link(channel['url'])
    if len(json.dumps(data).encode()) > 12000: raise ValueError('Public settings are too large')
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=ROOT / 'Resources/CinespiceAccess.json')
    args = parser.parse_args()
    raw = os.environ.get('CINESPICE_ACCESS_CONFIG_JSON', '').strip()
    local = ROOT / 'access-config.local.json'
    if not raw and local.is_file(): raw = local.read_text()
    data = validate(json.loads(raw)) if raw else {}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(data, indent=2) + '\n')
    print('Public access configuration written.' if data else 'Access configuration absent: this build will show setup pending and keep the library locked.')


if __name__ == '__main__':
    try: main()
    except (ValueError, TypeError, KeyError, OSError):
        raise SystemExit('Invalid public access configuration. See licensing-bot/README.md; do not supply bot tokens or private keys.')
