import ClipboardJS from '../../public/js/clipboard.min.js';

if (document.querySelector('.clipboard')) {
    const clipboard = new ClipboardJS('.clipboard');
    const timers = new WeakMap();
    clipboard.on('success', (event) => {
        const button = event.trigger;
        const tooltip = button.querySelector('.clipboard-tooltip');
        clearTimeout(timers.get(button));
        tooltip.textContent = 'Copied';
        event.clearSelection();
        timers.set(button, setTimeout(() => {
            tooltip.textContent = '';
            timers.delete(button);
        }, 2000));
    });
}
