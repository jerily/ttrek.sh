() => {
    const styles = (selector, properties) => {
        const style = getComputedStyle(document.querySelector(selector));
        return Object.fromEntries(properties.map(property => [property, style[property]]));
    };
    const box = selector => document.querySelector(selector).getBoundingClientRect().toJSON();
    return {
        shared: {
            body: styles('body', ['fontFamily', 'fontSize', 'lineHeight', 'backgroundColor']),
            menu: styles('.home-menu', ['display', 'padding', 'fontFamily']),
            brand: styles('.pure-menu-heading', ['fontSize', 'fontWeight', 'color']),
            header: styles('.site-header', ['position', 'height', 'backgroundColor']),
            footer: styles('.footer', ['position', 'padding', 'fontSize', 'color', 'backgroundColor']),
        },
        header: box('.site-header'),
        main: box('main'),
        footer: box('.footer'),
        overflow: document.documentElement.scrollWidth > innerWidth,
    };
}
