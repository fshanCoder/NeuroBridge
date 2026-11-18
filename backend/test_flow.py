import os
import tempfile
import unittest
from uuid import uuid4
from datetime import datetime, timezone
from unittest.mock import patch
from fastapi.testclient import TestClient
from backend.main import app


class CareFlowTest(unittest.TestCase):
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, NB_DATABASE=folder + '/test.sqlite3'):
            client = TestClient(app)
            profile = dict(name='小林', carer='阿青', consent=True)
            auth = lambda key: {'Authorization': 'Bearer ' + key}
            patient = client.post('/v1/patients', json=profile).json()
            patient_auth = auth(patient['token'])
            carer_auth = auth(patient['pairing_key'])
            other = client.post('/v1/patients', json=profile).json()
            for kind, text in [('phrase', '我想喝水'), ('alert', '我需要帮助')]:
                event = dict(id=str(uuid4()), kind=kind, text=text,
                             occurred_at=datetime.now(timezone.utc).isoformat())
                for _ in range(2):
                    self.assertEqual(client.post('/v1/events', headers=patient_auth, json=event).status_code, 200)
            board = client.get('/v1/board', headers=carer_auth).json()
            self.assertEqual(len(board['events']), 2)
            alert = board['pending'][0]['id']
            path = f'/v1/alerts/{alert}/acknowledge'
            self.assertEqual(client.post(path, headers=patient_auth).status_code, 403)
            self.assertEqual(client.post(path, headers=auth(other['pairing_key'])).status_code, 404)
            first = client.post(path, headers=carer_auth).json()
            self.assertEqual(first, client.post(path, headers=carer_auth).json())
            board = client.get('/v1/board', headers=patient_auth).json()
            self.assertEqual(board['pending'], [])
            self.assertEqual(board['events'][0]['who'], '阿青')
