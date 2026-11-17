// A small, deliberately partial shell highlighter for fenced Markdown examples.
// Work only with text nodes so examples remain inert and copy exactly as written.
function highlightShell(code) {
    const source = code.textContent;
    const tokens = /(?<comment>(?<!\S)#[^\n]*)|(?<string>'[^']*'|"(?:\\[\s\S]|[^"\\])*")|(?<variable>\$(?:\{[^}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@#?*!$-]))|(?<keyword>(?<![\w./-])(?:if|then|else|elif|fi|for|while|do|done|case|esac|in|function|export)(?![\w./-]))|(?<option>(?<!\S)--?[A-Za-z][A-Za-z0-9-]*)/g;
    const fragment = document.createDocumentFragment();
    let offset = 0;
    for (const match of source.matchAll(tokens)) {
        fragment.append(document.createTextNode(source.slice(offset, match.index)));
        const span = document.createElement('span');
        const kind = Object.keys(match.groups).find(key => match.groups[key] !== undefined);
        span.className = `shell-${kind}`;
        span.textContent = match[0];
        fragment.append(span);
        offset = match.index + match[0].length;
    }
    fragment.append(document.createTextNode(source.slice(offset)));
    code.replaceChildren(fragment);
}

const labels = { sh: 'Shell', bash: 'Bash', tcl: 'Tcl', json: 'JSON', ini: 'INI', markdown: 'Markdown', gitignore: 'Git ignore', text: 'Text' };
for (const code of document.querySelectorAll(':is(.docs-content, .blog-content) article pre > code')) {
    const languageClass = [...code.classList].find(name => name.startsWith('language-'));
    if (!languageClass) continue;
    const language = languageClass.slice('language-'.length).toLowerCase();
    code.parentElement.dataset.language = labels[language] || language;
    if (language === 'sh' || language === 'bash') highlightShell(code);
}
