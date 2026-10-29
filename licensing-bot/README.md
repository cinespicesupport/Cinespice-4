# Cinespice access bot

A standalone **python-telegram-bot 22.8** application. Run it on a PC, Linux server or Android phone with Termux. It uses long polling: no domain, public port, webhook, payment provider or separate licensing API is needed.

For the detailed behavior, protocol, storage and limitations, read [bot.md](bot.md).

## What you get

- A native **Activate your access** screen in Android and iOS, after account authentication (and after two-step verification when required).
- Access only when the same numeric account ID has started the bot, belongs to your **private paid-members group**, and belongs to every configured community channel.
- Manual approval: take payment through your own contact process, then manually add the buyer to the private group. The bot does not collect payment.
- A welcome message in the paid group when a member joins, with a Start access bot button.
- Admin-only broadcasts with text, formatting, one photo or one GIF/animation. Members receive the message in the bot chat and a Cinespice announcement banner that expands when tapped.
- Signed, account-bound, short-lived access passes. No bot token or private signing key goes into your APK/IPA.

**Existing signed-in users are also gated. An app built without access configuration stays locked with “Access setup is pending.”** Configure the bot before distributing the new build.

## 1. Create your bot and chats

1. Create a bot with **@BotFather**, save its token privately, and note its username and numeric ID (the digits before `:` in its token).
2. Create a **private paid-members group**. Keep its invitation under your control. Membership in this group is the entitlement: anyone admitted can use the app after completing the other requirements.
3. Choose a separate public contact group/link where people can ask for access. Joining the contact group does **not** grant access.
4. Optionally choose community channels that users must join.
5. Add the bot as an administrator to the paid group and all required channels. It needs membership visibility and permission to send welcome messages in the paid group. It does not need to administer your contact group.
6. Get your own numeric account ID, the paid-group ID and channel IDs using a trusted Telegram client/tool. Groups/channels use negative IDs, commonly `-100…`. Never substitute usernames/display names for IDs. After setup, `/id` in the bot's private chat shows your user ID; an admin can use `/id` in a group to confirm its chat ID.

A bot cannot privately message someone until that person starts it. Welcomes therefore appear **inside the paid group**. The app's single Activate button sends `/start` from the signed-in account with an explicit tap.

## 2. Install on PC/Linux/macOS

Use Python **3.10 or later**. First clone the repository (using the branch containing this bot) or copy this folder to your machine. Run these commands from the repository root:

```sh
cd licensing-bot
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

On Windows PowerShell use `py -m venv .venv`, `.venv\Scripts\Activate.ps1`, and `Copy-Item .env.example .env` for the corresponding setup steps. Only copy the example for a first installation; keep your existing `.env` when updating.

The bot automatically reads `.env` from the current working directory when you run `run` or `export-config`. Keep it in `licensing-bot/`. Explicit terminal or service environment variables take precedence over file values. File values are read as data; shell commands and `${...}` substitutions are not evaluated. Save the file as UTF-8; Windows line endings and a UTF-8 BOM are supported.

If you already have your `.env`, signing key and exported app configuration, update the bot files and run these commands from `licensing-bot/` in your activated Python environment:

```powershell
python -m pip install -r requirements.txt
python -m cinespice_bot run
```

Your existing `SIGNING_KEY` and `DATABASE` paths in `.env` are reused; defaults are `state/signing-key.pem` and `state/bot.sqlite3`. Keep these files when updating. You do not need to generate a new key, export again or rebuild your IPA to enable local `.env` loading. The exported `access-config.local.json` contains public app settings; the bot also needs its token and private membership settings from `.env`.

Edit `.env` on your own machine. It is ignored by Git. Values in the example are placeholders. `REQUIRED_CHANNELS` is a JSON array inside shell single quotes:

```sh
REQUIRED_CHANNELS='[{"id":-1001234567890,"title":"Community","url":"https://t.me/your_channel"}]'
```

Use `[]` if you have no required channels. Public links and private `https://t.me/+…` invites work. Pending join requests must be approved before access can pass. Never put the paid group's invitation in this list.

