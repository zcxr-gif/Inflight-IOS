
export function initPlaneSizeSlider(map, filters) {
    // 1. Updated default to 35% (0.35) for normalized icons
    if (filters.planeIconSize === undefined) {
        filters.planeIconSize = 0.35; 
    }

    // 2. Updated Slider UI (Range: 0.1 to 1.0)
    const sliderHTML = `
        <div class="filter-section-divider">
            <span class="filter-section-title">Visual Scaling</span>
        </div>
        <ul class="filter-toggle-list" style="padding-top: 8px;">
            <li class="filter-toggle-item" style="flex-direction: column; align-items: flex-start; gap: 8px; padding: 12px 16px;">
                <div style="display: flex; justify-content: space-between; width: 100%; align-items: center;">
                    <span class="filter-toggle-label"><i class="fa-solid fa-plane-up"></i> Aircraft Scale</span>
                    <span id="plane-size-display" style="font-family: 'JetBrains Mono', monospace; color: var(--color-brand); font-weight: 800; font-size: 0.9rem;">${Math.round(filters.planeIconSize * 100)}%</span>
                </div>
                <input type="range" id="plane-size-slider" min="0.1" max="1.0" step="0.05" value="${filters.planeIconSize}" style="width: 100%; accent-color: var(--color-brand); cursor: pointer;">
            </li>
        </ul>
    `;

    const updateSize = (val) => {
        val = parseFloat(val);
        filters.planeIconSize = val;
        
        const display = document.getElementById('plane-size-display');
        if (display) display.textContent = `${Math.round(val * 100)}%`;

        localStorage.setItem('mapFilters', JSON.stringify(filters));

        if (map && map.getLayer('sector-ops-live-flights-layer')) {
            map.setLayoutProperty('sector-ops-live-flights-layer', 'icon-size', val);
        }
        // Keep the natural (non-SDF) twin layer the same size as the SDF layer.
        if (map && map.getLayer('sector-ops-live-flights-natural-layer')) {
            map.setLayoutProperty('sector-ops-live-flights-natural-layer', 'icon-size', val);
        }
    };

    const injectSlider = () => {
        const settingsContainer = document.getElementById('filter-window-content');
        if (settingsContainer && !document.getElementById('plane-size-slider')) {
            settingsContainer.insertAdjacentHTML('beforeend', sliderHTML);
            
            const slider = document.getElementById('plane-size-slider');
            slider.addEventListener('input', (e) => updateSize(e.target.value));
        }
    };

    const applySize = () => {
        if (map.getLayer('sector-ops-live-flights-layer')) {
            map.setLayoutProperty('sector-ops-live-flights-layer', 'icon-size', filters.planeIconSize);
        }
        if (map.getLayer('sector-ops-live-flights-natural-layer')) {
            map.setLayoutProperty('sector-ops-live-flights-natural-layer', 'icon-size', filters.planeIconSize);
        }
    };

    if (map) {
        map.on('style.load', applySize);
        if (map.isStyleLoaded()) applySize();
    }

    const observer = new MutationObserver(() => {
        if (document.getElementById('filter-window-content')) {
            injectSlider();
        }
    });

    observer.observe(document.body, { childList: true, subtree: true });
}