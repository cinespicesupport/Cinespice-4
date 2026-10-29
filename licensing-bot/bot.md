# Bot behavior and maintenance

## Access decision

The bot never trusts an app-supplied user ID. `/start cs2_<installation>_<nonce>` and `/check <nonce> <installation>` (plus legacy `/start cs_<nonce>` and `/check <nonce>`) are accepted only in a private bot conversation, using `update.effective_user.id` as identity.

In order:

0. A persisted admin revocation denies access (`revoked`) even if the user remains a member.
1. A SQLite record must show that this account started the bot (`not_started` otherwise).
2. `getChatMember(PAID_GROUP_ID, user_id)` must show active membership (`unpaid` otherwise).
3. Every `REQUIRED_CHANNELS` numeric ID must show active membership (`join_required` otherwise).
4. If all pass, return `authorized`. Any membership API error returns `unavailable`.

Owner, administrator and member count as active; restricted users count only when `is_member` is true. Left, banned and pending requests do not count. The public contact group never grants access. There are no payment webhooks, subscriptions, automatic expiry dates or admin approval commands: **you manage the private group's membership manually**. Remove a member to invalidate current activation via a membership event and deny future passes. `/revoke <numeric user ID>` denies all installations until an admin uses `/restore <numeric user ID>`; rejoining cannot undo manual revocation. Keep paid-group admission and invitations private; another group administrator admitting someone also grants entitlement.

Membership handlers watch the paid group and every required channel. Leave/ban/removal and return transitions increment a per-account revision and enqueue a durable, coalesced private update (`access:1:<revision>`). The actual configured bot sender is required; this marker can only invalidate, never grant. Failed notifications retry; missed/offline events remain bounded by pass expiry.

The welcome handler receives `chat_member` changes for the private paid group and posts a welcome plus bot-start link on transitions into membership. Bots are excluded and repeats are limited for five minutes. It cannot DM people who have never started it. The bot must be an administrator and request these update types; `run` already requests them.

## Receipt wire protocol, version 1

```
CSP1.<base64url JSON without padding>.<base64url DER ECDSA signature without padding>
```

The signature uses P-256 ECDSA / SHA-256 over the literal ASCII `CSP1.<encoded payload>`. JSON fields are `v:1`, `uid` as a decimal **string**, a 32-character lowercase hexadecimal `nonce`, `status`, `iat` and `exp` as epoch seconds. Public keys are X.509 SubjectPublicKeyInfo DER encoded as standard base64. The private key is PKCS8 PEM, generated locally.

Apps require the configured bot's real private-chat sender, a matching signed-in account, the current random challenge, a valid signature, an allowed status, a current expiry, and a lifetime of at most 24 hours. Issued-at allows 60 seconds of clock skew. Raw receipts are not displayed as Cinespice announcements. Invalid, replayed, forwarded, stale or mismatched replies do not unlock the library. Verification requests time out after 75 seconds and can be retried.

New clients also require signed `device` (24 lowercase hex), nonnegative `revision`, `paid` (whether paid membership is missing) and `missing` (zero-based required-channel indices). The start payload is 61 characters, within Telegram's 64-character limit. Legacy clients retain the old payload format. `/verified <nonce>` acknowledges a validated reply: the bot edits it to Verified or a denial and deletes the matching request and acknowledgment. The acknowledgment never grants access.

Only `authorized` unlocks the library. `ACCESS_TTL_SECONDS` defaults to 3600 and accepts 60–86400. Denial receipts last 60 seconds. Passes and their nonce, installation ID and latest revision are saved in device-only secure storage per account and public configuration. A valid cached pass restores on process restart. Expired passes renew silently; new logins require Activate. Live events invalidate the saved grant before rechecking. Both wall-clock expiry and a monotonic deadline enforce the current session's limit. Background renewal runs near expiry; this is not perpetual offline access. Native media preparation, range requests and playback lifecycle also enforce the gate. Sign-out remains available on the activation screen. No account password/code is sent to or stored by the bot.

Changing channels, contacts or bot identity requires exporting new public settings and rebuilding both apps. Membership and TTL changes affect new checks immediately, while existing passes retain their signed lifetime. **Back up the signing key.** Replacing it requires updating the trusted public key in all installed apps. This version supports one signing key; rolling multi-key rotation is future work.

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

Only a configured numeric admin can prepare or confirm a campaign in a private bot chat. One pending preview per admin is held in memory; restarting expires unconfirmed previews. Confirming consumes that preview and snapshots all started user IDs into SQLite. Each delivery rechecks all current membership requirements before `copyMessage`.

A callback marker `notice:1:<campaign UUID hex>` identifies announcements to the native clients. It is not an access credential. Clients still require the configured bot as the actual sender. The copied message preserves media/formatting and replaces its original buttons with the announcement marker. One text/photo/animation is supported per campaign; albums/custom buttons are future work.

