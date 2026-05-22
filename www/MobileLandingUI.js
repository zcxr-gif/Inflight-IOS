/**
 * MobileLandingUI.js - Optimized for State Persistence & Responsive Inputs
 */

export const MobileLandingUI = {
    _isOpen: false,

    init(parentUI) {
        this.parent = parentUI; 
        this.injectMobileStyles();
        this.renderMobileContainer();
        this.attachMobileListeners();
    },

    renderMobileContainer() {
        const existing = document.getElementById('mobile-tactical-nexus');
        if (existing) existing.remove();

        const html = `
            <div id="mobile-tactical-nexus" class="mobile-only-ui">
                <div id="mobile-overlay" class="mobile-sheet-overlay"></div>

                <div class="mobile-bottom-sheet">
                    <div class="sheet-handle"></div>
                    
                    <div class="mobile-title">
                        <i class="fa-solid fa-sliders"></i>
                        <span>Tactical Filters</span>
                    </div>

                    <div class="sheet-content custom-scroll">
                        <div class="mobile-section-header">Active Rules</div>
                        <div id="mobile-active-rules-container"></div>
                        
                        <div class="mobile-section-header">Add Filters</div>
                        <div class="mobile-filter-grid">
                            ${this.renderFilterGrid()}
                        </div>
                    </div>

                    <div class="sheet-footer">
                        <button id="mobile-reset-btn" class="m-btn m-secondary">Reset</button>
                        <button id="mobile-apply-btn" class="m-btn m-primary">Apply Changes</button>
                    </div>
                </div>
            </div>
        `;

        document.getElementById('sector-ops-map-fullscreen')?.insertAdjacentHTML('beforeend', html);
    },

    renderFilterGrid() {
        let html = '';
        Object.values(this.parent.filterGroups).forEach(group => {
            group.filters.forEach(f => {
                html += `
                    <button class="m-grid-item" data-id="${f.id}">
                        <i class="fa-solid ${f.icon}"></i>
                        <span>${f.label}</span>
                    </button>
                `;
            });
        });
        return html;
    },

    attachMobileListeners() {
        const sheet = document.querySelector('.mobile-bottom-sheet');
        const overlay = document.getElementById('mobile-overlay');
        const container = document.getElementById('mobile-active-rules-container');

        window.addEventListener('openMobileUI', () => {
            this._isOpen = true;
            sheet.classList.add('open');
            overlay.classList.add('visible');
            this.syncActiveRules();
        });

        const closeUI = () => {
            this._isOpen = false;
            sheet.classList.remove('open');
            overlay.classList.remove('visible');
        };

        overlay.addEventListener('click', closeUI);

        // Grid selection for adding new filters
        document.querySelectorAll('.m-grid-item').forEach(btn => {
            btn.addEventListener('click', () => {
                this.parent.activateFilter(btn.dataset.id);
                this.syncActiveRules();
            });
        });

        // CRITICAL: Listen for typing/inputs within the mobile container
        container?.addEventListener('input', (e) => {
            const target = e.target;
            const id = target.dataset.id;
            
            if (target.classList.contains('data-input-min')) {
                this.parent.updateFilterValue(id, target.value, 'min');
            } else if (target.classList.contains('data-input-max')) {
                this.parent.updateFilterValue(id, target.value, 'max');
            } else if (target.classList.contains('data-input')) {
                this.parent.updateFilterValue(id, target.value);
            }
        });

        document.getElementById('mobile-apply-btn').addEventListener('click', () => {
            this.parent.dispatchFilterUpdate();
            closeUI();
        });

        document.getElementById('mobile-reset-btn').addEventListener('click', () => {
            this.parent._activeFilters = {};
            this.syncActiveRules();
            this.parent.dispatchFilterUpdate();
        });
    },

    syncActiveRules() {
        const container = document.getElementById('mobile-active-rules-container');
        if (!container) return;

        const activeEntries = Object.entries(this.parent._activeFilters);
        if (activeEntries.length === 0) {
            container.innerHTML = `<p class="m-empty-text">No active filters. Tap below to add.</p>`;
            return;
        }

        container.innerHTML = activeEntries.map(([id, value]) => {
            const def = this.parent.allFilters.find(f => f.id === id);
            return `
                <div class="m-active-card">
                    <div class="m-card-info">
                        <i class="fa-solid ${def.icon}"></i>
                        <span>${def.label}</span>
                    </div>
                    <div class="m-card-input-wrapper">
                        ${this.parent.renderInputControl(id, value)}
                    </div>
                    <button class="m-card-remove" onclick="MobileLandingUI.removeRule('${id}')">
                        <i class="fa-solid fa-trash-can"></i>
                    </button>
                </div>
            `;
        }).join('');
    },

    removeRule(id) {
        this.parent.removeFilter(id);
        this.syncActiveRules();
    },

    injectMobileStyles() {
    const css = `
        @media (min-width: 769px) { .mobile-only-ui { display: none; } }
        @media (max-width: 768px) {

        /* Shrink Grid Icons */
            .m-grid-item {
                padding: 12px 4px !important; /* Tighter padding */
                gap: 5px !important;
            }

            .m-grid-item i {
                font-size: 0.85rem !important; /* Smaller icon size */
            }

            .m-grid-item span {
                font-size: 0.65rem !important; /* Smaller label text */
            }

            /* Ensure Active Card icons are also slightly smaller */
            .m-card-info i {
                font-size: 0.9rem !important;
            }
            /* 1. FORCE BOX-SIZING GLOBALLY FOR MOBILE UI */
            .mobile-only-ui, .mobile-only-ui * {
                box-sizing: border-box !important;
            }

            .mobile-sheet-overlay {
                position: fixed; inset: 0; background: rgba(0,0,0,0.7); 
                backdrop-filter: blur(4px); opacity: 0; visibility: hidden; transition: 0.3s; z-index: 5000;
            }
            .mobile-sheet-overlay.visible { opacity: 1; visibility: visible; }

            .mobile-bottom-sheet {
                position: fixed; bottom: 0; left: 0; right: 0;
                background: #0a0a0b; border-top: 1px solid rgba(255,255,255,0.1);
                border-radius: 24px 24px 0 0; z-index: 5001;
                height: 85vh; transform: translateY(100%); transition: transform 0.4s cubic-bezier(0.16, 1, 0.3, 1);
                display: flex; flex-direction: column; color: #fff;
                box-shadow: 0 -10px 40px rgba(0,0,0,0.5);
            }
            .mobile-bottom-sheet.open { transform: translateY(0); }

            .sheet-handle { width: 40px; height: 5px; background: rgba(255,255,255,0.2); border-radius: 10px; margin: 12px auto; }
            
            .mobile-title { 
                padding: 5px 20px 15px; text-align: center; font-weight: 800; color: #38bdf8; 
                display: flex; align-items: center; justify-content: center; gap: 10px; font-size: 1.1rem;
                text-transform: uppercase; letter-spacing: 1px;
            }

            .sheet-content { flex: 1; overflow-y: auto; padding: 0 20px 100px; }
            .mobile-section-header { font-size: 0.7rem; font-weight: 900; color: #52525b; text-transform: uppercase; letter-spacing: 1.5px; margin: 25px 0 12px; }
            
            .mobile-filter-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
            .m-grid-item { 
                background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.08); 
                border-radius: 16px; padding: 15px 5px; color: #a1a1aa; display: flex; flex-direction: column; align-items: center; gap: 8px; font-size: 0.7rem;
                transition: all 0.2s;
            }
            .m-grid-item:active { background: rgba(56, 189, 248, 0.2); color: #38bdf8; border-color: #38bdf8; }

            .m-active-card { 
                background: #141416; border: 1px solid rgba(255,255,255,0.08); border-radius: 18px; 
                padding: 20px; margin-bottom: 12px; position: relative;
                width: 100%; /* Ensure card doesn't exceed parent */
                overflow: hidden; /* Safety clip */
            }
            .m-card-info { display: flex; align-items: center; gap: 12px; font-weight: 700; margin-bottom: 15px; font-size: 0.95rem; }
            .m-card-info i { color: #38bdf8; font-size: 1rem; }
            .m-card-remove { position: absolute; top: 18px; right: 18px; background: none; border: none; color: #ef4444; font-size: 1.1rem; opacity: 0.8; }

            /* 2. REFINED INPUT WRAPPER */
            .m-card-input-wrapper {
                width: 100%;
                display: block;
            }

            .m-card-input-wrapper .row-input, 
            .m-card-input-wrapper .row-input-select,
            .m-card-input-wrapper .range-pill-container {
                width: 100% !important;
                max-width: 100% !important; /* Prevents escaping the card */
                background: #1c1c1f !important;
                font-size: 16px !important;
                margin: 0 !important; /* Remove any external margins */
            }

            .m-card-input-wrapper .range-input {
                font-size: 16px !important;
                width: 100% !important;
            }

            .sheet-footer { 
                padding: 20px; background: #0a0a0b; border-top: 1px solid rgba(255,255,255,0.05); 
                display: flex; gap: 12px; position: sticky; bottom: 0;
            }
            .m-btn { flex: 1; padding: 16px; border-radius: 14px; font-weight: 700; border: none; font-size: 1rem; }
            .m-primary { background: #38bdf8; color: #000; }
            .m-secondary { background: rgba(255,255,255,0.08); color: #fff; }
            
            .m-empty-text { color: #3f3f46; font-size: 0.9rem; text-align: center; margin: 30px 0; font-style: italic; }
        }
    `;
    const style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);
}
};

window.MobileLandingUI = MobileLandingUI;