For a **first installation**, after editing `.env`, generate the key, export the public app configuration, and start the bot:

```sh
python -m cinespice_bot keygen --out state/signing-key.pem
python -m cinespice_bot export-config --out ../access-config.local.json
python -m cinespice_bot run
```

`keygen` refuses to overwrite an existing key. `export-config` also refuses to overwrite an existing destination: move/remove your old public export intentionally before exporting again. Keep the private key and SQLite state backed up. Run all commands with `licensing-bot/` as the working directory because the default state paths are relative.

The startup check verifies the token's bot identity, that the paid group is private, and administrator status in each configured membership chat. Only run **one polling instance per bot token**. Stop it with Ctrl+C. To restart, activate the venv and run the same `run` command from `licensing-bot/`; `.env` is read again automatically. A service manager should use the same working directory and intended environment; do not put secrets in command arguments.

## 3. Run on Android with Termux

Use a current Termux release and keep the checkout/state in Termux's private home, rather than shared storage. A typical installation is:

```sh
pkg update
pkg install python python-cryptography git
cd ~/Cinespice-2/licensing-bot
python -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
```

Then follow the `.env`, key generation, export and run steps above. The native `cryptography` dependency may require a newer Termux package or a source build (`pkg install rust clang make pkg-config openssl libffi`) if the packaged version does not satisfy the pinned requirement. The Android/Termux installation itself has not been device-tested here; the bot and dependencies were tested on Linux.

For continued polling, disable battery optimization for Termux, keep network connectivity, and optionally use `termux-wake-lock`. Android may still stop background processes. A small always-on Linux server is more reliable for paid access. No operator token should be entered into Cinespice.

## 4. Configure the Android and iOS builds

The export creates root `access-config.local.json`, containing **only**:

- bot username and numeric ID;
- the P-256 public verification key;
- public contact URL and required-channel titles/links.

The apps do not need the private paid-group ID, admin IDs, token or signing private key. [../access-config.example.json](../access-config.example.json) demonstrates the shape with a disposable example public key. **Replace the complete example with your real export.** Its key cannot verify your bot's receipts.

### GitHub Actions

Create a repository **Actions variable**, named `CINESPICE_ACCESS_CONFIG_JSON`, whose value is the entire exported JSON. This is public build configuration, so a repository variable is appropriate. Retain the existing `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` build secrets.

Both app workflows now read that variable. Run the Android APK and iOS IPA workflows on the branch containing these changes, or merge and run them on your desired branch. Configuration changes require a new app build. Neither workflow deploys or starts the bot.

### Rebuild the IPA after setting up the bot on Windows

Use this when the bot is already running but your installed IPA was built with older or missing access configuration.

1. Update your checkout to the branch containing the bot fixes. Keep your existing `licensing-bot/.env` and `licensing-bot/state/` folder. Install the updated dependencies from `licensing-bot/` with `python -m pip install -r requirements.txt`.
2. In another PowerShell terminal, activate the same Python environment and enter `licensing-bot/`. Export public settings using the **existing key used by the running bot**:

   ```powershell
   $publicExport = "../access-config.$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
   python -m cinespice_bot export-config --out $publicExport
   ```

   Continue only if it reports a successful export. The timestamp gives each export a new filename, preserving older exports. You do not need to run `keygen` again. If you have terminal overrides for bot settings, use the same ones as the running bot; they take precedence over `.env`.
3. Open the newly exported JSON file in your project root. In the repository's **Settings → Secrets and variables → Actions → Variables**, create or update the repository variable `CINESPICE_ACCESS_CONFIG_JSON` with its **entire contents**. This export contains the public key and app settings, not the bot token or private key. Your local file is ignored by Git and is not uploaded by a commit or workflow run.
4. In **Actions secrets**, retain `TELEGRAM_API_ID` and `TELEGRAM_API_HASH`. These are your Telegram application credentials, separate from the bot token. The IPA workflow reads them when generating its bundled Telegram credentials.
5. Open **Actions → Build Cinespice IPA → Run workflow**. Select the branch containing the committed fixes and start the workflow. A push containing only bot changes does not automatically trigger the IPA workflow. The separate **Test access bot** workflow tests the Python bot; it does not produce an IPA.
6. On success, download **Cinespice-unsigned-ipa**, unzip it, and sign/install `Cinespice-unsigned.ipa` using your existing installation method. If it fails, inspect the failed step and **Cinespice-build-diagnostics** when available. A macOS runner allocation failure occurs before compilation and may require a later retry.
7. Keep one bot instance running. In the new app, sign in, tap **Activate**, and join any missing requirements shown for that same account. Verify a paid member can enter and an unpaid account remains locked.

