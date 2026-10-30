import sqlite3
import time
from pathlib import Path


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        path.chmod(0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS deliveries (campaign TEXT NOT NULL, user_id INTEGER NOT NULL,
            source_chat INTEGER NOT NULL, source_message INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0, next_try INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(campaign,user_id));
        ''')
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS paid_membership_checks (
            user_id INTEGER PRIMARY KEY, member INTEGER, next_check INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS bot_contact_events (
            update_id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, blocked INTEGER NOT NULL, observed_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS active_devices (user_id INTEGER PRIMARY KEY, device TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS access_state (user_id INTEGER PRIMARY KEY, revoked INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS access_events (user_id INTEGER PRIMARY KEY, revision INTEGER NOT NULL, next_try INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS notice_clears (user_id INTEGER PRIMARY KEY, campaign TEXT NOT NULL, next_try INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS notice_deletes (user_id INTEGER NOT NULL, campaign TEXT NOT NULL, next_try INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(user_id,campaign));
          CREATE TABLE IF NOT EXISTS campaigns (id TEXT PRIMARY KEY, source_chat INTEGER NOT NULL, source_message INTEGER NOT NULL, cleared INTEGER NOT NULL DEFAULT 0);
          INSERT OR IGNORE INTO campaigns(id,source_chat,source_message) SELECT campaign,source_chat,source_message FROM deliveries;
          CREATE TABLE IF NOT EXISTS receipts (user_id INTEGER NOT NULL, nonce TEXT NOT NULL, message_id INTEGER NOT NULL,
            request_id INTEGER NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(user_id,nonce));
        """)
        self.db.commit()

    def start(self, uid: int):
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO users VALUES (?,?)', (uid, int(time.time())))
            self.db.execute('INSERT OR IGNORE INTO paid_membership_checks VALUES (?,NULL,?)', (uid, int(time.time())+900))
            self.db.execute('UPDATE notice_clears SET next_try=0 WHERE user_id=?', (uid,))
            self.db.execute('UPDATE notice_deletes SET next_try=0 WHERE user_id=?', (uid,))

    def record_bot_contact_event(self, update_id: int, uid: int, blocked: bool, observed_at: int) -> bool:
        with self.db:
            cursor = self.db.execute('INSERT OR IGNORE INTO bot_contact_events VALUES (?,?,?,?)',
                                     (update_id, uid, int(blocked), observed_at))
            return cursor.rowcount == 1

    def recent_bot_contact_events(self, limit=20):
        return self.db.execute('SELECT user_id,blocked,observed_at FROM bot_contact_events ORDER BY observed_at DESC, rowid DESC LIMIT ?',
                               (limit,)).fetchall()

    def started(self, uid: int) -> bool:
        return self.db.execute('SELECT 1 FROM users WHERE id=?', (uid,)).fetchone() is not None

    def access_state(self, uid: int):
        row = self.db.execute('SELECT revoked,revision FROM access_state WHERE user_id=?', (uid,)).fetchone()
        return (bool(row[0]), row[1]) if row else (False, 0)

    def access_changed(self, uid: int, revoked=None):
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO access_state(user_id) VALUES (?)', (uid,))
            self.db.execute('UPDATE access_state SET revision=revision+1 WHERE user_id=?', (uid,))
            if revoked is not None:
                self.db.execute('UPDATE access_state SET revoked=? WHERE user_id=?', (int(revoked), uid))
            revision = self.access_state(uid)[1]
            if self.started(uid):
                self.db.execute('INSERT INTO access_events(user_id,revision) VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,next_try=0', (uid,revision))
        return revision

    def authorize_device(self, uid, device, *, transfer):
        # /start explicitly activates a device; /check may adopt a legacy account
        # only if no device is registered, and must never steal another slot.
        with self.db:
            row = self.db.execute('SELECT device FROM active_devices WHERE user_id=?', (uid,)).fetchone()
            if row and row[0] != device and not transfer:
                return False
            if row and row[0] != device:
                self.db.execute('INSERT OR IGNORE INTO access_state(user_id) VALUES (?)', (uid,))
                self.db.execute('UPDATE access_state SET revision=revision+1 WHERE user_id=?', (uid,))
                revision = self.access_state(uid)[1]
                self.db.execute('INSERT INTO access_events(user_id,revision) VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,next_try=0', (uid, revision))
            self.db.execute('INSERT INTO active_devices VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET device=excluded.device', (uid,device))
        return True

    def schedule_membership_reconciliation(self):
        # Existing databases have no snapshot yet. Preserve known membership across restarts.
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO paid_membership_checks(user_id) SELECT id FROM users')
            self.db.execute('UPDATE paid_membership_checks SET next_check=0')

    def next_membership_check(self):
        return self.db.execute("""SELECT checks.user_id, checks.member, COALESCE(state.revision,0)
            FROM paid_membership_checks AS checks
            LEFT JOIN access_state AS state ON checks.user_id=state.user_id
            WHERE checks.next_check<=? ORDER BY checks.next_check,checks.user_id LIMIT 1""", (int(time.time()),)).fetchone()

    def observe_paid_membership(self, uid, member):
        # An event is an observation, not a grant. A fresh lookup follows to handle
        # old Telegram updates delivered after a restart.
        with self.db:
            self.db.execute('UPDATE paid_membership_checks SET member=?,next_check=0 WHERE user_id=?', (int(member), uid))

    def complete_membership_check(self, uid, previous, revision, member):
        with self.db:
            row = self.db.execute('SELECT member FROM paid_membership_checks WHERE user_id=?', (uid,)).fetchone()
            if row is None:
                return
            # Membership updates can arrive while the network request is in flight.
            if row[0] != previous or self.access_state(uid)[1] != revision:
                self.db.execute('UPDATE paid_membership_checks SET next_check=0 WHERE user_id=?', (uid,))
                return
            if previous is None or bool(previous) != member:
                self.db.execute('INSERT OR IGNORE INTO access_state(user_id) VALUES (?)', (uid,))
                self.db.execute('UPDATE access_state SET revision=revision+1 WHERE user_id=?', (uid,))
                new_revision = self.access_state(uid)[1]
                self.db.execute('INSERT INTO access_events(user_id,revision) VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,next_try=0', (uid,new_revision))
            self.db.execute('UPDATE paid_membership_checks SET member=?,next_check=? WHERE user_id=?', (int(member),int(time.time())+900,uid))

    def retry_membership_check(self, uid, seconds):
        with self.db:
            self.db.execute('UPDATE paid_membership_checks SET next_check=? WHERE user_id=?', (int(time.time())+seconds,uid))

    def next_access_event(self):
        return self.db.execute('SELECT user_id,revision FROM access_events WHERE next_try<=? ORDER BY next_try,user_id LIMIT 1', (int(time.time()),)).fetchone()

    def finish_access_event(self, uid, revision, retry=False):
        with self.db:
            if retry:
                self.db.execute('UPDATE access_events SET next_try=? WHERE user_id=? AND revision=?', (int(time.time())+30,uid,revision))
            else:
                self.db.execute('DELETE FROM access_events WHERE user_id=? AND revision=?', (uid,revision))

    def remember_receipt(self, uid, nonce, message, request, status):
        with self.db:
            self.db.execute('DELETE FROM receipts WHERE created_at<?', (int(time.time())-86400,))
            self.db.execute('INSERT OR REPLACE INTO receipts VALUES (?,?,?,?,?,?,?)', (uid,nonce,message,request,status,self.access_state(uid)[1],int(time.time())))

    def pending_receipt(self, uid, nonce):
        return self.db.execute('SELECT message_id,request_id,status,revision FROM receipts WHERE user_id=? AND nonce=? AND created_at>=?', (uid,nonce,int(time.time())-86400)).fetchone()

    def forget_receipt(self, uid, nonce):
        with self.db:
            self.db.execute('DELETE FROM receipts WHERE user_id=? AND nonce=?', (uid,nonce))

    def campaign_exists(self, campaign: str) -> bool:
        return self.db.execute('SELECT 1 FROM campaigns WHERE id=?', (campaign,)).fetchone() is not None

    def queue(self, campaign: str, chat: int, message: int) -> int:
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO campaigns(id,source_chat,source_message) VALUES (?,?,?)', (campaign,chat,message))
            if not self.campaign_active(campaign): return 0
            self.db.execute('INSERT OR IGNORE INTO deliveries(campaign,user_id,source_chat,source_message) SELECT ?,id,?,? FROM users', (campaign, chat, message))
        return self.db.execute('SELECT COUNT(*) FROM deliveries WHERE campaign=?', (campaign,)).fetchone()[0]

    def next_delivery(self):
        return self.db.execute("SELECT campaign,user_id,source_chat,source_message,attempts FROM deliveries WHERE state='pending' AND next_try<=? ORDER BY rowid LIMIT 1", (int(time.time()),)).fetchone()

    def delivered(self, campaign: str, uid: int, state='sent'):
        with self.db:
            self.db.execute("UPDATE deliveries SET state=? WHERE campaign=? AND user_id=? AND state='pending'", (state, campaign, uid))

    def retry(self, campaign: str, uid: int, delay: int):
        with self.db:
            self.db.execute('UPDATE deliveries SET attempts=attempts+1,next_try=? WHERE campaign=? AND user_id=?', (int(time.time()) + delay, campaign, uid))

    def stats(self):
        users = self.db.execute('SELECT COUNT(*) FROM users').fetchone()[0]
        states = dict(self.db.execute('SELECT state,COUNT(*) FROM deliveries GROUP BY state'))
        return users, states

    def close(self):
        self.db.close()

    def clear_notifications(self, campaign):
        with self.db:
            # Cancel old queued copies before placing the clear marker. Future campaigns are unaffected.
            self.db.execute("UPDATE deliveries SET state='cleared' WHERE state='pending'")
            self.db.execute('UPDATE campaigns SET cleared=1')
            self.db.execute("INSERT INTO notice_clears(user_id,campaign) SELECT id,? FROM users WHERE 1 ON CONFLICT(user_id) DO UPDATE SET campaign=excluded.campaign,next_try=0", (campaign,))
        return self.db.execute('SELECT COUNT(*) FROM notice_clears').fetchone()[0]

    def next_notice_clear(self):
        return self.db.execute('SELECT user_id,campaign FROM notice_clears WHERE next_try<=? ORDER BY next_try,user_id LIMIT 1', (int(time.time()),)).fetchone()

    def finish_notice_clear(self, uid, campaign, seconds=0):
        with self.db:
            if seconds:
                self.db.execute('UPDATE notice_clears SET next_try=? WHERE user_id=? AND campaign=?', (int(time.time())+seconds,uid,campaign))
            else:
                removed = self.db.execute('DELETE FROM notice_clears WHERE user_id=? AND campaign=?', (uid,campaign)).rowcount
                if removed:
                    self.db.execute("UPDATE deliveries SET next_try=0 WHERE user_id=? AND state='pending'", (uid,))

    def notice_clear_pending(self, uid):
        return self.db.execute('SELECT 1 FROM notice_clears WHERE user_id=?', (uid,)).fetchone() is not None

    def delay_delivery(self, campaign, uid, seconds):
        with self.db:
            self.db.execute('UPDATE deliveries SET next_try=? WHERE campaign=? AND user_id=?', (int(time.time())+seconds,campaign,uid))

    def campaign_active(self, campaign):
        return self.db.execute('SELECT 1 FROM campaigns WHERE id=? AND cleared=0', (campaign,)).fetchone() is not None

    def campaigns_for(self, chat, message):
        return [row[0] for row in self.db.execute('SELECT id FROM campaigns WHERE source_chat=? AND source_message=? AND cleared=0 ORDER BY rowid DESC', (chat,message))]

    def delete_notification(self, campaign):
        with self.db:
            if not self.campaign_active(campaign): return None
            self.db.execute('UPDATE campaigns SET cleared=1 WHERE id=?', (campaign,))
            self.db.execute("UPDATE deliveries SET state='cleared' WHERE campaign=? AND state='pending'", (campaign,))
            # Include blocked/offline recipients; their authenticated chat history must also be updated.
            self.db.execute('INSERT OR IGNORE INTO notice_deletes(user_id,campaign) SELECT user_id,campaign FROM deliveries WHERE campaign=?', (campaign,))
        return self.db.execute('SELECT COUNT(*) FROM notice_deletes WHERE campaign=?', (campaign,)).fetchone()[0]

    def next_notice_delete(self):
        return self.db.execute('SELECT user_id,campaign FROM notice_deletes WHERE next_try<=? ORDER BY next_try,user_id,campaign LIMIT 1', (int(time.time()),)).fetchone()

    def finish_notice_delete(self, uid, campaign, seconds=0):
        with self.db:
            if seconds:
                self.db.execute('UPDATE notice_deletes SET next_try=? WHERE user_id=? AND campaign=?', (int(time.time())+seconds,uid,campaign))
            else:
                self.db.execute('DELETE FROM notice_deletes WHERE user_id=? AND campaign=?', (uid,campaign))

    def delivery_pending(self, campaign, uid):
        return self.db.execute("SELECT 1 FROM deliveries WHERE campaign=? AND user_id=? AND state='pending'", (campaign,uid)).fetchone() is not None
