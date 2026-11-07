const clipboard = new ClipboardJS('.clipboard');
const clipboardTimers = new WeakMap();

clipboard.on('success', (event) => {
    const button = event.trigger;
    const tooltip = button.querySelector('.clipboard-tooltip');

    clearTimeout(clipboardTimers.get(button));
    tooltip.textContent = 'Copied';
    event.clearSelection();

    clipboardTimers.set(button, setTimeout(() => {
        tooltip.textContent = '';
        clipboardTimers.delete(button);
    }, 2000));
});
