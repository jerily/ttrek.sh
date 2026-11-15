// Pointer events cover touch and pen without taking over vertical scroll or zoom.
export function onSwipe(element, navigate) {
    let start = null;
    let suppressClick = false;
    element.addEventListener('pointerdown', event => {
        suppressClick = false;
        if (!event.isPrimary) { start = null; return; }
        if (event.pointerType !== 'touch' && event.pointerType !== 'pen') return;
        start = { id: event.pointerId, x: event.clientX, y: event.clientY };
    });
    element.addEventListener('pointercancel', () => { start = null; });
    element.addEventListener('pointerup', event => {
        if (!start || event.pointerId !== start.id) return;
        const dx = event.clientX - start.x;
        const dy = event.clientY - start.y;
        start = null;
        if (Math.abs(dx) < 40 || Math.abs(dx) <= Math.abs(dy) * 1.5) return;
        suppressClick = true;
        navigate(dx < 0 ? 1 : -1);
    });
    // A swipe starting on a link must not follow that link on release.
    element.addEventListener('click', event => {
        if (!suppressClick || event.detail === 0) return;
        suppressClick = false;
        event.preventDefault();
        event.stopPropagation();
    }, true);
}
