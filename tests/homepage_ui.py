"""Carousel checks shared by the optional browser suite and a rendered fixture."""
from playwright.sync_api import expect


def check_homepage(browser, base):
    page = browser.new_page(viewport={"width": 1440, "height": 1000})
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.clock.install(time=0)
    page.clock.pause_at(1)

    def start():
        page.goto(base + "/")
        page.mouse.move(0, 0)
        page.locator('.showcase-slide img').first.evaluate("image => image.decode()")
        expect(page.locator('.home-showcase')).to_have_class('home-showcase is-enhanced')
        # Let IntersectionObserver deliver its initial visibility notification.
        page.clock.run_for(100)

    def current(index):
        expect(page.locator('.showcase-slide[aria-hidden="false"]')).to_have_count(1)
        expect(page.locator('.showcase-slide').nth(index)).to_have_attribute('aria-hidden', 'false')
        assert page.locator('.showcase-slide').evaluate_all(
            "slides => slides.filter(slide => !slide.inert).length === 1")

    start()
    dots = page.locator('.showcase-dot')
    rotation = page.locator('[data-rotation-control]')
    assert dots.count() == 5
    assert page.locator('.home-showcase').evaluate(
        "element => element.querySelector('button, a, input').matches('[data-rotation-control]')")
    current(0)
    page.clock.run_for(14000)
    current(0)
    page.clock.run_for(1100)
    current(1)
    for index in range(2, 5):
        page.clock.run_for(12000)
        current(index)
    expect(rotation).to_have_text('Play')
    page.clock.run_for(60000)
    current(4)
    # Automatic changes do not move focus.
    assert page.evaluate('document.activeElement === document.body')
    rotation.click()
    current(0)
    expect(rotation).to_have_text('Pause')
    page.mouse.move(0, 0)
    page.clock.run_for(15100)
    current(1)

    start()
    page.locator('.showcase-copy').first.hover()
    page.clock.run_for(20000)
    current(0)
    page.mouse.move(0, 0)
    page.clock.run_for(14000)
    current(0)
    page.clock.run_for(1100)
    current(1)
    # Pause must survive the pointerdown -> focusin -> click event ordering.
    rotation.click()
    expect(rotation).to_have_text('Play')
    page.mouse.move(0, 0)
    page.clock.run_for(30000)
    current(1)

    dots.nth(2).click()
    current(2)
    dots.nth(2).press('End')
    current(4)
    dots.nth(4).press('ArrowRight')
    current(0)
    dots.nth(0).press('ArrowLeft')
    current(4)
    dots.nth(4).press('Home')
    current(0)
    expect(dots.nth(0)).to_be_focused()
    expect(page.locator('[data-slide-status]')).to_have_attribute('aria-live', 'polite')
    page.mouse.move(0, 0)
    page.clock.run_for(60000)
    current(0)

    for selector in ('.registry-search input', '.clipboard'):
        start()
        page.locator(selector).focus()
        expect(rotation).to_have_text('Play')
        page.clock.run_for(20000)
        current(0)
    start()
    page.locator('.clipboard').click()
    expect(page.locator('.clipboard-tooltip')).to_have_text('Copied')
    expect(rotation).to_have_text('Play')

    # Synthetic visibility changes exercise suspension without background-tab
    # throttling making the test dependent on the browser runner's window state.
    start()
    page.evaluate("""() => {
        window.testHidden = true;
        Object.defineProperty(document, 'hidden', {configurable: true, get: () => window.testHidden});
        document.dispatchEvent(new Event('visibilitychange'));
    }""")
    page.clock.run_for(60000)
    current(0)
    page.evaluate("window.testHidden = false; document.dispatchEvent(new Event('visibilitychange'))")
    page.clock.run_for(14000)
    current(0)
    page.clock.run_for(1100)
    current(1)
    page.locator('.registry-search input').focus()
    page.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
    page.clock.run_for(20000)
    current(1)

    # Use enough document height to move the carousel fully out of view.
    start()
    page.evaluate("document.body.style.paddingBottom = '2000px'; window.scrollTo(0, 1500)")
    page.wait_for_timeout(100)  # IntersectionObserver runs on real rendering frames.
    page.clock.run_for(100)
    page.clock.run_for(60000)
    current(0)
    page.evaluate('window.scrollTo(0, 0)')
    page.wait_for_timeout(100)
    page.clock.run_for(100)
    page.clock.run_for(15100)
    current(1)

    start()
    page.locator('.home-showcase').dispatch_event('pointerdown', {'pointerType': 'touch'})
    expect(rotation).to_have_text('Play')
    page.clock.run_for(60000)
    current(0)

    # A slow next image must not hide the current slide or override a manual
    # choice when the pending decode eventually completes.
    import re
    pending = []
    image_pattern = re.compile(r'.*(?:community-home\.png|/homepage/images/community)(?:\?.*)?$')
    page.route(image_pattern, lambda route: pending.append(route))
    page.goto(base + '/', wait_until='domcontentloaded')
    page.mouse.move(0, 0)
    page.locator('.showcase-slide img').first.evaluate('image => image.decode()')
    page.wait_for_timeout(100)
    page.clock.run_for(16000)
    current(0)
    assert pending, 'The next screenshot should be preloaded'
    dots.nth(2).click()
    current(2)
    for route in pending:
        route.fallback()
    page.unroute(image_pattern)
    page.locator('.showcase-slide img').nth(1).evaluate('image => image.decode()')
    page.clock.run_for(60000)
    current(2)

    # The largest slide reserves space at every viewport and at enlarged text.
    page.emulate_media(reduced_motion='reduce')
    for width in (320, 390, 768, 1440):
        page.set_viewport_size({"width": width, "height": 1000})
        start()
        expect(rotation).to_have_text('Play')
        positions = []
        for index in range(5):
            dots.nth(index).click()
            positions.append(page.locator('.registry-search').evaluate('element => element.offsetTop'))
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), width
            assert page.locator('.showcase-slide').nth(index).evaluate(
                'element => element.scrollWidth <= element.clientWidth'), (width, index)
        assert len(set(positions)) == 1, (width, positions)
    page.evaluate("document.documentElement.style.fontSize = '32px'")
    for index in range(5):
        dots.nth(index).click()
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
    page.clock.run_for(60000)
    current(4)
    rotation.click()
    page.mouse.move(0, 0)
    page.clock.run_for(15100)
    current(1)  # Reduced motion permits explicit Play, without crossfades.
    assert page.locator('.home-showcase').evaluate('element => element.getAnimations({subtree: true}).length === 0')
    assert not errors, errors
    page.close()

    plain = browser.new_context(java_script_enabled=False, viewport={"width": 390, "height": 1000})
    page = plain.new_page()
    page.goto(base + '/')
    expect(page.locator('.showcase-slide')).to_have_count(5)
    for slide in page.locator('.showcase-slide').all():
        expect(slide).to_be_visible()
        expect(slide.locator('.showcase-link')).to_be_visible()
    expect(page.locator('[data-rotation-control]')).to_be_hidden()
    expect(page.locator('.showcase-controls')).to_be_hidden()
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
    plain.close()
    print('PASS carousel timing, stops, resume, keyboard, reduced motion, stable layout, clipboard and no-JS fallback')
