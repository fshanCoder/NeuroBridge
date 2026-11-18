"""Optional HTTPS delivery adapter with a durable, idempotent outbox."""

import json
import os
import time
import urllib.request
from urllib.parse import urlparse

SCHEMA = """
CREATE TABLE IF NOT EXISTS outbound(
 id TEXT PRIMARY KEY, event TEXT NOT NULL REFERENCES event(id), channel TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'queued', retry_at REAL NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0);
CREATE TRIGGER IF NOT EXISTS queue_alert AFTER INSERT ON event WHEN NEW.kind='alert' BEGIN
 INSERT INTO outbound(id,event,channel) VALUES(NEW.id||'/push',NEW.id,'push');
 INSERT INTO outbound(id,event,channel,retry_at) VALUES(NEW.id||'/sms',NEW.id,'sms',unixepoch()+60);
END;
"""


def deliver(payload, key):
    endpoint = os.getenv("NB_DELIVERY_URL", "")
    if urlparse(endpoint).scheme != "https":
        raise RuntimeError("Configure an HTTPS delivery adapter")
    headers = {"Content-Type": "application/json", "Idempotency-Key": key}
    if secret := os.getenv("NB_DELIVERY_TOKEN"):
        headers["Authorization"] = "Bearer " + secret
    req = urllib.request.Request(
        endpoint, data=json.dumps(payload).encode(), headers=headers
    )
    with urllib.request.urlopen(req, timeout=5) as response:
        return 200 <= response.status < 300


def dispatch(database):
    if not os.getenv("NB_DELIVERY_URL"):
        return
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("""UPDATE outbound SET state='stopped' WHERE state='queued' AND event IN
            (SELECT event.id FROM event LEFT JOIN alert_outcome USING(id) WHERE acknowledged IS NOT NULL OR outcome IS NOT NULL)""")
        row = db.execute(
            """SELECT o.id,o.event,o.channel,o.attempts,e.patient,e.body,e.created,s.contact
            FROM outbound o JOIN event e ON e.id=o.event LEFT JOIN care_settings s ON s.patient=e.patient
            WHERE o.state='queued' AND retry_at<=? ORDER BY retry_at LIMIT 1""",
            (time.time(),),
        ).fetchone()
        if not row:
            return
        db.execute(
            "UPDATE outbound SET attempts=attempts+1,retry_at=? WHERE id=?",
            (time.time() + 60, row["id"]),
        )
    try:
        accepted = deliver(dict(row), row["id"])
    except (OSError, RuntimeError, ValueError):
        accepted = False
    with database() as db:
        db.execute(
            "UPDATE outbound SET state=?,retry_at=? WHERE id=? AND state='queued'",
            (
                "accepted" if accepted else "queued",
                time.time() + min(3600, 15 * 2 ** min(8, row["attempts"])),
                row["id"],
            ),
        )