For local macOS builds, copy the newly exported JSON to root `access-config.local.json`, then run `python3 scripts/configure-access.py` before XcodeGen. Windows can host the bot and trigger the GitHub workflow; compiling an IPA locally requires macOS and Xcode.

### Local builds

Android's `preBuild` runs `scripts/configure-access.py` automatically. It reads the root local export or the `CINESPICE_ACCESS_CONFIG_JSON` environment variable and generates the access asset. Android builds require Python 3 as well as the existing Android toolchain.

For iOS run this **before XcodeGen**:

```sh
python3 scripts/configure-access.py
xcodegen generate --spec project.yml
```

This generates `Resources/CinespiceAccess.json`. It is ignored by Git and included as an app resource. Supplied invalid configuration fails the build. Missing configuration produces a setup-pending app with no access bypass.


## Upgrade an already working bot and app

1. Stop the bot with Ctrl+C and back up `licensing-bot/state/` securely. Keep your existing `.env`, signing key and database. **Do not run keygen again.**
2. Update this repository on the branch containing these changes. From `licensing-bot`, run `python -m pip install -r requirements.txt`, then `python -m cinespice_bot run`. The new SQLite tables are created automatically; membership/admin state survives later restarts.
3. Keep the same public `access-config.local.json` / `CINESPICE_ACCESS_CONFIG_JSON` if the bot, key and channel configuration have not changed. Run the configured IPA/APK workflow on the branch containing these app changes. Update **both** the bot and app; older apps keep their old manual flow.
4. Install the new build and follow the end-to-end test below. No real hardware ID or MAC address is collected: each installation generates a random identifier in Keychain/Android Keystore storage. This binds receipts to the installation; it does not impose a one-device purchase limit or provide hardware attestation.

The first successful activation replaces the previous memory-only behavior with a securely saved, account/installation-bound pass. Checks renew silently near expiry, rather than requiring Activate every reopen. A new login requires activation. Do not set an unlimited pass lifetime: short signed leases are the fallback when membership events cannot reach a device. Keep the bot online and an administrator in every required chat.

Raw signed replies are sent silently, then edited only after the app validates and acknowledges them. They can briefly appear in the Telegram chat during that exchange; they cannot be invisible because this design uses Telegram chat as transport. Failed delivery/acknowledgment can leave a receipt visible. Historical messages from older builds are not automatically erased; you can delete those manually. The private signing key is never sent in a receipt.

## 5. First end-to-end test

1. Keep the configured bot running.
2. Install a newly configured build and log in, including the cloud password if the account requires it. No password is sent to the bot.
3. On **Activate your access**, tap **Activate**. With no paid membership it must say approval is pending.
4. Manually add that same account to your private paid group. It should receive a welcome in the group.
5. Tap **Join** for each required channel in Cinespice. These actions use the signed-in account. **Open** is an external link fallback. Wait for approval if the channel requires it.
6. Joining a channel in the app triggers verification automatically. Membership events also trigger verification after paid approval. If an event was missed while disconnected, tap **Activate**. Only all three conditions together unlock the library.
7. Test with a second unpaid account: copying the APK and forwarding the first account's receipt must not unlock it.
8. Close and reopen the app: valid saved activation must restore without another tap. Remove the member from either required chat: an online app must lock when the bot update arrives. If offline or an event is missed, its signed pass expires within the configured TTL (one hour by default). Test `/revoke <user ID>` and `/restore <user ID>` too.
9. Sign out and sign in again, or use a second device: tap Activate for that login. A receipt from a different account or installation must not unlock it. After verification, inspect the bot chat: the signed receipt becomes **Verified ✅**, and the request/acknowledgment commands are deleted.

