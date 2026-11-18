"""Patient-scoped care workspace. Recognition is a deterministic simulator."""

import json
from pathlib import Path
from . import insights, safety
from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field, StringConstraints
from typing import Annotated

TEXT = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)
]
SAMPLES = {
    "Lip reading": ["I need water", "I want to eat"],
    "Hand gesture": ["Yes", "No"],
    "Emotion": [
        "Neutral",
        "Happy",
        "Sad",
        "Angry",
        "Crying",
        "Excited",
        "Irritated",
        "Frustrated",
        "Quiet",
        "Scared",
        "Sleepy",
        "Pain",
    ],
    "Eye movement": ["Single blink", "Emergency blink", "Unresponsive"],
    "Head movement": ["Nod", "Head shake"],
    "Activity": ["Seated", "Resting"],
    "Fall detection": ["Possible fall", "No fall"],
}
SCHEMA = """
CREATE TABLE IF NOT EXISTS patient_details(patient TEXT PRIMARY KEY REFERENCES patient(id), age INTEGER,disability TEXT,blood_group TEXT,hospital TEXT);
CREATE TABLE IF NOT EXISTS therapy_start(patient TEXT PRIMARY KEY REFERENCES patient(id), started TEXT);
CREATE TABLE IF NOT EXISTS alert_outcome(id TEXT PRIMARY KEY REFERENCES event(id), outcome TEXT, closed TEXT);
CREATE TABLE IF NOT EXISTS model_revision(patient TEXT REFERENCES patient(id),version INTEGER, samples INTEGER,accepted INTEGER,created TEXT,PRIMARY KEY(patient,version));
CREATE TABLE IF NOT EXISTS demo_model(patient TEXT PRIMARY KEY REFERENCES patient(id), version INTEGER, samples INTEGER, created TEXT);
CREATE TABLE IF NOT EXISTS gesture(patient TEXT REFERENCES patient(id), label TEXT, PRIMARY KEY(patient,label));
CREATE TABLE IF NOT EXISTS care_settings(
 patient TEXT PRIMARY KEY REFERENCES patient(id), history TEXT DEFAULT '', contact TEXT DEFAULT '',
 consent INTEGER DEFAULT 0, calibration TEXT, baseline INTEGER, baseline_at TEXT, doctor_hash TEXT UNIQUE
);
CREATE TABLE IF NOT EXISTS observation(
 id TEXT PRIMARY KEY, patient TEXT REFERENCES patient(id), mode TEXT, result TEXT, created TEXT
);
CREATE TABLE IF NOT EXISTS care_entry(
 id TEXT PRIMARY KEY, patient TEXT REFERENCES patient(id), kind TEXT, body TEXT, created TEXT, due TEXT
);
CREATE INDEX IF NOT EXISTS care_entry_patient ON care_entry(patient,kind,created);
"""


class Outcome(BaseModel):
    outcome: Literal["Cancelled", "Resolved", "False alarm"]


class Settings(BaseModel):
    age: int | None = Field(default=None, ge=0, le=125)
    disability: str = Field(default="", max_length=160)
    blood_group: str = Field(default="", max_length=12)
    hospital: str = Field(default="", max_length=160)
    guardian: str = Field(default="", max_length=80)
    history: str = Field(max_length=500)
    contact: str = Field(max_length=160)
    consent: bool


class Translation(BaseModel):
    text: TEXT
    target: Literal[
        "English",
        "Hindi",
        "Punjabi",
        "Tamil",
        "Spanish",
        "French",
        "Arabic",
        "Japanese",
        "Chinese",
    ]


class Sample(BaseModel):
    mode: str


class OfflineSample(BaseModel):
    id: UUID
    mode: str
    result: TEXT
    started: datetime
    confirmed: datetime


class Confirmation(BaseModel):
    result: TEXT


class Entry(BaseModel):
    kind: Literal["note", "reminder", "reply"]
    text: TEXT
    due: datetime | None = None


