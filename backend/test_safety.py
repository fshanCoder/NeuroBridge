from datetime import datetime, timezone, timedelta
import os
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch
from uuid import uuid4
from fastapi.testclient import TestClient
from backend.main import app, database
from backend import delivery, safety


class SafetyIntegration(TestCase):
    def setUp(self):
        folder = TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        env = patch.dict(
            os.environ,
            NB_DATABASE=folder.name + "/test.sqlite3",
            NB_DEMO_OTP="1",
            NB_DELIVERY_URL="",
        )
        env.start()
        self.addCleanup(env.stop)
        self.api = TestClient(app)
        self.profile = {"name": "Alex", "carer": "Sam", "consent": True}
        self.user = self.api.post("/v1/patients", json=self.profile).json()
        self.auth = {"Authorization": "Bearer " + self.user["token"]}
        self.carer = {"Authorization": "Bearer " + self.user["pairing_key"]}

    def test_timeout_wins_late_response_and_queues_once(self):
        key = str(uuid4())
        path = "/v1/safety/checks"
        self.api.post(
            path, headers=self.auth, json={"id": key, "reason": "Unresponsive"}
        ).raise_for_status()
        with database() as db:
            db.execute(
                "UPDATE safety_check SET deadline=? WHERE id=?",
                ((datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(), key),
            )
        self.assertEqual(
            self.api.post(
                path + "/" + key, headers=self.carer, json={"action": "help"}
            ).status_code,
            403,
        )
        answer = self.api.post(
            path + "/" + key, headers=self.auth, json={"action": "safe"}
        ).json()
        self.assertEqual(answer["state"], "timed out")
        safety.tick(database)
        with database() as db:
            self.assertEqual(
                db.execute("SELECT count(*) FROM event WHERE id=?", (key,)).fetchone()[
                    0
                ],
                1,
            )
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM outbound WHERE event=?", (key,)
                ).fetchone()[0],
                2,
            )
        with (
            patch.dict(os.environ, NB_DELIVERY_URL="https://example.invalid/alerts"),
            patch.object(delivery, "deliver", return_value=True) as adapter,
        ):
            delivery.dispatch(database)
            self.assertEqual(adapter.call_args.args[0]["channel"], "push")
            self.api.post(
                "/v1/alerts/" + key + "/acknowledge", headers=self.carer
            ).raise_for_status()
            delivery.dispatch(database)
            self.assertEqual(adapter.call_count, 1)

    def test_minor_and_single_use_phone_grant(self):
        issue = self.api.post("/v1/auth/otp", json={"phone": "+15555550123"}).json()
        verify = self.api.post(
            "/v1/auth/verify-otp", json={"id": issue["id"], "code": issue["demo_code"]}
        ).json()
        data = {**self.profile, "minor": True, "phone_grant": verify["grant"]}
        self.assertEqual(self.api.post("/v1/patients", json=data).status_code, 422)
        data["guardian"] = "Robin"
        self.assertEqual(self.api.post("/v1/patients", json=data).status_code, 201)
        self.assertEqual(self.api.post("/v1/patients", json=data).status_code, 422)

    def test_simulated_fall_opens_persistent_window(self):
        self.api.post(
            "/v1/care/settings",
            headers=self.auth,
            json={"consent": True, "history": "", "contact": ""},
        ).raise_for_status()
        self.api.post("/v1/care/calibrate", headers=self.auth).raise_for_status()
        result = self.api.post(
            "/v1/care/samples", headers=self.auth, json={"mode": "Fall detection"}
        ).json()
        check = self.api.get("/v1/board", headers=self.auth).json()["safety"]
        self.assertEqual((check["id"], check["state"]), (result["id"], "waiting"))
        self.api.post(
            "/v1/safety/checks/" + check["id"],
            headers=self.auth,
            json={"action": "safe"},
        ).raise_for_status()
        stamp = datetime.now(timezone.utc).isoformat()
        body = {
            "id": str(uuid4()),
            "mode": "Emotion",
            "result": "Happy",
            "started": stamp,
            "confirmed": stamp,
        }
        for _ in range(2):
            self.api.post(
                "/v1/care/offline-observations", headers=self.auth, json=body
            ).raise_for_status()
        summary = self.api.get("/v1/care", headers=self.auth).json()
        self.assertEqual(summary["analysis"]["moods"][0]["samples"], 1)
        self.assertEqual(summary["confirmed"], 1)