## Commands

| Command | Who/where | Purpose |
|---|---|---|
| `/start` | Anyone, private chat | Show the Cinespice welcome, app summary and chat/contact/update buttons; record that the user started the bot |
| `/check` | Anyone, private chat | Show current eligibility; the app supplies a verification challenge |
| `/id` | Configured admins privately or in groups | Show numeric user/chat IDs |
| `/help` | Anyone privately | Ask users to post issues in the chat group, with support/contact/update buttons |
| `/revoke <user ID>` | Configured admins privately | Revoke all installations for that numeric account, even if still a member |
| `/restore <user ID>` | Configured admins privately | Remove manual revocation; all membership requirements still apply |
| `/stats` | Configured admins privately | Started-account and broadcast-delivery counts |
| `/clear` (alias `/clear_notifications`) | Configured admins privately | Reply to a published announcement, its preview or original source, then confirm removal of only that broadcast |
| `/clearall` | Configured admins privately | Clear all app announcement history and cancel older pending broadcasts; Telegram chat copies remain |
| `/broadcast` | Configured admins privately | Reply to a text/photo/GIF, preview it, then explicitly Publish or Cancel |

### Broadcasts

Send or forward your announcement to the bot's private chat, including its formatting and media. Reply to that message with `/broadcast`. Inspect the copied preview, then tap **Publish**. Only numeric IDs in `ADMIN_IDS` can publish. Membership is checked for each recipient at delivery time; users who have not started the bot cannot receive a message.

The bot preserves Bot API text entities, photos and GIF/MP4 animations with `copyMessage`. Apps show the received announcement only when its sender is the configured bot and it carries the bot's announcement marker. Bold, italic, underline, strike, monospace and HTTP(S) links are rendered; unsupported entity styles retain readable text. Media downloads are capped at 20 MB. Android animations loop; iOS video animations have playback controls, GIFs animate within a decoded-memory limit. Albums and custom announcement buttons/layouts are not supported in this version.

Telegram delivers the bot's messages and handles its normal system notifications according to the user's Telegram settings. Cinespice does not request notification permission or schedule duplicate native alerts. No separate FCM/APNs integration is needed for this flow.

Inside Cinespice, trusted broadcasts appear as a compact **Announcement** banner. Tap it to open the full formatted text/photo/animation, then use **Close**; **Dismiss** hides the banner without opening it. Nothing opens automatically. While Cinespice is open, broadcasts arrive through its account connection. The **Notifications** bell beside **Channels** opens the message history, including text-only posts and media. Closing a post or dismissing its banner keeps it in that history. The app reloads messages from the bot conversation after restart; **Load older notifications** pages through earlier messages instead of limiting history to the newest post. Pull to refresh on iOS or tap Refresh on Android. Broadcasts remain readable in Telegram. Do not delete the source message before a queued broadcast completes.

To remove **one** announcement, reply to its original source message, bot preview or delivered bot copy with `/clear`. Tap **Delete announcement** to confirm, or **Cancel**. Alternatively send `/clear <broadcast ID>` using the ID in the publish confirmation. If the same source was published more than once, select one of the most recent 20 matching broadcast IDs; use the exact ID to remove an older one. Only that broadcast is removed from app history; its pending deliveries are cancelled and other announcements stay. Deletions survive bot restarts, retry transient/blocked-chat errors, and stop older history pages from restoring the announcement. Keep the control marker in bot conversations so reinstalled clients can reconstruct the deletion.

To clear **all** app notifications, send `/clearall` privately from an `ADMIN_IDS` account. The bot sends a silent clear marker to every started account and cancels older pending broadcasts. Broadcasts published afterward still appear. Offline apps apply removals when they reconnect. Telegram chat copies remain readable. **Command change:** `/clear_notifications` is now an alias for selecting one announcement; `/clearall` performs the previous full-clear action. Update the bot and rebuild both apps for individual removal support; older builds only understand full clears.

### Public welcome and support

