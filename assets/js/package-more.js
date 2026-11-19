for (const nav of document.querySelectorAll('.package-more')) {
    const link = nav.querySelector('[rel="next"]');
    const status = nav.querySelector('[role="status"]');
    const grid = nav.closest('main').querySelector('.package-grid');
    let loading = false;
    let observer;

    async function loadMore(manual) {
        if (loading || link.hidden) return;
        loading = true;
        link.setAttribute('aria-busy', 'true');
        status.textContent = 'Loading packages…';
        try {
            const response = await fetch(link.href);
            if (response.status === 409) {
                observer?.disconnect();
                const restart = new URL(link.href);
                restart.searchParams.delete('after');
                const retry = document.createElement('a');
                retry.href = restart.href;
                retry.textContent = 'Restart search';
                status.replaceChildren('The results have changed. ', retry);
                link.hidden = true;
                if (manual) retry.focus();
                return;
            }
            if (!response.ok) throw new Error('Page unavailable');
            const page = new DOMParser().parseFromString(await response.text(), 'text/html');
            if (!page.querySelector('link[rel="canonical"]')) throw new Error('Unexpected page');
            const cards = page.querySelectorAll('.package-grid > .package-card');
            const next = page.querySelector('.package-more [rel="next"]');
            grid.append(...cards);
            if (manual && document.activeElement === link) cards[0]?.querySelector('h2 a')?.focus();
            if (next) {
                link.href = next.getAttribute('href');
                status.textContent = cards.length + ' more packages loaded.';
            } else {
                observer?.disconnect();
                link.hidden = true;
                status.textContent = 'All remaining packages loaded.';
            }
        } catch {
            observer?.disconnect();
            status.textContent = 'Couldn’t load packages. Select Load more to try again.';
        } finally {
            link.removeAttribute('aria-busy');
            loading = false;
        }
    }

    link.addEventListener('click', event => {
        if (event.button || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
        event.preventDefault();
        loadMore(true);
    });
    if ('IntersectionObserver' in window) {
        observer = new IntersectionObserver(entries => {
            if (entries.some(entry => entry.isIntersecting) && document.activeElement !== link) loadMore(false);
        }, { rootMargin: '0px 0px 120px' });
        observer.observe(link);
    }
}
