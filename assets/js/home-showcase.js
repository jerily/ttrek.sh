// Server-rendered sections work without JavaScript. Enhance only this component;
// search and clipboard keep their own event handlers and keyboard behavior.
for (const carousel of document.querySelectorAll('.home-showcase')) {
    const slides = [...carousel.querySelectorAll('.showcase-slide')];
    const dots = [...carousel.querySelectorAll('.showcase-dot')];
    if (!slides.length || slides.length !== dots.length) continue;
    const rotation = carousel.querySelector('[data-rotation-control]');
    const controls = carousel.querySelector('.showcase-controls');
    const label = carousel.querySelector('[data-current-label]');
    const status = carousel.querySelector('[data-slide-status]');
    const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
    let current = 0;
    let requested = slides.length > 1 && carousel.dataset.autoplay === 'true' && !motion.matches;
    let hovered = carousel.matches(':hover');
    let playHoverExemption = false;
    let visible = false;
    let ready = false;
    let timer = null;
    let pendingPointerAction = null;
    let generation = 0;
    let animations = [];

    function clearTimer() {
        window.clearTimeout(timer);
        timer = null;
    }
    function canRotate() {
        return carousel.isConnected && requested && ready && visible && !document.hidden &&
            (!hovered || playHoverExemption);
    }
    function updateControl() {
        rotation.textContent = requested ? 'Pause' : 'Play';
        rotation.setAttribute('aria-label', requested ? 'Pause automatic slide rotation' : 'Start automatic slide rotation');
        status.setAttribute('aria-live', requested ? 'off' : 'polite');
    }
    // Decode before advancing. Keep the current panel on screen while the next
    // image loads; failures still leave that panel's text and link usable.
    function prepare(index) {
        const image = slides[index].querySelector('img');
        if (!image) return Promise.resolve();
        image.loading = 'eager';
        if (typeof image.decode === 'function') return image.decode().catch(() => {});
        if (image.complete) return Promise.resolve();
        return new Promise(resolve => {
            image.addEventListener('load', resolve, { once: true });
            image.addEventListener('error', resolve, { once: true });
        });
    }
    function schedule() {
        clearTimer();
        const token = ++generation;
        updateControl();
        if (!canRotate()) return;
        if (current < slides.length - 1) prepare(current + 1);
        timer = window.setTimeout(async () => {
            timer = null;
            const next = current + 1;
            if (next >= slides.length) return;
            await prepare(next);
            if (token !== generation || !canRotate()) return;
            show(next, false);
            if (current === slides.length - 1) requested = false;
            schedule();
        }, current === 0 ? 15000 : 12000);
    }
    function stop() {
        requested = false;
        playHoverExemption = false;
        schedule();
    }
    function show(index, announce) {
        const next = (index + slides.length) % slides.length;
        const previous = slides[current];
        animations.forEach(animation => animation.cancel());
        animations = [];
        slides.forEach((slide, i) => {
            slide.setAttribute('aria-hidden', String(i !== next));
            slide.inert = i !== next;
        });
        dots.forEach((dot, i) => dot.setAttribute('aria-pressed', String(i === next)));
        if (next !== current && !motion.matches && typeof slides[next].animate === 'function') {
            animations = [
                previous.animate([{ opacity: 1, visibility: 'visible' }, { opacity: 0, visibility: 'visible' }], { duration: 250 }),
                slides[next].animate([{ opacity: 0 }, { opacity: 1 }], { duration: 250 }),
            ];
        }
        current = next;
        label.textContent = slides[next].dataset.label;
        if (announce) status.textContent = `${label.textContent}, slide ${next + 1} of ${slides.length}`;
        prepare(next);
    }
    function choose(index, focusControl = false) {
        stop();
        show(index, true);
        if (focusControl) dots[current].focus();
    }
    slides.forEach((slide, i) => {
        slide.setAttribute('role', 'group');
        slide.setAttribute('aria-roledescription', 'slide');
        slide.setAttribute('aria-label', `${i + 1} of ${slides.length}: ${slide.dataset.label}`);
    });
    dots.forEach((dot, index) => {
        dot.addEventListener('click', () => choose(index));
        dot.addEventListener('keydown', event => {
            const destinations = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: dots.length - 1 };
            if (!(event.key in destinations)) return;
            event.preventDefault();
            choose(destinations[event.key], true);
        });
    });
    // Pointer focus stops rotation before click fires. Remember the action the
    // visitor actually pressed so a Pause click cannot accidentally restart it.
    rotation.addEventListener('pointerdown', () => { pendingPointerAction = requested ? 'pause' : 'play'; });
    rotation.addEventListener('pointercancel', () => { pendingPointerAction = null; });
    rotation.addEventListener('keydown', () => { pendingPointerAction = null; });
    rotation.addEventListener('click', event => {
        const action = event.detail > 0 && pendingPointerAction ? pendingPointerAction : (requested ? 'pause' : 'play');
        pendingPointerAction = null;
        if (action === 'pause') { stop(); return; }
        if (current === slides.length - 1) show(0, false);
        status.textContent = '';
        requested = true;
        playHoverExemption = rotation.matches(':hover');
        schedule();
    });
    carousel.addEventListener('focusin', stop);
    carousel.addEventListener('pointerdown', event => {
        if (!rotation.contains(event.target)) stop();
    });
    carousel.addEventListener('pointerenter', event => {
        if (event.pointerType !== 'mouse') return;
        hovered = true;
        playHoverExemption = false;
        schedule();
    });
    carousel.addEventListener('pointermove', event => {
        if (event.pointerType === 'mouse' && playHoverExemption && !rotation.contains(event.target)) {
            playHoverExemption = false;
            schedule();
        }
    });
    carousel.addEventListener('pointerleave', event => {
        if (event.pointerType !== 'mouse') return;
        hovered = false;
        playHoverExemption = false;
        schedule();
    });
    // Keyboard and assistive-technology clicks also permanently stop playback.
    carousel.addEventListener('click', event => {
        if (!rotation.contains(event.target)) stop();
    });
    for (const area of document.querySelectorAll('.home-page .registry-search, .home-page .install-panel')) {
        area.addEventListener('focusin', stop);
        area.addEventListener('pointerdown', stop);
        area.addEventListener('click', stop);
    }
    document.addEventListener('visibilitychange', schedule);
    window.addEventListener('pagehide', () => { clearTimer(); ++generation; });
    window.addEventListener('pageshow', schedule);
    motion.addEventListener('change', () => {
        if (motion.matches) {
            stop();
            animations.forEach(animation => animation.cancel());
        }
    });
    if ('IntersectionObserver' in window) {
        const observer = new IntersectionObserver(entries => {
            visible = entries.some(entry => entry.isIntersecting && entry.intersectionRatio >= .4);
            schedule();
        }, { threshold: [0, .4] });
        observer.observe(carousel);
    } else {
        // Older browsers keep the manual controls without off-screen autoplay.
        requested = false;
    }
    carousel.setAttribute('aria-roledescription', 'carousel');
    carousel.classList.add('is-enhanced');
    controls.hidden = slides.length < 2;
    rotation.hidden = slides.length < 2;
    show(0, false);
    updateControl();
    prepare(0).then(() => { ready = true; schedule(); });
}