Normal `/start` (including the paid-group welcome link) shows a branded Cinespice introduction without running membership verification. It includes **Join chat group**, **Contact me**, and an updates button for each `REQUIRED_CHANNELS` entry. `/help` asks users to raise questions/issues in the chat group. Set optional `CHAT_GROUP_URL` in `licensing-bot/.env` to your support/chat invite, and `CONTACT_URL` to your contact link. Without `CHAT_GROUP_URL`, the group button falls back to `CONTACT_URL`, preserving existing configuration. These welcome links are bot settings; the new support URL does not require changing the signing key or public app config. Changing the app's own `contactURL` still requires exporting config and rebuilding.

The public private-chat command menu shows `/start` and `/help`. Admin private-chat menus also show broadcast, clear, stats, ID and license commands. Numeric `ADMIN_IDS` checks protect every admin handler and confirmation callback even if someone types a hidden command manually. App `/start cs2_<installation>_<nonce>`, legacy challenge links, `/check` and `/verified` remain reserved protocol flows; their signed, account-bound verification is unchanged.

Photos fit within the message viewport without cropping or using their original pixel size as layout width. Animations use the same bounded area. Text-only posts have no blank image area; media posts show loading and retry states if the file is unavailable or exceeds the existing 20 MB limit.

## Troubleshooting

- **Bot stopped (BadRequest) in an older checkout:** Telegram rejected a startup request. Check the exact numeric `PAID_GROUP_ID` and every `REQUIRED_CHANNELS` ID, and add the bot as an administrator in each chat. A private invite URL or username is not a numeric chat ID. The paid group must remain private. Updated startup errors name the failing setting or webhook operation without exposing tokens or provider response details.
- **Signing key file not found / Bot stopped (FileNotFoundError):** check the `SIGNING_KEY` path in `.env`. Relative paths start from the terminal's current working directory (`licensing-bot/`), and the default is `state/signing-key.pem`. Point it to the existing private `.pem` key used for your app's public config, or restore that key from your backup. `access-config.local.json` cannot replace the private signing key. If the original key is lost, a new key requires exporting new public configuration and rebuilding the apps; it cannot verify against an already distributed app's public key.
- **Missing configuration / Bot stopped (KeyError) in an older checkout:** update the bot and install its requirements. Run from `licensing-bot/` with your existing file named exactly `.env` (check that Windows has not named it `.env.txt`). Include all six required settings (`BOT_TOKEN`, `BOT_USERNAME`, `BOT_USER_ID`, `PAID_GROUP_ID`, `ADMIN_IDS`, `CONTACT_URL`) and check `REQUIRED_CHANNELS`. Updated code names missing variables/fields without printing their values. Check for stale terminal variables if a file change seems ignored. Do not share your token, `.env` or signing key when asking for help.
- **Setup pending:** export your real public config, set the Actions variable, and rebuild. A bot running alone cannot configure an already installed app.
- **No reply:** keep the bot running, check connectivity, and ensure no other process polls the same token. Existing webhooks are removed at startup without discarding queued updates.
- **Awaiting approval:** add the buyer's actual signed-in numeric account to the private paid group. A username match/contact-group membership is insufficient.
- **Join required:** check *all* configured channels, including approval of pending requests, and check again.
- **Unavailable:** restore bot administrator/membership permissions and network connectivity. Provider errors never approve an account.
- **Invalid/ignored receipt:** verify bot username/ID/public key match the installed app. Correct the device clock. Lost/replaced signing keys require new public config and app builds.
- **Two-step password not requested:** an existing account session can restore authentication without re-entering the password. The separate access gate still runs; this bot does not change account authentication or store cloud passwords.
- **Bot stopped:** unexpired passes keep working until their deadline. New activations fail closed. Restore the bot using the same state and signing key.

## Development checks

```sh
python -m unittest discover -s tests -v
```

Run development checks from a full repository checkout. The tests use synthetic accounts and mocked Bot API operations. The shared Python-signed fixture at `Tests/Fixtures/access-receipt.json` is also checked by Android's actual Java crypto verifier and the Swift receipt parser (and CryptoKit on macOS). Test the real membership/activation/broadcast flow with your own test group before selling access.
