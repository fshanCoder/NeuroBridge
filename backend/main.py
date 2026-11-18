"""NeuroBridge local care-board service."""

import hashlib
import os
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID, uuid4

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, StringConstraints
from typing import Annotated, Literal

import asyncio
from contextlib import asynccontextmanager, suppress
from . import care, safety, insights, delivery, enrollment


@asynccontextmanager
async def lifespan(app):
    async def monitor():
        while True:
            await asyncio.sleep(0.5)
            try:
                await asyncio.to_thread(safety.tick, database)
            except sqlite3.OperationalError:
                continue

    async def send_outbound():
        while True:
            await asyncio.sleep(1)
            await asyncio.to_thread(delivery.dispatch, database)

    sender = asyncio.create_task(send_outbound())
    worker = asyncio.create_task(monitor())
    try:
        yield
    finally:
        sender.cancel()
        with suppress(asyncio.CancelledError):
            await sender
        worker.cancel()
        with suppress(asyncio.CancelledError):
            await worker


app = FastAPI(title="NeuroBridge", version="1.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv(
        "NB_ORIGINS", "http://localhost:8080,http://127.0.0.1:8080"
    ).split(","),
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)
Name = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)
]
SCHEMA = """
CREATE TABLE IF NOT EXISTS patient (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, carer TEXT NOT NULL,
 patient_hash TEXT UNIQUE NOT NULL, carer_hash TEXT UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS event (
 id TEXT PRIMARY KEY, patient TEXT NOT NULL REFERENCES patient(id),
 kind TEXT NOT NULL, body TEXT NOT NULL, created TEXT NOT NULL,
 acknowledged TEXT, who TEXT
);
CREATE INDEX IF NOT EXISTS patient_events ON event(patient,created);
"""


@contextmanager
def database():
    path = os.getenv("NB_DATABASE", str(Path(__file__).with_name("care.sqlite3")))
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    try:
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript(
            SCHEMA
            + care.SCHEMA
            + safety.SCHEMA
            + insights.SCHEMA
            + delivery.SCHEMA
            + enrollment.SCHEMA
        )
        with db:
            yield db
    finally:
        db.close()


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def now():
    return datetime.now(timezone.utc).isoformat()


class Profile(BaseModel):
    name: Name
    carer: Name
    consent: Literal[True]
    minor: bool = False
    guardian: str = Field(default="", max_length=80)
    phone_grant: str | None = None


class Event(BaseModel):
    id: UUID
    kind: Literal["phrase", "alert"]
    text: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
    ]
    occurred_at: datetime


def identity(auth: HTTPAuthorizationCredentials = Depends(HTTPBearer())):
    token = digest(auth.credentials)
    with database() as db:
        row = db.execute(
            "SELECT * FROM patient WHERE patient_hash=? OR carer_hash=?", (token, token)
        ).fetchone()
        if row is None:
            doctor = db.execute(
                "SELECT p.* FROM patient p JOIN care_settings s ON s.patient=p.id WHERE s.doctor_hash=?",
                (token,),
            ).fetchone()
            if doctor is not None:
                return doctor, "doctor"
    if row is None:
        raise HTTPException(401, "Invalid credentials")
    return row, "patient" if token == row["patient_hash"] else "carer"


@app.post("/v1/patients", status_code=201)
def register(profile: Profile):
    patient, carer = secrets.token_urlsafe(24), secrets.token_urlsafe(18)
    with database() as db:
        if profile.minor and not profile.guardian.strip():
            raise HTTPException(422, "Guardian name is required")
        phone = None
        if profile.phone_grant:
            import time

            row = db.execute(
                "DELETE FROM phone_code WHERE grant_hash=? AND expires>? RETURNING phone",
                (digest(profile.phone_grant), time.time()),
            ).fetchone()
            if not row:
                raise HTTPException(422, "Invalid phone verification")
            phone = row[0]
        pid = str(uuid4())
        db.execute(
            "INSERT INTO patient VALUES(?,?,?,?,?)",
            (pid, profile.name, profile.carer, digest(patient), digest(carer)),
        )
        db.execute(
            "INSERT INTO enrollment VALUES(?,?,?)",
            (pid, phone, profile.guardian.strip() if profile.minor else None),
        )
    return {"token": patient, "pairing_key": carer}


