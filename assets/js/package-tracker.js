for (const bar of document.querySelectorAll('[data-tracker-bar]')) {
    const panels = [...bar.querySelectorAll('[data-tracker-panel]')];
    const selectors = [...bar.querySelectorAll('[data-tracker-select]')];
    const rotation = bar.querySelector('[data-tracker-rotation]');
    const status = bar.querySelector('[data-tracker-status]');
    const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
    const active = panels.map((panel, i) => panel.dataset.hasRows === 'yes' ? i : -1).filter(i => i >= 0);
    let current = 0;
    let playing = !motion.matches && active.length > 1;
    let timer;
    let hovered = false;
    let visible = false;
    let pointerAction = null;
    function schedule() {
        clearTimeout(timer);
        rotation.textContent = playing ? 'Pause' : 'Play';
        if (!playing || hovered || !visible || document.hidden || motion.matches || active.length < 2) return;
        timer = setTimeout(() => {
            const next = active[(active.indexOf(current) + 1) % active.length];
            show(next);
            schedule();
        }, 8000);
    }
    function stop() { playing = false; schedule(); }
    function show(index, announce = false) {
        current = index;
        panels.forEach((panel, i) => {
            panel.classList.toggle('is-active', i === current);
            panel.setAttribute('aria-hidden', String(i !== current));
            panel.inert = i !== current;
        });
        selectors.forEach((button, i) => button.setAttribute('aria-pressed', String(i === current)));
        if (announce) status.textContent = selectors[current].textContent;
    }
    selectors.forEach((button, index) => {
        button.addEventListener('click', () => { stop(); show(index, true); });
        button.addEventListener('keydown', event => {
            const destinations = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: panels.length - 1 };
            if (!(event.key in destinations)) return;
            event.preventDefault();
            const next = (destinations[event.key] + panels.length) % panels.length;
            stop(); show(next, true); selectors[next].focus();
        });
    });
    rotation.addEventListener('pointerdown', () => { pointerAction = playing ? 'pause' : 'play'; });
    rotation.addEventListener('pointercancel', () => { pointerAction = null; });
    rotation.addEventListener('keydown', () => { pointerAction = null; });
    rotation.addEventListener('click', event => {
        const action = event.detail > 0 && pointerAction ? pointerAction : (playing ? 'pause' : 'play');
        pointerAction = null;
        playing = action === 'play';
        schedule();
    });
    bar.addEventListener('focusin', stop);
    bar.addEventListener('click', event => { if (!rotation.contains(event.target)) stop(); });
    bar.addEventListener('pointerdown', event => { if (!rotation.contains(event.target)) stop(); });
    bar.addEventListener('pointerenter', event => { if (event.pointerType === 'mouse') { hovered = true; schedule(); } });
    bar.addEventListener('pointerleave', event => { if (event.pointerType === 'mouse') { hovered = false; schedule(); } });
    motion.addEventListener('change', () => {
        rotation.hidden = active.length < 2 || motion.matches;
        if (motion.matches) stop();
    });
    document.addEventListener('visibilitychange', schedule);
    window.addEventListener('pagehide', () => clearTimeout(timer));
    window.addEventListener('pageshow', schedule);
    if ('IntersectionObserver' in window) {
        new IntersectionObserver(entries => {
            visible = entries.some(entry => entry.isIntersecting);
            schedule();
        }).observe(bar);
    } else { playing = false; }
    bar.classList.add('is-enhanced');
    bar.querySelector('.tracker-bar-controls').inert = false;
    rotation.hidden = active.length < 2 || motion.matches;
    show(0);
    schedule();
}
