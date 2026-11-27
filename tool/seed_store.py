#!/usr/bin/env python3
"""
Fills an EMULATOR's message store with a heavy user's worth of texts, to measure how the app loads them.

Matt, 2026-11-13: "Users with a ton of messages stored on their phone are taking forever to load".

    python3 tool/seed_store.py emulator-5586 [--threads 3000] [--seed 7]

It writes straight into Android's own database (mmssms.db of com.android.providers.telephony) with sqlite3 as root,
which only an emulator allows (`adb root`), and it is meant for a throwaway one: start the spare AVD read-only
(`emulator -avd ghostflutter2 -read-only -no-window -port 5586`) so nothing is kept. Sending this many texts through
the emulator's modem would take hours and raise a notification for each.

What it makes, the same every run for a given --seed: [--threads] conversations, most with one person (a third of
those a short code or a sender's name, as sign-in codes come), some groups; a few to a few dozen texts in most, a
few hundred to two thousand in thirty, and three of 20,000, 8,000 and 5,000; picture messages as the newest thing
in about one conversation in eight, and in every group (a group is picture messages throughout), so that the list
has to look past an empty summary. Dates run back three years from now, the newest conversations newest.

The store's own triggers recount a conversation's messages on every insert, so they are taken off for the load and
put back as they were, and each conversation's row is written with its own count and date.
"""

import argparse
import os
import random
import subprocess
import sys
import tempfile
import time

ADB = os.path.expanduser('~/Library/Android/sdk/platform-tools/adb')
# The store once the phone is unlocked. (There is a second, under /data/user_de/, that Android writes to only before
# the first unlock: filling that one shows nothing.)
DB = '/data/user/0/com.android.providers.telephony/databases/mmssms.db'
TRIGGERS = ('sms_update_thread_on_insert', 'pdu_update_thread_on_insert', 'update_threads_on_insert_part')
WORDS = (
    'Running ten minutes late', 'Sounds good', 'See you at 7', 'Call me when you land', 'On my way', 'Did you get the tickets?',
    'haha yes', 'Thanks!', 'Can you pick up milk', 'Your package was delivered', 'Happy birthday!', 'Where are you?',
    'Dinner at mine first?', 'I\'ll send the address', 'ok', 'Meeting moved to 3', 'Love you', 'Good night', 'Here\'s the link https://example.com/a',
    'That works for me, let me check with Sam and get back to you tonight', 'Look at this view', 'lol', 'Just landed', 'Be there in five',
)
SENDERS = ('AMAZON', 'Verify', 'UPS', 'BankAlert', 'Uber', 'DoorDash', 'CVS', 'Delta', 'Venmo', 'GitHub')


# Runs adb against the device `serial`, with `text` as its input: what it printed. Raises where adb fails.
def adb(serial, *args, text=None):
    return subprocess.run([ADB, '-s', serial, *args], input=text, capture_output=True, text=True, check=True).stdout


# A string as SQLite writes one: in single quotes, with any inside doubled.
def q(s):
    return "'" + s.replace("'", "''") + "'"


