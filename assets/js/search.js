import { throttle } from 'throttle-debounce';

for (const form of document.querySelectorAll('[data-registry-search]')) {
    const input = form.querySelector('input[name="q"]');
    const popup = form.querySelector('.suggestions');
    const list = form.querySelector('[role="listbox"]');
    const status = form.querySelector('[data-search-status]');
    let controller;
    let generation = 0;
    let active = -1;
    let matches = [];
    let composing = false;

    input.setAttribute('role', 'combobox');
    input.setAttribute('aria-autocomplete', 'list');
    input.setAttribute('aria-controls', list.id);
    input.setAttribute('aria-expanded', 'false');

    function close() {
        popup.hidden = true;
        input.setAttribute('aria-expanded', 'false');
        input.removeAttribute('aria-activedescendant');
        active = -1;
    }

    function cancel() {
        generation += 1;
        controller?.abort();
        lookup.cancel({ upcomingOnly: true });
        input.removeAttribute('aria-busy');
        close();
        status.textContent = '';
    }

    function select(index) {
        active = index;
        for (const [position, option] of Array.from(list.children).entries()) {
            option.setAttribute('aria-selected', String(position === active));
        }
        const option = list.children[active];
        input.setAttribute('aria-activedescendant', option.id);
        option.scrollIntoView({ block: 'nearest' });
    }

    function openPackage(index) {
        window.location.assign(`/package/${encodeURIComponent(matches[index].name)}`);
    }

    const lookup = throttle(200, async (query, requestGeneration) => {
        controller = new AbortController();
        input.setAttribute('aria-busy', 'true');
        try {
            const response = await fetch(`/registry/autocomplete?q=${encodeURIComponent(query)}`, {
                signal: controller.signal,
                headers: { Accept: 'application/json' },
            });
            if (!response.ok) throw new Error('Autocomplete unavailable');
            const suggestions = await response.json();
            if (requestGeneration !== generation || document.activeElement !== input) return;
            matches = suggestions;
            list.replaceChildren();
            for (const [index, match] of matches.entries()) {
                const option = document.createElement('li');
                option.id = `${list.id}-${index}`;
                option.setAttribute('role', 'option');
                option.setAttribute('aria-selected', 'false');
                const name = document.createElement('span');
                name.className = 'suggestion-name';
                name.textContent = match.name;
                const description = document.createElement('span');
                description.className = 'suggestion-description';
                description.textContent = match.description || 'View package and available versions';
                option.append(name, description);
                option.addEventListener('pointerdown', (event) => event.preventDefault());
                option.addEventListener('click', () => openPackage(index));
                list.append(option);
            }
            popup.hidden = matches.length === 0;
            input.setAttribute('aria-expanded', String(matches.length > 0));
            status.textContent = matches.length
                ? `${matches.length} suggestions. Use the arrow keys to explore, or Enter to search all results.`
                : 'No suggestions. Press Enter to search all packages.';
        } catch (error) {
            if (requestGeneration !== generation || error.name === 'AbortError') return;
            close();
            status.textContent = 'Suggestions unavailable. Press Enter to search.';
        } finally {
            if (requestGeneration === generation) input.removeAttribute('aria-busy');
        }
    });

    function update() {
        cancel();
        const query = input.value.trim();
        if (composing || !query || query === '.' || query === '..' ||
                query.length > 255 || !/^[A-Za-z0-9._+ -]+$/.test(query)) return;
        lookup(query, generation);
    }

    input.addEventListener('input', update);
    input.addEventListener('focus', update);
    input.addEventListener('blur', cancel);
    input.addEventListener('compositionstart', () => { composing = true; cancel(); });
    input.addEventListener('compositionend', () => { composing = false; update(); });
    input.addEventListener('keydown', (event) => {
        if (event.isComposing) return;
        if (event.key === 'Escape') {
            event.preventDefault();
            cancel();
        } else if (!popup.hidden && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
            event.preventDefault();
            const next = active < 0 ? (event.key === 'ArrowDown' ? 0 : matches.length - 1)
                : (active + (event.key === 'ArrowDown' ? 1 : -1) + matches.length) % matches.length;
            select(next);
        } else if (event.key === 'Enter' && !popup.hidden && active >= 0) {
            event.preventDefault();
            openPackage(active);
        }
    });
    form.addEventListener('submit', cancel);
    window.addEventListener('pagehide', cancel);
}
