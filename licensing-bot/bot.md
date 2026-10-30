# Bot behavior and maintenance

## Access decision

The bot never trusts an app-supplied user ID. `/start cs2_<installation>_<nonce>` and `/check <nonce> <installation>` (plus legacy `/start cs_<nonce>` and `/check <nonce>`) are accepted only in a private bot conversation, using `update.effective_user.id` as identity.

In order:

0. A persisted admin revocation denies access (`revoked`) even if the user remains a member.
1. A SQLite record must show that this account started the bot (`not_started` otherwise).
2. `getChatMember(PAID_GROUP_ID, user_id)` must show active membership (`unpaid` otherwise).
3. A successful activation binds the account to its installation. `/start` on a different installation transfers access and notifies the old one. `/check` never transfers an existing slot.
4. Updates channels are optional. A failed paid-group lookup returns `unavailable`.

Owner, administrator and member count as active; restricted users count only when `is_member` is true. Left, banned and pending requests do not count. The public contact group never grants access. Payment and paid-group admissions are managed manually. `/revoke <numeric user ID>` denies access until an admin uses `/restore`; rejoining cannot undo manual revocation.

Paid-group changes increment an account revision and enqueue a durable private update (`access:1:<revision>`). The bot also reconciles current paid membership on startup and periodically while running. The app checks the bot after an update; only a confirmed denial blocks an existing persistent grant. A stopped bot or unreachable client delays enforcement.

The welcome handler receives `chat_member` changes for the private paid group and posts a welcome plus bot-start link on transitions into membership. Bots are excluded and repeats are limited for five minutes. It cannot DM people who have never started it. The bot must be an administrator and request these update types; `run` already requests them.

## Receipt wire protocol, version 1

```
CSP1.<base64url JSON without padding>.<base64url DER ECDSA signature without padding>
```

The signature uses P-256 ECDSA / SHA-256 over the literal ASCII `CSP1.<encoded payload>`. JSON fields are `v:1`, `uid` as a decimal **string**, a 32-character lowercase hexadecimal `nonce`, `status`, `iat` and `exp` as epoch seconds. Public keys are X.509 SubjectPublicKeyInfo DER encoded as standard base64. The private key is PKCS8 PEM, generated locally.

Fresh replies require the configured bot's private-chat sender, signed-in account, random challenge, valid signature, allowed status and unexpired `iat`/`exp` window. Modern replies also carry signed `device`, `revision`, `paid`, and optional-channel `missing` indices. A signed `persistent: true` is issued only on authorized modern replies. Once initially validated and stored in device-only secure storage, that specific authorized grant can be restored after expiry for the same account and installation. Legacy grants keep their old expiry rules. The signature and account/device binding are verified again on restoration.

`other_device` denies a check from an installation displaced by another activation. A successful `/start` claims the device slot; `/check` adopts only an unassigned legacy account and cannot steal a slot. The SQLite device record and per-account revision survive restarts. `/verified <nonce>` acknowledges a reply and does not grant access. The old installation is blocked only after it receives or checks the transfer, so strict immediate revocation is not possible while communication is unavailable.

The app silently checks at reopen and periodically. A transient verification failure preserves a valid saved grant; a confirmed unpaid, revoked, or other-device result blocks access. Signing out removes the stored grant; reinstalling creates a new installation identity. Back up both the signing key and bot database. Older apps continue to use expiring grants and cannot reliably enforce the new device limit.

## Code map

| File | Responsibility |
|---|---|
| `cinespice_bot/config.py` | Environment parsing, numeric identities, separate paid group, links, TTL |
| `cinespice_bot/protocol.py` | Exclusive private-key generation, public export, signed receipts |
| `cinespice_bot/service.py` | All membership conditions and fail-closed eligibility |
| `cinespice_bot/storage.py` | Started users, manual revocation/revisions, receipt cleanup bookkeeping and durable delivery queues |
| `cinespice_bot/__main__.py` | Commands, group welcomes, preview/confirmation, delivery loop, startup checks |
| `tests/test_bot.py` | Synthetic authorization, signature, persistence and admin-boundary checks |

Apps consume `AccessReceipt` and public `AccessConfiguration`; Android's `AccessController` and iOS's `TelegramClient` own the activation lifecycle. `AccessUi.kt` / `AccessActivationView.swift` provide the gate, and `Announcement.java` / `AccessAnnouncement.swift` render trusted bot announcements.

## Broadcast delivery

Only a configured numeric admin can prepare or confirm a campaign in a private bot chat. One pending preview per admin is held in memory; restarting expires unconfirmed previews. Confirming consumes that preview and snapshots all started user IDs into SQLite. Each delivery rechecks paid-group membership before `copyMessage`. When `ANNOUNCEMENT_CHANNEL_ID` is configured, supported posts from that channel enter the same queue without an admin preview; repeated updates for the same post are deduplicated.

A callback marker `notice:1:<campaign UUID hex>` identifies announcements to the native clients. It is not an access credential. Clients still require the configured bot as the actual sender. The copied message preserves media/formatting and replaces its original buttons with the announcement marker. One text/photo/animation is supported per campaign; albums/custom buttons are future work.