def router(database, identity, digest, now):
    import secrets

    routes = APIRouter(prefix="/v1/care")

    def require(role, *allowed):
        if role not in allowed:
            raise HTTPException(403, "This action is unavailable for this role")

    @routes.get("")
    def workspace(days: int = 7, actor=Depends(identity)):
        p, role = actor
        if days not in (1, 7, 30):
            raise HTTPException(422, "Choose a day, week or month")
        pid = p["id"]
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        with database() as db:
            db.execute("INSERT OR IGNORE INTO care_settings(patient) VALUES(?)", (pid,))
            settings = dict(
                db.execute(
                    "SELECT history,contact,consent,calibration,baseline,baseline_at,doctor_hash IS NOT NULL AS doctor_linked FROM care_settings WHERE patient=?",
                    (pid,),
                ).fetchone()
            )
            details = db.execute(
                "SELECT age,disability,blood_group,hospital FROM patient_details WHERE patient=?",
                (pid,),
            ).fetchone()
            if details:
                settings.update(dict(details))
            guardian = db.execute(
                "SELECT guardian FROM enrollment WHERE patient=?", (pid,)
            ).fetchone()
            settings["guardian"] = guardian[0] if guardian and guardian[0] else ""
            analysis = insights.summary(db, pid, days)
            anchor = db.execute(
                "SELECT started FROM therapy_start WHERE patient=?", (pid,)
            ).fetchone()
            if anchor:
                therapy = datetime.fromisoformat(anchor[0])
                span = timedelta(days=days)
                analysis["therapy"] = {
                    "started": anchor[0],
                    "before": insights.metrics(
                        db, pid, (therapy - span).isoformat(), anchor[0]
                    ),
                    "after": insights.metrics(
                        db,
                        pid,
                        anchor[0],
                        min(datetime.now(timezone.utc), therapy + span).isoformat(),
                    ),
                }
            totals = dict(
                db.execute(
                    "SELECT kind,count(*) FROM event WHERE patient=? AND created>=? GROUP BY kind",
                    (pid, cutoff),
                )
            )
            observations = [
                dict(r)
                for r in db.execute(
                    "SELECT * FROM observation WHERE patient=? AND created>=? ORDER BY created DESC LIMIT 50",
                    (pid, cutoff),
                )
            ]
            entries = [
                dict(r)
                for r in db.execute(
                    "SELECT kind,body,created,due FROM care_entry WHERE patient=? AND kind!='reminder' AND created>=? ORDER BY created DESC LIMIT 50",
                    (pid, cutoff),
                )
            ]
            reminders = [
                dict(r)
                for r in db.execute(
                    "SELECT id,body,due FROM care_entry WHERE patient=? AND kind='reminder' ORDER BY due",
                    (pid,),
                )
            ]
            model = db.execute(
                "SELECT version,samples,created FROM demo_model WHERE patient=?", (pid,)
            ).fetchone()
            versions = [
                dict(r)
                for r in db.execute(
                    "SELECT version,samples,accepted,created FROM model_revision WHERE patient=? ORDER BY version DESC LIMIT 2",
                    (pid,),
                )
            ]
            gestures = [
                r[0]
                for r in db.execute(
                    "SELECT label FROM gesture WHERE patient=? ORDER BY label", (pid,)
                )
            ]
            confirmed = db.execute(
                "SELECT count(*) FROM observation WHERE patient=? AND result IS NOT NULL AND created>=?",
                (pid, cutoff),
            ).fetchone()[0]
        return dict(
            versions=versions,
            simulator=SAMPLES,
            analysis=analysis,
            model=dict(model) if model else None,
            gestures=gestures,
            settings=settings,
            totals=totals,
            observations=observations,
            entries=entries,
            reminders=reminders,
            confirmed=confirmed,
            modes=list(SAMPLES),
            days=days,
        )

    @routes.get("/report")
    def report(days: int = 7, actor=Depends(identity)):
        p, role = actor
        require(role, "doctor")
        data = workspace(days, actor)
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        with database() as db:
            notes = [
                dict(r)
                for r in db.execute(
                    "SELECT body,created FROM care_entry WHERE kind='note' AND patient=? AND created>=? ORDER BY created",
                    (p["id"], cutoff),
                )
            ]
        return {
            "totals": data["totals"],
            "confirmed": data["confirmed"],
            "baseline": data["settings"]["baseline"],
            "notes": notes,
        }

    @routes.post("/settings")
    def settings(data: Settings, actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        with database() as db:
            if data.age is not None and data.age < 18 and not data.guardian.strip():
                raise HTTPException(
                    422, "A consenting guardian is required for a minor"
                )
            db.execute(
                "INSERT OR REPLACE INTO patient_details VALUES(?,?,?,?,?)",
                (p["id"], data.age, data.disability, data.blood_group, data.hospital),
            )
            if data.guardian.strip():
                db.execute(
                    "INSERT INTO enrollment(patient,guardian) VALUES(?,?) ON CONFLICT(patient) DO UPDATE SET guardian=excluded.guardian",
                    (p["id"], data.guardian.strip()),
                )
            db.execute(
                """INSERT INTO care_settings(patient,history,contact,consent) VALUES(?,?,?,?)
                ON CONFLICT(patient) DO UPDATE SET history=excluded.history,contact=excluded.contact,consent=excluded.consent""",
                (p["id"], data.history, data.contact, data.consent),
            )
        return {"saved": True}

    @routes.post("/doctor-key")
    def doctor_key(actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        key = secrets.token_urlsafe(24)
        with database() as db:
            db.execute(
                "INSERT INTO care_settings(patient,doctor_hash) VALUES(?,?) ON CONFLICT(patient) DO UPDATE SET doctor_hash=excluded.doctor_hash",
                (p["id"], digest(key)),
            )
        return {"key": key}

    @routes.post("/revoke-doctor")
    def revoke(actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        with database() as db:
            db.execute(
                "UPDATE care_settings SET doctor_hash=NULL WHERE patient=?", (p["id"],)
            )
        return {"revoked": True}

    @routes.post("/calibrate")
    @routes.post("/baseline")
    def checkpoint(request: Request, actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        with database() as db:
            db.execute(
                "INSERT OR IGNORE INTO care_settings(patient) VALUES(?)", (p["id"],)
            )
            if request.url.path.endswith("/baseline"):
                count = db.execute(
                    "SELECT count(*) FROM event WHERE kind='phrase' AND patient=? AND created>=?",
                    (
                        p["id"],
                        (datetime.now(timezone.utc) - timedelta(days=7)).isoformat(),
                    ),
                ).fetchone()[0]
                db.execute(
                    "UPDATE care_settings SET baseline=?,baseline_at=? WHERE patient=?",
                    (count, now(), p["id"]),
                )
            else:
                changed = db.execute(
                    "UPDATE care_settings SET calibration=? WHERE patient=? AND consent=1",
                    (now(), p["id"]),
                ).rowcount
                if not changed:
                    raise HTTPException(
                        409, "Enable simulation in profile settings first"
                    )
        return {"saved": True}

    @routes.post("/therapy-start")
    def therapy_start(actor=Depends(identity)):
        p, role = actor
        require(role, "doctor")
        with database() as db:
            db.execute(
                "INSERT OR REPLACE INTO therapy_start VALUES(?,?)", (p["id"], now())
            )
        return {"saved": True}

    @routes.post("/offline-observations")
    def offline(data: OfflineSample, actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        if (
            data.mode not in SAMPLES
            or not data.started.tzinfo
            or not data.confirmed.tzinfo
            or data.confirmed < data.started
        ):
            raise HTTPException(422, "Invalid observation")
        with database() as db:
            permitted = db.execute(
                "SELECT consent,calibration FROM care_settings WHERE patient=?",
                (p["id"],),
            ).fetchone()
            if not permitted or not permitted[0] or not permitted[1]:
                raise HTTPException(403, "Simulation consent or calibration is missing")
            values = (
                str(data.id),
                p["id"],
                data.mode,
                data.result,
                data.started.astimezone(timezone.utc).isoformat(),
            )
            db.execute("INSERT OR IGNORE INTO observation VALUES(?,?,?,?,?)", values)
            if (
                tuple(
                    db.execute(
                        "SELECT * FROM observation WHERE id=?", (str(data.id),)
                    ).fetchone()
                )
                != values
            ):
                raise HTTPException(409, "Conflicting observation")
            db.execute(
                "INSERT OR IGNORE INTO response_time VALUES(?,?)",
                (str(data.id), data.confirmed.astimezone(timezone.utc).isoformat()),
            )
        return {"saved": True}

    @routes.post("/samples")
    def sample(data: Sample, actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        if data.mode not in SAMPLES:
            raise HTTPException(422, "Unknown mode")
        key = str(uuid4())
        with database() as db:
            settings = db.execute(
                "SELECT consent,calibration FROM care_settings WHERE patient=?",
                (p["id"],),
            ).fetchone()
            if not settings or not settings["consent"] or not settings["calibration"]:
                raise HTTPException(
                    409, "Enable simulation and run demo calibration first"
                )
            db.execute(
                "INSERT INTO observation VALUES(?,?,?,?,?)",
                (key, p["id"], data.mode, None, now()),
            )
            signal = {
                "Fall detection": "Possible fall",
                "Eye movement": "Unresponsive",
                "Head movement": "Head shake",
            }.get(data.mode)
            configured = safety.preference(db, p["id"])
            if (signal == "Possible fall" and configured["stillness"] > 5) or (
                signal == "Unresponsive" and configured["silence"] > 10
            ):
                signal = None
            if signal:
                safety.open_window(db, p["id"], key, signal)
            candidates = list(SAMPLES[data.mode])
            if data.mode == "Hand gesture":
                candidates.extend(
                    r[0]
                    for r in db.execute(
                        "SELECT label FROM gesture WHERE patient=? ORDER BY label",
                        (p["id"],),
                    )
                )
        return {
            "id": key,
            "simulated": True,
            "confidence": 0.61,
            "signal": signal,
            "candidates": candidates,
        }

    @routes.post("/samples/{key}/confirm")
    def confirm(key: str, data: Confirmation, actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT mode,result FROM observation WHERE id=? AND patient=?",
                (key, p["id"]),
            ).fetchone()
            if not row:
                raise HTTPException(404)
            if not db.execute(
                "SELECT consent FROM care_settings WHERE patient=?", (p["id"],)
            ).fetchone()[0]:
                raise HTTPException(403)
            if row["result"] and row["result"] != data.result:
                raise HTTPException(409, "Sample already confirmed")
            db.execute("INSERT OR IGNORE INTO response_time VALUES(?,?)", (key, now()))
            db.execute("UPDATE observation SET result=? WHERE id=?", (data.result, key))
        return {"saved": True}

    @routes.post("/entries")
    def entry(data: Entry, actor=Depends(identity)):
        p, role = actor
        require(
            role,
            *{
                "note": ["doctor"],
                "reply": ["doctor", "carer"],
                "reminder": ["patient", "carer", "doctor"],
            }[data.kind],
        )
        due = None
        if data.kind == "reminder":
            if (
                not data.due
                or not data.due.tzinfo
                or data.due <= datetime.now(timezone.utc)
            ):
                raise HTTPException(422, "Choose a future reminder time")
            due = data.due.astimezone(timezone.utc).isoformat()
        key = str(uuid4())
        with database() as db:
            db.execute(
                "INSERT INTO care_entry VALUES(?,?,?,?,?,?)",
                (key, p["id"], data.kind, data.text, now(), due),
            )
            if data.kind == "reply":
                db.execute(
                    "INSERT INTO event(id,patient,kind,body,created) VALUES(?,?,?,?,?)",
                    (key, p["id"], "reply", data.text, now()),
                )
        return {"id": key}

    @routes.post("/reminders/{key}/complete")
    def complete(key: str, actor=Depends(identity)):
        p, _ = actor
        with database() as db:
            if not db.execute(
                "DELETE FROM care_entry WHERE patient=? AND id=? AND kind='reminder'",
                (p["id"], key),
            ).rowcount:
                raise HTTPException(404)
        return {"completed": True}

    @routes.post("/translate")
    def translate(data: Translation, actor=Depends(identity)):
        phrases = json.loads(
            (
                Path(__file__).resolve().parents[1]
                / "frontend/assets/data/phrases.json"
            ).read_text()
        )
        result = phrases.get(data.text, {}).get(data.target)
        return {
            "translated": result,
            "available": result is not None,
            "source": "phrase cache",
        }

    @routes.post("/personalize")
    def personalize(actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            config = db.execute(
                "SELECT consent FROM care_settings WHERE patient=?", (p["id"],)
            ).fetchone()
            if not config or not config[0]:
                raise HTTPException(403, "Enable simulation first")
            samples = db.execute(
                "SELECT count(*) FROM observation WHERE patient=? AND result IS NOT NULL",
                (p["id"],),
            ).fetchone()[0]
            if not samples:
                raise HTTPException(409, "Confirm a sample first")
            db.execute(
                """INSERT INTO demo_model VALUES(?,1,?,?) ON CONFLICT(patient) DO UPDATE SET
                version=demo_model.version+1,samples=excluded.samples,created=excluded.created""",
                (p["id"], samples, now()),
            )
            model = db.execute(
                "SELECT version,created FROM demo_model WHERE patient=?", (p["id"],)
            ).fetchone()
            accepted = sum(
                row["result"] == SAMPLES[row["mode"]][0]
                for row in db.execute(
                    "SELECT mode,result FROM observation WHERE patient=? AND result IS NOT NULL",
                    (p["id"],),
                )
            )
            db.execute(
                "INSERT INTO model_revision VALUES(?,?,?,?,?)",
                (p["id"], model[0], samples, accepted, model[1]),
            )
        return {"simulated": True}

    @routes.post("/gestures")
    def gesture(data: Confirmation, actor=Depends(identity)):
        p, role = actor
        require(role, "patient")
        with database() as db:
            db.execute(
                "INSERT OR IGNORE INTO gesture VALUES(?,?)", (p["id"], data.result)
            )
        return {"saved": True}

    @routes.post("/alerts/{key}/close")
    def close(key: str, data: Outcome, actor=Depends(identity)):
        p, role = actor
        require(role, "patient" if data.outcome == "Cancelled" else "carer")
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            event = db.execute(
                "SELECT acknowledged FROM event WHERE patient=? AND kind='alert' AND id=?",
                (p["id"], key),
            ).fetchone()
            if event is None:
                raise HTTPException(404)
            if data.outcome == "Resolved" and not event[0]:
                raise HTTPException(409, "Acknowledge this request first")
            db.execute(
                "INSERT OR IGNORE INTO alert_outcome VALUES(?,?,?)",
                (key, data.outcome, now()),
            )
            if (
                db.execute(
                    "SELECT outcome FROM alert_outcome WHERE id=?", (key,)
                ).fetchone()[0]
                != data.outcome
            ):
                raise HTTPException(409, "This request has already been closed")
        return {"outcome": data.outcome}

    return routes
