// Native form submission keeps validation, redirects and server errors intact.
const pending = new Map();
for (const form of document.querySelectorAll('.account-panel form[method="post"]')) {
    const action = new URL(form.action).pathname.match(/\/(login|register)\/?$/)?.[1];
    if (!action) continue;
    form.addEventListener('submit', event => {
        if (pending.has(form)) {
            event.preventDefault();
            return;
        }
        if (event.defaultPrevented) return;
        const button = form.querySelector('button[type="submit"]');
        if (!button || button.disabled) return;
        pending.set(form, { button, label: button.textContent });
        button.disabled = true;
        button.setAttribute('aria-busy', 'true');
        button.textContent = action === 'login' ? 'Signing in…' : 'Creating account…';
    });
}

// Browsers can restore the submitted page, including disabled controls, from cache.
window.addEventListener('pageshow', () => {
    for (const { button, label } of pending.values()) {
        button.disabled = false;
        button.removeAttribute('aria-busy');
        button.textContent = label;
    }
    pending.clear();
});