`/clear` (alias `/clear_notifications`) is private/admin-only. Reply to a broadcast source, published copy or preview (or supply its exact campaign ID), select one campaign if needed, and confirm. The durable campaign catalog maps original source IDs and survives restarts; existing delivery rows are migrated on startup. The command marks just that campaign cleared, cancels its pending deliveries, and queues `notice-delete:1:<campaign UUID>` for each original recipient. Clients retain campaign tombstones for the loaded bot history so late/duplicate pages cannot restore the deleted post. Failed control deliveries retry across restarts and `/start` expedites blocked-chat retries. Workers recheck the pending state after asynchronous membership requests before copying, closing the cancellation race at that boundary. An already in-flight remote copy may complete; its queued control marker subsequently removes it from app history.

`/clearall` queues a durable `notice-clear:1:<UUID>` marker for every started user. It cancels pending existing broadcasts; newer deliveries wait until their recipient's clear marker succeeds. Clients apply its bot-chat message ID as a cutoff and ignore older announcements, including out-of-order history pages. Both commands clear app history; Telegram chat copies remain. A blocked bot cannot deliver a marker until the user starts a working conversation again. Clear markers must remain in the conversations for clients to reconstruct deletions after reinstalling.

A normal `/start` shows the Cinespice welcome and app summary with chat-group, contact and optional updates-channel links, without membership API calls. Optional `CHAT_GROUP_URL` controls only the bot support link and falls back to `CONTACT_URL`. `/help` points users to that chat group for issues. Public menus expose `/start` and `/help`; numeric admins receive an expanded private menu. Menu visibility is not authorization: admin commands and callbacks independently check `ADMIN_IDS`. The account-bound challenge `/start` payloads and `/check`/`/verified` preserve the signing and identity checks described above. Unpublished copied previews carry `notice-preview:1:<UUID>`, which apps do not ingest as announcements.

Notifications history is read from paginated TDLib bot-chat history (100 messages/request; returned pages may be smaller). Clients authenticate the bot's actual sender before storing any notice or clear marker. Dismissal hides only the banner; the Notifications list keeps that message. Permanent Telegram message deletions are reflected while connected. UI media fitting uses bounded viewport dimensions and preserves aspect ratio.

The worker sends at most five successful deliveries per second. It respects Bot API `RetryAfter`, retries temporary delivery errors with bounded backoff, and records blocked, ineligible or failed recipients. `/stats` shows aggregate states. State survives restart; unconfirmed previews do not. Queue processing is sequential and **at least once**: a crash after Telegram accepts a message but before SQLite records success can cause a duplicate after restart. Exact-once remote delivery is not promised. Membership errors never deliver to an unchecked recipient.

## Operations and data

The default `state/` directory contains:

- `signing-key.pem`: private signing key, mode 0600;
- `bot.sqlite3` and SQLite WAL/SHM sidecars: started numeric IDs/timestamps plus campaign catalog/delivery bookkeeping, queued announcement removals, manual revocations, the active installation per account, paid-membership snapshots, revision counters, pending membership events and receipt message IDs/nonces/statuses. Receipt cleanup records expire after 24 hours when new receipts are recorded.

Back up the entire state directory with the bot stopped, or use SQLite's backup API while live. Keep `.env`, state and backups private. The bot does not store passwords, payment details, receipt bodies or users' media libraries. Broadcast source chat/message IDs are stored so Telegram can copy the original message; keep it available until delivery completes. SQLite files contain account IDs; treat backups accordingly. Remove obsolete delivery history/users using a deliberate maintenance process; automatic retention/deletion is not implemented.

Only one process may poll a token. Startup validates configured identity and paid-group administrator status and removes an existing webhook while retaining pending updates. Ctrl+C stops polling and the background delivery task. Runtime logs omit raw messages, HTTP URLs, tokens and detailed transport exceptions; diagnose provider/network problems locally without publishing credentials. Pin upgrades, run tests, and test a private staging bot before replacing dependencies. Termux uptime and dependency installation depend on the phone/OS; see the README.

`run` and `export-config` read `.env` in the current working directory, with explicit process environment variables taking precedence. No parent-directory search, shell execution or variable interpolation is performed. Relative signing-key and database paths remain relative to that working directory. Startup reuses the existing key and state; it does not generate a replacement key or rewrite an exported public app configuration.

## Security boundary and future work

This prevents a copied unmodified APK from granting access to a different unpaid account and prevents users from forging grants without the private key. **Client software can still be modified.** App-only checks cannot make a distributed APK uncrackable or restrict content independently accessible to the user's account. Stronger protection for exclusive hosted services requires server-side entitlement checks for those services. Signing is asymmetric so extracting app configuration does not expose an approval secret.

This version enforces one current installation when the bot can communicate with clients; it has no remote attestation, server-protected media endpoints, payment processing, subscription renewals, web dashboard, push-notification service or guaranteed immediate revocation. Offline or missed-event revocation is delayed until a successful check. Group membership is the source of truth, rather than an editable client allowlist. Future additions should preserve the numeric account binding, fresh challenge, fail-closed membership checks and secret separation.