# Adds to `out` the INSERTs that put `values` (each a row already written out) into `table`, `batch` rows a statement.
def rows(table, columns, values, out, batch=400):
    for i in range(0, len(values), batch):
        out.append('INSERT INTO %s(%s) VALUES %s;' % (table, columns, ','.join(values[i:i + batch])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('serial')
    ap.add_argument('--threads', type=int, default=3000)
    ap.add_argument('--seed', type=int, default=7)
    a = ap.parse_args()
    if not a.serial.startswith('emulator-'):
        sys.exit('An emulator only: this writes into Android\'s own message database as root.')
    r = random.Random(a.seed)
    adb(a.serial, 'root')
    time.sleep(2)
    had = adb(a.serial, 'shell', 'sqlite3 %s "select count(*) from threads"' % DB).strip()
    if had != '0':
        sys.exit('The store already holds %s conversations: this fills an empty one.' % had)
    triggers = {}
    for name in TRIGGERS:
        sql = adb(a.serial, 'shell', 'sqlite3 %s "select sql from sqlite_master where type=\'trigger\' and name=\'%s\'"' % (DB, name)).strip()
        if sql:
            triggers[name] = sql

    now = int(time.time() * 1000)
    addresses, threads, sms, pdu, part, addr = [], [], [], [], [], []
    big = {0: 20000, 1: 8000, 2: 5000}
    mms_id = 0
    for t in range(1, a.threads + 1):
        group = r.random() < 0.15
        if group:
            people = ['+1555%07d' % r.randrange(10 ** 7) for _ in range(r.randint(3, 5))]
        elif r.random() < 0.35:
            people = [r.choice(SENDERS) if r.random() < 0.3 else str(r.randrange(10000, 999999))]
        else:
            people = ['+1555%07d' % r.randrange(10 ** 7)]
        ids = []
        for p in people:
            addresses.append("(%d,%s)" % (len(addresses) + 1, q(p)))
            ids.append(str(len(addresses)))
        # The newest conversations are the lowest numbers: t minutes to three years back.
        newest = now - int((t / a.threads) ** 2 * 3 * 365 * 86400_000) - r.randrange(60_000)
        count = big.get(t - 1) or (r.randint(500, 2000) if t % 100 == 50 else r.randint(1, 30 if r.random() < 0.8 else 120))
        picture_last = group or r.random() < 0.12
        snippet, unread, attachment = '', 0, 0
        when = newest
        for n in range(count):
            incoming = len(people) == 1 and not people[0].startswith('+') or r.random() < 0.55
            body = ('Your verification code is %06d. Don\'t share it.' % r.randrange(10 ** 6)) if not people[0].startswith('+') else r.choice(WORDS)
            read = 0 if (n == 0 and incoming and r.random() < 0.1) else 1
            if group or (n == 0 and picture_last):
                mms_id += 1
                pdu.append("(%d,%d,%d,%d,%d,%s,'application/vnd.wap.multipart.related',%d,18,1,0)" % (
                    mms_id, t, when // 1000, 1 if incoming else 2, read, q('mid%d' % mms_id), 132 if incoming else 128))
                if group:
                    part.append("(%d,0,'text/plain',NULL,'text0.txt',%s)" % (mms_id, q(body)))
                if not group or r.random() < 0.2:
                    part.append("(%d,1,'image/jpeg','image0.jpg','image0.jpg',NULL)" % mms_id)
                    attachment = 1
                addr.append("(%d,%s,137,106)" % (mms_id, q(r.choice(people) if incoming else 'insert-address-token')))
                for p in people:
                    addr.append("(%d,%s,151,106)" % (mms_id, q(p)))
            else:
                sms.append("(%d,%s,%d,%d,%d,-1,%d,%s,1)" % (t, q(people[0]), when, when - 1500, read, 1 if incoming else 2, q(body)))
                if n == 0:
                    snippet = body
            if n == 0:
                unread = 1 - read
            when -= r.randrange(30_000, 6 * 3600_000 if count < 200 else 40 * 60_000)
        threads.append("(%d,%d,%d,%s,%s,%d,%d)" % (t, newest, count, q(' '.join(ids)), q(snippet), 1 - unread, attachment))

    out = ['BEGIN;']
    out += ['DROP TRIGGER IF EXISTS %s;' % name for name in triggers]
    rows('canonical_addresses', '_id,address', addresses, out)
    rows('threads', '_id,date,message_count,recipient_ids,snippet,read,has_attachment', threads, out)
    rows('sms', 'thread_id,address,date,date_sent,read,status,type,body,seen', sms, out)
    rows('pdu', '_id,thread_id,date,msg_box,read,m_id,ct_t,m_type,v,seen,text_only', pdu, out)
    rows('part', 'mid,seq,ct,name,cl,text', part, out)
    rows('addr', 'msg_id,address,type,charset', addr, out)
    out += [sql + ';' for sql in triggers.values()]
    out.append('COMMIT;')
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False) as f:
        f.write('\n'.join(out))
        local = f.name
    try:
        adb(a.serial, 'push', local, '/data/local/tmp/seed.sql')
        adb(a.serial, 'shell', 'sqlite3 %s < /data/local/tmp/seed.sql && rm /data/local/tmp/seed.sql' % DB)
    finally:
        os.unlink(local)
    counted = adb(a.serial, 'shell', 'sqlite3 %s "select (select count(*) from threads), (select count(*) from sms), (select count(*) from pdu), (select count(*) from sqlite_master where type=\'trigger\' and name in (%s))"' % (
        DB, ','.join("'%s'" % n for n in TRIGGERS))).strip()
    th, s, p, tr = counted.split('|')
    print('%s conversations, %s texts, %s picture messages; triggers back: %s of %d' % (th, s, p, tr, len(triggers)))


if __name__ == '__main__':
    main()
