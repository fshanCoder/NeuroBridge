from datetime import datetime, timedelta, timezone
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

from fastapi.testclient import TestClient
from backend.main import app


class WorkspaceFlow(TestCase):
    def setUp(self):
        folder = TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        env = patch.dict("os.environ", NB_DATABASE=folder.name + "/care.sqlite3")
        env.start()
        self.addCleanup(env.stop)
        self.api = TestClient(app)
        profile = self.api.post("/v1/patients", json={"name":"Alex","carer":"Sam","consent":True}).json()
        self.patient = {"Authorization":"Bearer " + profile["token"]}
        self.carer = {"Authorization":"Bearer " + profile["pairing_key"]}

    def test_simulation_and_clinician_access(self):
        def post(path, body=None, role=None):
            return self.api.post("/v1/care/" + path, headers=role or self.patient, json=body or {})
        self.assertEqual(post("samples", {"mode":"Eye movement"}).status_code,409)
        post("settings", {"history":"Demo only","contact":"Sam","consent":True}).raise_for_status()
        post("calibrate").raise_for_status()
        samples = self.api.get("/v1/care",headers=self.patient).json()["modes"]
        for mode in samples:
            sample = post("samples", {"mode":mode}).json()
            self.assertTrue(sample["simulated"])
            post(f"samples/{sample['id']}/confirm", {"result":"Corrected"}).raise_for_status()
        post("baseline").raise_for_status()
        translated=post("translate",{"text":"I need water","target":"Spanish"}).json()
        self.assertEqual(translated["translated"],"Necesito agua")
        self.assertFalse(post("translate",{"text":"Uncached","target":"French"}).json()["available"])
        post("gestures",{"result":"Bring my glasses"}).raise_for_status()
        self.assertIn("Bring my glasses",post("samples",{"mode":"Hand gesture"}).json()["candidates"])
        post("personalize").raise_for_status()
        model=self.api.get("/v1/care",headers=self.patient).json()["model"]
        self.assertEqual(model["samples"],len(samples))
        self.assertEqual(model["version"],1)
        doctor = {"Authorization":"Bearer " + post("doctor-key").json()["key"]}
        self.assertEqual(self.api.get("/v1/board",headers=doctor).json()["role"], "doctor")
        post("entries",{"kind":"note","text":"Practice session"},doctor).raise_for_status()
        self.assertEqual(post("entries",{"kind":"note","text":"Restricted"},self.carer).status_code,403)
        post("entries",{"kind":"reply","text":"I am here"},self.carer).raise_for_status()
        due = (datetime.now(timezone.utc)+timedelta(days=1)).isoformat()
        reminder = post("entries",{"kind":"reminder","text":"Practice","due":due},doctor).json()
        state = self.api.get("/v1/care?days=1",headers=self.patient).json()
        self.assertEqual(state["confirmed"],len(samples))
        self.assertEqual(state["settings"]["baseline"],0)
        self.assertEqual(state["reminders"][0]["id"],reminder["id"])
        post(f"reminders/{reminder['id']}/complete").raise_for_status()
        report=self.api.get("/v1/care/report",headers=doctor).json()
        self.assertEqual(report["notes"][0]["body"],"Practice session")
        self.assertEqual(self.api.get("/v1/care/report",headers=self.carer).status_code,403)
        post("revoke-doctor").raise_for_status()
        self.assertEqual(self.api.get("/v1/care",headers=doctor).status_code,401)


    def test_closed_request_cannot_be_acknowledged(self):
        from uuid import uuid4
        key = str(uuid4())
        self.api.post("/v1/events",headers=self.patient,json={
            "kind":"alert","id":key,"text":"Please help",
            "occurred_at":datetime.now(timezone.utc).isoformat()}).raise_for_status()
        self.api.post(f"/v1/care/alerts/{key}/close",headers=self.patient,json={"outcome":"Cancelled"}).raise_for_status()
        self.assertEqual(self.api.post(f"/v1/alerts/{key}/acknowledge",headers=self.carer).status_code,409)
        board=self.api.get("/v1/board",headers=self.carer).json()
        self.assertEqual(board["pending"],[])
        self.assertEqual(board["events"][0]["outcome"],"Cancelled")