`/clear` (alias `/clear_notifications`) is private/admin-only. Reply to a broadcast source, published copy or preview (or supply its exact campaign ID), select one campaign if needed, and confirm. The durable campaign catalog maps original source IDs and survives restarts; existing delivery rows are migrated on startup. The command marks just that campaign cleared, cancels its pending deliveries, and queues `notice-delete:1:<campaign UUID>` for each original recipient. Clients retain campaign tombstones for the loaded bot history so late/duplicate pages cannot restore the deleted post. Failed control deliveries retry across restarts and `/start` expedites blocked-chat retries. Workers recheck the pending state after asynchronous membership requests before copying, closing the cancellation race at that boundary. An already in-flight remote copy may complete; its queued control marker subsequently removes it from app history.

`/clearall` queues a durable `notice-clear:1:<UUID>` marker for every started user. It cancels pending existing broadcasts; newer deliveries wait until their recipient's clear marker succeeds. Clients apply its bot-chat message ID as a cutoff and ignore older announcements, including out-of-order history pages. Both commands clear app history; Telegram chat copies remain. A blocked bot cannot deliver a marker until the user starts a working conversation again. Clear markers must remain in the conversations for clients to reconstruct deletions after reinstalling.

A normal `/start` shows the Cinespice welcome and app summary with chat-group, contact and required-channel update links, without membership API calls. Optional `CHAT_GROUP_URL` controls only the bot support link and falls back to `CONTACT_URL`. `/help` points users to that chat group for issues. Public menus expose `/start` and `/help`; numeric admins receive an expanded private menu. Menu visibility is not authorization: admin commands and callbacks independently check `ADMIN_IDS`. The account-bound challenge `/start` payloads and `/check`/`/verified` app protocol retain the original access decision and signature contract. Unpublished copied previews carry `notice-preview:1:<UUID>`, which apps do not ingest as announcements.

Notifications history is read from paginated TDLib bot-chat history (100 messages/request; returned pages may be smaller). Clients authenticate the bot's actual sender before storing any notice or clear marker. Dismissal hides only the banner; the Notifications list keeps that message. Permanent Telegram message deletions are reflected while connected. UI media fitting uses bounded viewport dimensions and preserves aspect ratio.

The worker sends at most five successful deliveries per second. It respects Bot API `RetryAfter`, retries temporary delivery errors with bounded backoff, and records blocked, ineligible or failed recipients. `/stats` shows aggregate states. State survives restart; unconfirmed previews do not. Queue processing is sequential and **at least once**: a crash after Telegram accepts a message but before SQLite records success can cause a duplicate after restart. Exact-once remote delivery is not promised. Membership errors never deliver to an unchecked recipient.

## Operations and data

The default `state/` directory contains:

- `signing-key.pem`: private signing key, mode 0600;
- `bot.sqlite3` and SQLite WAL/SHM sidecars: started numeric IDs/timestamps plus campaign catalog/delivery bookkeeping, queued announcement removals, manual revocations, revision counters, pending membership events and receipt message IDs/nonces/statuses. Receipt cleanup records expire after 24 hours when new receipts are recorded.

Back up the entire state directory with the bot stopped, or use SQLite's backup API while live. Keep `.env`, state and backups private. The bot does not store passwords, payment details, receipt bodies or users' media libraries. Broadcast source chat/message IDs are stored so Telegram can copy the original message; keep it available until delivery completes. SQLite files contain account IDs; treat backups accordingly. Remove obsolete delivery history/users using a deliberate maintenance process; automatic retention/deletion is not implemented.

Only one process may poll a token. Startup validates configured identity and chat administrator status and removes an existing webhook while retaining pending updates. Ctrl+C stops polling and the background delivery task. Runtime logs omit raw messages, HTTP URLs, tokens and detailed transport exceptions; diagnose provider/network problems locally without publishing credentials. Pin upgrades, run tests, and test a private staging bot before replacing dependencies. Termux uptime and dependency installation depend on the phone/OS; see the README.

`run` and `export-config` read `.env` in the current working directory, with explicit process environment variables taking precedence. No parent-directory search, shell execution or variable interpolation is performed. Relative signing-key and database paths remain relative to that working directory. Startup reuses the existing key and state; it does not generate a replacement key or rewrite an exported public app configuration.

## Security boundary and future work

This prevents a copied unmodified APK from granting access to a different unpaid account and prevents users from forging grants without the private key. **Client software can still be modified.** App-only checks cannot make a distributed APK uncrackable or restrict content independently accessible to the user's account. Stronger protection for exclusive hosted services requires server-side entitlement checks for those services. Signing is asymmetric so extracting app configuration does not expose an approval secret.

This version has no device-count limits, remote attestation, server-protected media endpoints, payment processing, subscription renewals, web dashboard, push-notification service or guaranteed immediate revocation. Online revocation uses membership events; offline/missed-event revocation is bounded by the signed pass's remaining lifetime. Group membership is the source of truth, rather than an editable client allowlist. Future additions should preserve the numeric account binding, fresh challenge, fail-closed membership checks and secret separation.
