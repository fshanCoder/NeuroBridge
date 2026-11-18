"""Durable confirmation windows for simulated sensor signals."""

from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

SCHEMA = """
CREATE TABLE IF NOT EXISTS thresholds(patient TEXT PRIMARY KEY REFERENCES patient(id), confidence REAL, silence INTEGER, stillness INTEGER);
CREATE TABLE IF NOT EXISTS safety_check(
 id TEXT PRIMARY KEY, patient TEXT REFERENCES patient(id), reason TEXT NOT NULL,
 deadline TEXT NOT NULL, state TEXT NOT NULL, changed TEXT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS one_open_check ON safety_check(patient) WHERE state='waiting';
CREATE TABLE IF NOT EXISTS preferences(patient TEXT PRIMARY KEY REFERENCES patient(id),
 seconds INTEGER NOT NULL DEFAULT 15, scan_ms INTEGER NOT NULL DEFAULT 1500,
 dwell_ms INTEGER NOT NULL DEFAULT 1200);
"""


class Preferences(BaseModel):
    confidence: float = Field(default=0.7, ge=0.5, le=1.0)
    silence: int = Field(default=10, ge=2, le=60)
    stillness: int = Field(default=5, ge=1, le=30)
    seconds: int = Field(ge=5, le=300)
    scan_ms: int = Field(ge=500, le=10000)
    dwell_ms: int = Field(ge=500, le=5000)


class Trigger(BaseModel):
    id: UUID
    reason: Literal["Possible fall", "Unresponsive", "Emergency blink", "Head shake"]


class LocalDecision(Trigger):
    deadline: datetime
    decided: datetime
    action: Literal["safe", "help", "timeout"]


class Answer(BaseModel):
    action: Literal["safe", "help"]


def instant():
    return datetime.now(timezone.utc)


def preference(db, patient):
    row = db.execute(
        "SELECT seconds,scan_ms,dwell_ms FROM preferences WHERE patient=?", (patient,)
    ).fetchone()
    timing = dict(row) if row else {"seconds": 15, "scan_ms": 1500, "dwell_ms": 1200}
    thresholds = db.execute(
        "SELECT confidence,silence,stillness FROM thresholds WHERE patient=?",
        (patient,),
    ).fetchone()
    return {
        **timing,
        **(
            dict(thresholds)
            if thresholds
            else {"confidence": 0.7, "silence": 10, "stillness": 5}
        ),
    }


def escalate(db, row, state, timestamp):
    db.execute(
        "INSERT INTO event(id,patient,kind,body,created) VALUES(?,?,'alert',?,?)",
        (
            row["id"],
            row["patient"],
            f"Safety check: {row['reason']} ({state})",
            timestamp,
        ),
    )
    db.execute(
        "UPDATE safety_check SET state=?,changed=? WHERE id=?",
        (state, timestamp, row["id"]),
    )


def expire(db):
    timestamp = instant().isoformat()
    for row in db.execute(
        "SELECT * FROM safety_check WHERE state='waiting' AND deadline<=?", (timestamp,)
    ).fetchall():
        escalate(db, row, "timed out", timestamp)


def tick(database):
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        expire(db)


def latest(db, patient):
    row = db.execute(
        "SELECT id,reason,deadline,state FROM safety_check WHERE patient=? ORDER BY (state='waiting') DESC,changed DESC LIMIT 1",
        (patient,),
    ).fetchone()
    return dict(row) if row else None


def open_window(db, patient, key, reason):
    now = instant()
    deadline = now + timedelta(seconds=preference(db, patient)["seconds"])
    db.execute(
        "INSERT OR IGNORE INTO safety_check VALUES(?,?,?,?,'waiting',?)",
        (key, patient, reason, deadline.isoformat(), now.isoformat()),
    )
    return latest(db, patient)


def router(database, identity):
    api = APIRouter(prefix="/v1/safety")

    def owner(actor=Depends(identity)):
        p, role = actor
        if role != "patient":
            raise HTTPException(403)
        return p["id"]

    @api.post("/preferences")
    def save(data: Preferences, p=Depends(owner)):
        with database() as db:
            db.execute(
                "INSERT OR REPLACE INTO thresholds VALUES(?,?,?,?)",
                (p, data.confidence, data.silence, data.stillness),
            )
            db.execute(
                "INSERT OR REPLACE INTO preferences VALUES(?,?,?,?)",
                (p, data.seconds, data.scan_ms, data.dwell_ms),
            )
        return data

    @api.post("/checks")
    def start(data: Trigger, p=Depends(owner)):
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            expire(db)
            key = str(data.id)
            prior = db.execute(
                "SELECT * FROM safety_check WHERE id=?", (key,)
            ).fetchone()
            if prior:
                if prior["patient"] != p or prior["reason"] != data.reason:
                    raise HTTPException(409)
                return dict(prior)
            open_check = db.execute(
                "SELECT * FROM safety_check WHERE patient=? AND state='waiting'", (p,)
            ).fetchone()
            if open_check:
                return dict(open_check)
            return open_window(db, p, key, data.reason)

    @api.post("/local-decisions")
    def replay(data: LocalDecision, p=Depends(owner)):
        if not data.deadline.tzinfo or not data.decided.tzinfo:
            raise HTTPException(422, "Decision timestamps must include a time zone")
        key = str(data.id)
        state = (
            "timed out"
            if data.decided >= data.deadline or data.action == "timeout"
            else "cancelled"
            if data.action == "safe"
            else "help confirmed"
        )
        stamp = data.decided.astimezone(timezone.utc).isoformat()
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM safety_check WHERE id=?", (key,)).fetchone()
            if row:
                if (
                    row["patient"] != p
                    or row["state"] != state
                    or row["reason"] != data.reason
                ):
                    raise HTTPException(409, "Conflicting local decision")
                return {"state": state}
            db.execute(
                "INSERT INTO safety_check VALUES(?,?,?,?,?,?)",
                (
                    key,
                    p,
                    data.reason,
                    data.deadline.astimezone(timezone.utc).isoformat(),
                    state,
                    stamp,
                ),
            )
            if state != "cancelled":
                escalate(
                    db, {"id": key, "patient": p, "reason": data.reason}, state, stamp
                )
        return {"state": state}

    @api.post("/checks/{key}")
    def answer(key: UUID, data: Answer, p=Depends(owner)):
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            expire(db)
            row = db.execute(
                "SELECT * FROM safety_check WHERE patient=? AND id=?", (p, str(key))
            ).fetchone()
            if not row:
                raise HTTPException(404)
            if row["state"] == "waiting":
                now = instant().isoformat()
                if data.action == "safe":
                    db.execute(
                        "UPDATE safety_check SET state='cancelled',changed=? WHERE id=?",
                        (now, str(key)),
                    )
                else:
                    escalate(db, row, "help confirmed", now)
            return dict(
                db.execute(
                    "SELECT * FROM safety_check WHERE id=?", (str(key),)
                ).fetchone()
            )

    return api
