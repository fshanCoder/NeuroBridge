"""Optional phone verification and guardian attribution for enrollment."""

import hashlib
import os
import secrets
import time
from uuid import uuid4
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from .delivery import deliver

SCHEMA = """
CREATE TABLE IF NOT EXISTS phone_code(id TEXT PRIMARY KEY,phone TEXT,secret TEXT,expires REAL,attempts INTEGER,grant_hash TEXT);
CREATE TABLE IF NOT EXISTS enrollment(patient TEXT PRIMARY KEY REFERENCES patient(id),phone TEXT,guardian TEXT);
"""


class Phone(BaseModel):
    phone: str = Field(pattern=r"^\+[1-9][0-9]{6,14}$")


class Verify(BaseModel):
    id: str
    code: str = Field(pattern=r"^[0-9]{6}$")


def digest(s):
    return hashlib.sha256(s.encode()).hexdigest()


def router(database):
    r = APIRouter(prefix="/v1/auth")

    @r.post("/otp")
    def issue(data: Phone):
        demo = os.getenv("NB_DEMO_OTP") == "1"
        if not demo and not os.getenv("NB_DELIVERY_URL"):
            raise HTTPException(
                503, "SMS delivery is not configured for this installation."
            )
        code = f"{secrets.randbelow(1000000):06d}"
        key = str(uuid4())
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute(
                "SELECT 1 FROM phone_code WHERE phone=? AND expires>?",
                (data.phone, time.time() + 240),
            ).fetchone():
                raise HTTPException(429, "Wait one minute before requesting a new code")
            db.execute(
                "DELETE FROM phone_code WHERE phone=? OR expires<?",
                (data.phone, time.time()),
            )
            db.execute(
                "INSERT INTO phone_code VALUES(?,?,?,?,0,NULL)",
                (key, data.phone, digest(key + code), time.time() + 300),
            )
        if not demo:
            try:
                deliver({"channel": "otp", "phone": data.phone, "code": code}, key)
            except (RuntimeError, OSError):
                raise HTTPException(503, "SMS delivery failed")
        return {"id": key, **({"demo_code": code} if demo else {})}

    @r.post("/verify-otp")
    def verify(data: Verify):
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT * FROM phone_code WHERE id=? AND expires>? AND attempts<5 AND grant_hash IS NULL",
                (data.id, time.time()),
            ).fetchone()
            if row:
                db.execute(
                    "UPDATE phone_code SET attempts=attempts+1 WHERE id=?", (data.id,)
                )
                if secrets.compare_digest(row["secret"], digest(data.id + data.code)):
                    grant = secrets.token_urlsafe(24)
                    db.execute(
                        "UPDATE phone_code SET grant_hash=? WHERE id=?",
                        (digest(grant), data.id),
                    )
                    return {"grant": grant}
        raise HTTPException(400, "Incorrect or expired code")

    return r
