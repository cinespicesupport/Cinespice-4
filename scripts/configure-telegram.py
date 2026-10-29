"""Create the ignored app resource from CI secrets or local environment variables."""
import os
from pathlib import Path
import plistlib
import re


def main():
    api_id = os.environ.get("TELEGRAM_API_ID", "").strip()
    api_hash = os.environ.get("TELEGRAM_API_HASH", "").strip()
    if not re.fullmatch(r"[0-9]{1,10}", api_id) or not 0 < int(api_id) <= 2147483647:
        raise SystemExit("Set TELEGRAM_API_ID to a valid positive Telegram API ID.")
    if not re.fullmatch(r"[a-fA-F0-9]{32}", api_hash):
        raise SystemExit("Set TELEGRAM_API_HASH to a valid Telegram API hash.")
    destination = Path(__file__).resolve().parent.parent / "Resources/TelegramBuildCredentials.plist"
    destination.write_bytes(plistlib.dumps({"apiID": api_id, "apiHash": api_hash}))
    destination.chmod(0o600)


if __name__ == "__main__":
    main()
