export class ProTrackManager {
    constructor() {
        this.pinnedPaths = new Set();
        this.MAX_TRACKS = 4;
        this.containerId = 'pro-multi-track-manager';
        
        this.init();
    }

    init() {
        if (!document.getElementById('pro-track-manager-styles')) {
            this.injectPremiumStyles();
        }
        this.renderContainer();
    }

    injectPremiumStyles() {
        const style = document.createElement('style');
        style.id = 'pro-track-manager-styles';
        style.textContent = `
            #pro-multi-track-manager {
                position: fixed;
                top: 80px;
                left: 20px;
                width: 280px;
                z-index: 4000;
                display: flex;
                flex-direction: column;
                gap: 10px;
                pointer-events: none;
            }
            .pro-track-card {
                pointer-events: auto;
                background: rgba(10, 12, 26, 0.65);
                backdrop-filter: blur(16px) saturate(180%);
                -webkit-backdrop-filter: blur(16px);
                border: 1px solid rgba(56, 189, 248, 0.2);
                border-left: 3px solid #38bdf8;
                border-radius: 10px;
                padding: 10px 14px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                box-shadow: 0 8px 32px rgba(0,0,0,0.5);
                transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
                animation: slideInLeft 0.3s ease-out forwards;
            }
            .pro-track-card:hover {
                background: rgba(15, 23, 42, 0.9);
                border-color: rgba(56, 189, 248, 0.6);
                transform: translateX(4px);
            }
            .pro-track-info { display: flex; flex-direction: column; gap: 2px; }
            .pro-track-callsign { font-family: 'JetBrains Mono', monospace; color: #fff; font-weight: 800; font-size: 1rem; }
            .pro-track-route { font-size: 0.7rem; color: #94a3b8; font-weight: 600; display: flex; align-items: center; gap: 6px; }
            .pro-track-close { 
                background: rgba(239, 68, 68, 0.1); 
                border: 1px solid rgba(239, 68, 68, 0.2); 
                color: #ef4444; 
                width: 26px; height: 26px; 
                border-radius: 50%; 
                cursor: pointer; 
                display: grid; place-items: center; 
                transition: 0.2s; 
            }
            .pro-track-close:hover { background: #ef4444; color: #fff; }
            
            @keyframes slideInLeft {
                from { opacity: 0; transform: translateX(-20px); }
                to { opacity: 1; transform: translateX(0); }
            }
        `;
        document.head.appendChild(style);
    }

    renderContainer() {
        let manager = document.getElementById(this.containerId);
        if (!manager) {
            manager = document.createElement('div');
            manager.id = this.containerId;
            document.body.appendChild(manager);
        }
    }

    isPinned(flightId) {
        return this.pinnedPaths.has(flightId);
    }

    toggleTrack(flightId, mapInstance, mapFeatures, FlownPath3DClass, drawTrailCallback, showNotificationCallback) {
        if (!flightId) return;

        if (this.pinnedPaths.has(flightId)) {
            // Remove Track
            this.pinnedPaths.delete(flightId);
            
            // Surgical cleanup of Mapbox layers for this specific flight
            if (FlownPath3DClass && mapInstance) {
                FlownPath3DClass.removePath(mapInstance, flightId); 
            }
            if (mapInstance && mapInstance.getLayer(`flown-path-${flightId}`)) {
                mapInstance.removeLayer(`flown-path-${flightId}`);
                mapInstance.removeSource(`flown-path-${flightId}`);
            }
        } else {
            // Add Track
            if (this.pinnedPaths.size >= this.MAX_TRACKS) {
                if (showNotificationCallback) showNotificationCallback("Pro Multi-Track is limited to 4 simultaneous targets.", "warning");
                return;
            }
            this.pinnedPaths.add(flightId);
            if (showNotificationCallback) showNotificationCallback("Target acquired. Live track pinned.", "success");
            
            // Fetch trail if not already cached
            if (drawTrailCallback && mapFeatures && mapFeatures[flightId]) {
                drawTrailCallback(mapFeatures[flightId].properties.userId, flightId);
            }
        }
        
        this.renderUI(mapFeatures);
    }

    renderUI(mapFeatures) {
        const manager = document.getElementById(this.containerId);
        if (!manager) return;

        manager.innerHTML = ''; // Flush current UI

        this.pinnedPaths.forEach(fid => {
            const feature = mapFeatures ? mapFeatures[fid] : null;
            if (!feature) return;
            
            const props = feature.properties;
            const dep = props.departureIcao || '---';
            const arr = props.arrivalIcao || '---';

            const card = document.createElement('div');
            card.className = 'pro-track-card';
            card.innerHTML = `
                <div class="pro-track-info">
                    <div class="pro-track-callsign">
                        <i class="fa-solid fa-location-crosshairs" style="color:#38bdf8; font-size: 0.75rem; margin-right: 6px;"></i>${props.callsign || 'UNKNOWN'}
                    </div>
                    <div class="pro-track-route">${dep} <i class="fa-solid fa-arrow-right-long" style="opacity: 0.4;"></i> ${arr}</div>
                </div>
                <button class="pro-track-close" data-flight-id="${fid}" title="Remove Track">
                    <i class="fa-solid fa-xmark"></i>
                </button>
            `;
            manager.appendChild(card);
        });

        // Attach event listeners dynamically to avoid inline onclick handlers referencing window scopes
        const closeButtons = manager.querySelectorAll('.pro-track-close');
        closeButtons.forEach(btn => {
            btn.addEventListener('click', (e) => {
                const idToRemove = e.currentTarget.getAttribute('data-flight-id');
                // We dispatch a custom event so the main flight.js can catch it and provide the map dependencies
                window.dispatchEvent(new CustomEvent('removeProTrack', { detail: { flightId: idToRemove } }));
            });
        });
    }
}

export const trackManager = new ProTrackManager();