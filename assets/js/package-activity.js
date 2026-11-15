for (const container of document.querySelectorAll('[data-activity-chart]')) {
    if (typeof window.Chart !== 'function') continue;
    try {
        const { days } = JSON.parse(container.dataset.activity);
        container.hidden = false;
        new window.Chart(container.querySelector('canvas'), {
            type: 'bar',
            data: {
                labels: days.map(day => `${day.date}${day.partial ? ' (partial)' : ''}`),
                datasets: [{
                    label: 'Unique machines downloading recipes',
                    data: days.map(day => day.available ? day.count : null),
                    backgroundColor: days.map(day => day.partial ? '#a9c6e1' : '#4282ba'),
                    borderRadius: 3,
                }],
            },
            options: {
                responsive: true, maintainAspectRatio: false, animation: false,
                plugins: { legend: { display: false } },
                scales: {
                    y: { beginAtZero: true, ticks: { precision: 0 }, grid: { color: '#edf1f6' } },
                    x: { grid: { display: false }, ticks: { maxTicksLimit: 6, maxRotation: 0 } },
                },
            },
        });
    } catch {
        // The server-rendered table remains usable if chart initialization fails.
        container.hidden = true;
    }
}
