"""Reporting and patient-authorized device status."""

from datetime import datetime, timedelta, timezone
from pydantic import BaseModel, Field
from fastapi import APIRouter, Depends, HTTPException

SCHEMA = """
CREATE TABLE IF NOT EXISTS response_time(id TEXT PRIMARY KEY REFERENCES observation(id),confirmed_at TEXT);
CREATE TABLE IF NOT EXISTS device(patient TEXT PRIMARY KEY REFERENCES patient(id), seen TEXT,battery INTEGER,lat REAL,lon REAL,location_at TEXT);
"""


class Status(BaseModel):
    battery: int | None = Field(default=None, ge=0, le=100)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)


def metrics(db, p, start, end):
    row = db.execute(
        """SELECT count(*) attempts,count(o.result) confirmed,
        avg((julianday(t.confirmed_at)-julianday(o.created))*86400) seconds
        FROM observation o LEFT JOIN response_time t USING(id)
        WHERE o.patient=? AND o.created>=? AND o.created<?""",
        (p, start, end),
    ).fetchone()
    return dict(row)


def summary(db, p, days):
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)
    moods = [
        dict(r)
        for r in db.execute(
            """SELECT substr(created,1,13) hour,result,count(*) samples FROM observation
        WHERE patient=? AND mode='Emotion' AND result IS NOT NULL AND created>=?
        GROUP BY hour,result ORDER BY hour DESC""",
            (p, start.isoformat()),
        )
    ]
    return {
        "current": metrics(db, p, start.isoformat(), end.isoformat()),
        "previous": metrics(
            db, p, (start - timedelta(days=days)).isoformat(), start.isoformat()
        ),
        "moods": moods,
    }


def router(database, identity, now):
    api = APIRouter()

    @api.post("/v1/device")
    def status(data: Status, actor=Depends(identity)):
        p, role = actor
        if role != "patient":
            raise HTTPException(403)
        if (data.lat is None) != (data.lon is None):
            raise HTTPException(422)
        with database() as db:
            db.execute(
                """INSERT INTO device VALUES(?,?,?,?,?,?) ON CONFLICT(patient) DO UPDATE SET
                seen=excluded.seen,battery=excluded.battery,lat=excluded.lat,lon=excluded.lon,location_at=excluded.location_at""",
                (
                    p["id"],
                    now(),
                    data.battery,
                    data.lat,
                    data.lon,
                    now() if data.lat is not None else None,
                ),
            )
        return {"saved": True}

    return api