@app.get("/v1/board")
def board(actor=Depends(identity)):
    patient, role = actor
    with database() as db:
        if role == "patient":
            db.execute(
                "INSERT INTO device(patient,seen) VALUES(?,?) ON CONFLICT(patient) DO UPDATE SET seen=excluded.seen",
                (patient["id"], now()),
            )
        device = db.execute(
            "SELECT seen,battery,lat,lon,location_at FROM device WHERE patient=?",
            (patient["id"],),
        ).fetchone()
        check = safety.latest(db, patient["id"])
        preferences = safety.preference(db, patient["id"])
        due = db.execute(
            "SELECT body,due FROM care_entry WHERE patient=? AND kind='reminder' AND due<=? ORDER BY due",
            (patient["id"], now()),
        ).fetchall()
        rows = db.execute(
            """SELECT event.id, kind, body AS text, created, acknowledged, who,outcome FROM event LEFT JOIN alert_outcome ON alert_outcome.id=event.id
            WHERE patient=? ORDER BY created DESC LIMIT 50""",
            (patient["id"],),
        ).fetchall()
        open_alerts = db.execute(
            "SELECT event.id,created,acknowledged FROM event LEFT JOIN alert_outcome USING(id) WHERE patient=? AND kind='alert' AND outcome IS NULL ORDER BY created DESC",
            (patient["id"],),
        ).fetchall()
        outbound = db.execute(
            "SELECT channel,state FROM outbound JOIN event ON outbound.event=event.id WHERE patient=? ORDER BY created DESC LIMIT 4",
            (patient["id"],),
        ).fetchall()
        pending = db.execute(
            """SELECT id, created FROM event WHERE patient=? AND kind='alert'
            AND acknowledged IS NULL AND id NOT IN (SELECT id FROM alert_outcome) ORDER BY created""",
            (patient["id"],),
        ).fetchall()
    return {
        "name": patient["name"],
        "carer": patient["carer"],
        "role": role,
        "open_alerts": [dict(r) for r in open_alerts],
        "delivery": [
            {
                "channel": r["channel"],
                "state": r["state"]
                if os.getenv("NB_DELIVERY_URL")
                else "Adapter not configured",
            }
            for r in outbound
        ],
        "device": dict(device) if device else None,
        "safety": check,
        "preferences": preferences,
        "due_reminders": [dict(r) for r in due],
        "events": [dict(r) for r in rows],
        "pending": [dict(r) for r in pending],
    }


@app.post("/v1/events")
def record(event: Event, actor=Depends(identity)):
    patient, role = actor
    if role != "patient":
        raise HTTPException(403)
    if event.occurred_at.tzinfo is None:
        raise HTTPException(422, "A time zone is required")
    created = event.occurred_at.astimezone(timezone.utc).isoformat()
    with database() as db:
        key = str(event.id)
        values = (patient["id"], event.kind, event.text, created)
        db.execute(
            "INSERT OR IGNORE INTO event(id,patient,kind,body,created) VALUES(?,?,?,?,?)",
            (key, *values),
        )
        existing = db.execute(
            "SELECT patient,kind,body,created FROM event WHERE id=?", (key,)
        ).fetchone()
        if tuple(existing) != values:
            raise HTTPException(409, "Conflicting event ID")
    return {"id": key}


@app.post("/v1/alerts/{alert_id}/acknowledge")
def acknowledge(alert_id: UUID, actor=Depends(identity)):
    patient, role = actor
    if role != "carer":
        raise HTTPException(403)
    with database() as db:
        args = (str(alert_id), patient["id"])
        db.execute("BEGIN IMMEDIATE")
        if db.execute(
            "SELECT 1 FROM alert_outcome JOIN event USING(id) WHERE id=? AND patient=?",
            args,
        ).fetchone():
            raise HTTPException(409, "This request has been closed")
        db.execute(
            """UPDATE event SET acknowledged=?, who=? WHERE id=? AND patient=?
            AND kind='alert' AND acknowledged IS NULL""",
            (now(), patient["carer"], *args),
        )
        row = db.execute(
            "SELECT who,acknowledged FROM event WHERE id=? AND patient=? AND kind='alert'",
            args,
        ).fetchone()
        if row is None:
            raise HTTPException(404)
    return dict(row)


app.include_router(enrollment.router(database))
app.include_router(insights.router(database, identity, now))
app.include_router(safety.router(database, identity))
app.include_router(care.router(database, identity, digest, now))

# A built client and the API share an origin in the local demo.
from fastapi.staticfiles import StaticFiles

web_build = Path(__file__).resolve().parents[1] / "frontend/build/web"
if (web_build / "index.html").is_file():
    app.mount("/", StaticFiles(directory=web_build, html=True), name="frontend")
