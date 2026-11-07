"""Optional Playwright checks, run by local-stack.tcl with TTREK_BROWSER_TESTS=1."""
import time
from playwright.sync_api import sync_playwright, expect


def check(base):
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        try:
            page = browser.new_page(viewport={"width": 1440, "height": 1000})
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.goto(base + "/")
            query = page.get_by_role("combobox")
            query.fill("web")
            options = page.get_by_role("option")
            expect(options.first).to_be_visible()
            assert 0 < options.count() <= 8
            first_name = options.first.locator(".suggestion-name").inner_text()
            query.press("ArrowDown")
            expect(options.first).to_have_attribute("aria-selected", "true")
            query.press("Enter")
            expect(page).to_have_url(base + "/package/" + first_name)

            page.goto(base + "/")
            query.fill("json")
            expect(options.first).to_be_visible()
            query.press("Escape")
            expect(query).to_have_attribute("aria-expanded", "false")
            query.fill("web")
            expect(options.first).to_be_visible()
            query.press("Tab")
            expect(query).to_have_attribute("aria-expanded", "false")
            query.focus()
            expect(options.first).to_be_visible()
            options.first.click()
            expect(page).to_have_url(base + "/package/" + first_name)

            page.goto(base + "/")
            query.fill("web")
            expect(options.first).to_be_visible()
            query.press("Enter")
            expect(page).to_have_url(base + "/search?q=web")
            expect(page.locator(".package-card").first).to_be_visible()

            # Observe actual requests while typing faster than the throttle interval.
            page.goto(base + "/")
            requests = []
            page.on("request", lambda request: requests.append((time.monotonic(), request.url))
                    if "/registry/autocomplete?" in request.url else None)
            query.press_sequentially("compression", delay=35)
            expect(options.first).to_be_visible()
            page.wait_for_timeout(300)
            assert requests[-1][1].endswith("q=compression"), requests
            assert 2 <= len(requests) <= 5, requests
            assert all(b[0] - a[0] >= .16 for a, b in zip(requests, requests[1:])), requests
            query.fill("")
            page.wait_for_timeout(250)
            expect(query).to_have_attribute("aria-expanded", "false")

            # Resolve the old fetch after the new one, ignoring abort in the mock.
            # This exercises the generation guard independently of AbortController.
            page.evaluate("""() => {
                window.fetch = (url) => new Promise(resolve => {
                    const q = new URL(url, location.href).searchParams.get('q');
                    setTimeout(() => resolve({ok: true, json: async () => [
                        {name: q, description: '<img src=x onerror=alert(1)>'}
                    ]}), q === 'old' ? 600 : 20);
                });
            }""")
            query.fill("old")
            page.wait_for_timeout(220)
            query.fill("new")
            expect(options.first.locator(".suggestion-name")).to_have_text("new")
            page.wait_for_timeout(650)
            expect(options.first.locator(".suggestion-name")).to_have_text("new")
            assert options.locator("img").count() == 0
            query.fill("pending")
            query.press("Escape")
            page.wait_for_timeout(300)
            expect(query).to_have_attribute("aria-expanded", "false")
            page.evaluate("() => { window.fetch = async () => {throw new Error('offline');}; }")
            query.fill("offline")
            expect(page.locator("[data-search-status]")).to_contain_text("Suggestions unavailable")
            query.press("Enter")
            expect(page).to_have_url(base + "/search?q=offline")

            for width in (390, 768, 1440):
                page.set_viewport_size({"width": width, "height": 900})
                for path in ("/", "/search?q=web", "/packages"):
                    page.goto(base + path)
                    assert not page.evaluate("document.documentElement.scrollWidth > innerWidth"), (width, path)
            assert not errors, errors

            plain = browser.new_context(java_script_enabled=False)
            no_js = plain.new_page()
            no_js.goto(base + "/")
            no_js.get_by_label("Search packages", exact=True).fill("web")
            no_js.get_by_role("button", name="Search").click()
            expect(no_js.locator(".package-card").first).to_be_visible()
            no_js.goto(base + "/search?q=zzzzzzzzzzzzzzzz")
            expect(no_js.get_by_text("No packages found.")).to_be_visible()
            plain.close()
            print("PASS browser autocomplete, throttle, stale responses, escaping, keyboard, mobile and no-JS search")
        finally:
            browser.close()


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        sys.exit("usage: search_ui.py BASE_URL")
    check(sys.argv[1])
