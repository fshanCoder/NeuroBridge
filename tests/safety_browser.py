"""Exercise the release web build with two isolated Chrome sessions."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import httpx
from playwright.sync_api import expect, sync_playwright


@contextmanager
def demo():
    with tempfile.TemporaryDirectory() as folder, socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        url = f"http://127.0.0.1:{port}"
        server = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "backend.main:app",
                "--port",
                str(port),
                "--log-level",
                "warning",
            ],
            cwd=Path(__file__).resolve().parents[1],
            env={**os.environ, "NB_DATABASE": folder + "/demo.db"},
        )
        try:
            for _ in range(100):
                try:
                    if httpx.get(url, timeout=1).is_success:
                        break
                except httpx.ConnectError:
                    pass
                time.sleep(0.1)
            yield url
        finally:
            server.terminate()
            server.wait()


def run():
    with demo() as url, sync_playwright() as pw:
        profile = httpx.post(
            url + "/v1/patients", json={"name": "Alex", "carer": "Sam", "consent": True}
        ).json()
        headers = {"Authorization": "Bearer " + profile["token"]}
        httpx.post(
            url + "/v1/safety/preferences",
            headers=headers,
            json={"seconds": 5, "scan_ms": 2200, "dwell_ms": 550},
        ).raise_for_status()
        chrome = pw.chromium.launch(channel="chrome")

        def open_role(role):
            ctx = chrome.new_context(viewport={"width": 1080, "height": 900})
            page = ctx.new_page()
            session = {"role": role, "name": "Alex", "carer": "Sam", **profile}
            if role == "carer":
                session["token"] = profile["pairing_key"]
            page.add_init_script(
                "localStorage.setItem('flutter.session',"
                + json.dumps(json.dumps(json.dumps(session)))
                + ");"
            )
            page.goto(url)
            page.locator("flt-semantics-placeholder").evaluate("(e)=>e.click()")
            return page

        p = open_role("patient")
        c = open_role("carer")

        def btn(page, label):
            return page.get_by_role("button", name=label, exact=True)

        def state():
            return httpx.get(url + "/v1/board", headers=headers).json()

        def trigger():
            btn(p, "Simulate safety signal").click()
            btn(p, "Possible fall").click()
            p.mouse.move(2, 2)
            expect(btn(p, "I am okay")).to_be_visible()

        def wait(check):
            end = time.monotonic() + 12
            while time.monotonic() < end:
                if check():
                    return
                time.sleep(0.15)
            raise AssertionError("Timed out waiting for persisted state")

        trigger()
        btn(p, "I am okay").click()
        wait(lambda: state()["safety"]["state"] == "cancelled")
        assert not state()["pending"]
        trigger()
        btn(p, "Send help now").click()
        btn(c, "Acknowledge request").click(timeout=12000)
        wait(lambda: any(e["who"] == "Sam" for e in state()["events"]))
        trigger()
        p.close()
        btn(c, "Acknowledge request").click(timeout=15000)
        wait(
            lambda: state()["safety"]["state"] == "timed out" and not state()["pending"]
        )
        assert len([e for e in state()["events"] if e["kind"] == "alert"]) == 2
        p = open_role("patient")
        btn(p, "Assisted communication").click()
        btn(p, "Start scanning").click()
        p.keyboard.press("Space")
        wait(lambda: any(e["kind"] == "phrase" for e in state()["events"]))
        btn(p, "Pause scanning").click()
        p.get_by_role("checkbox", name="Dwell selection").click()
        btn(p, "I am in pain").hover()
        wait(lambda: any(e["text"] == "I am in pain" for e in state()["events"]))
        time.sleep(1.3)
        assert sum(e["text"] == "I am in pain" for e in state()["events"]) == 1
        btn(p, "Return to board").click()
        p.context.set_offline(True)
        expect(
            p.get_by_text("Offline · Showing saved activity", exact=False).first
        ).to_be_visible(timeout=12000)
        trigger()
        btn(p, "I am okay").click()
        trigger()
        expect(p.get_by_text("Waiting to send:", exact=False).first).to_be_visible(
            timeout=12000
        )
        p.context.set_offline(False)
        btn(c, "Acknowledge request").click(timeout=15000)
        wait(lambda: len([e for e in state()["events"] if e["kind"] == "alert"]) == 3)
        # A simulated inference must enter the same confirmation flow without a second trigger.
        httpx.post(
            url + "/v1/care/settings",
            headers=headers,
            json={"consent": True, "history": "", "contact": ""},
        ).raise_for_status()
        httpx.post(url + "/v1/care/calibrate", headers=headers).raise_for_status()
        btn(p, "Care workspace").click()
        p.get_by_role("checkbox", name="Recognition", exact=True).click()
        p.get_by_role("checkbox", name="Fall detection", exact=True).click()
        btn(p, "Run sample").click()
        btn(p, "I am okay").click(timeout=10000)
        wait(lambda: state()["safety"]["state"] == "cancelled")
        chrome.close()
        print(
            "Passed cancellation, immediate help, unattended timeout, acknowledgement, switch scanning and dwell selection."
        )


if __name__ == "__main__":
    run()
