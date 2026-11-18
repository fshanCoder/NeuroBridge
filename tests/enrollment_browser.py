import os
from safety_browser import demo
from playwright.sync_api import sync_playwright, expect


def run():
    os.environ["NB_DEMO_OTP"] = "1"
    with demo() as url, sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome")
        page = browser.new_page(viewport={"width": 1280, "height": 1300})
        page.goto(url)
        page.locator("flt-semantics-placeholder").evaluate("(e)=>e.click()")

        def btn(text):
            return page.get_by_role("button", name=text, exact=True)

        def fill(name, value):
            page.get_by_role("textbox", name=name, exact=True).click()
            page.wait_for_timeout(300)
            page.keyboard.type(value, delay=15)
            page.keyboard.press("Tab")

        btn("Set up").click()
        fill("Patient name", "Alex")
        fill("Caregiver name", "Sam")
        btn("Phone and guardian details").click()
        fill("Phone with country code", "+15555550123")
        with page.expect_response(lambda r: r.url.endswith("/auth/otp")) as challenge:
            btn("Request verification code").click()
        fill("Verification code", challenge.value.json()["demo_code"])
        with page.expect_response(lambda r: r.url.endswith("/verify-otp")) as verified:
            btn("Verify phone").click()
        assert verified.value.ok
        page.get_by_role("switch", name="Guardian is enrolling a minor").click()
        fill("Consenting guardian name", "Morgan")
        page.get_by_role("checkbox", name="I agree to share", exact=False).click()
        with page.expect_response(lambda r: r.url.endswith("/v1/patients")) as created:
            btn("Create profile").click()
        assert created.value.status == 201
        expect(btn("Assisted communication")).to_be_visible()
        browser.close()
        print("Passed demo phone verification and guardian enrollment in Chrome.")


if __name__ == "__main__":
    run()
