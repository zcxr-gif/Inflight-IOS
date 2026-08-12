/**
 * ===================================================================
 * Panel Tab & Modal Logic
 * ===================================================================
 * Handles switching between tabs in the modal window.
 * Handles opening/closing the modal interactions.
 */
document.addEventListener('DOMContentLoaded', () => {
    // --- 1. Tab Switching Logic ---
    const tabButtons = document.querySelectorAll('.panel-tab-btn');
    const tabContents = document.querySelectorAll('.tab-content');

    function activateTab(tabId) {
        tabButtons.forEach(btn => {
            if (btn.dataset.tab === tabId) {
                btn.classList.add('active');
            } else {
                btn.classList.remove('active');
            }
        });

        tabContents.forEach(content => {
            if (content.id === tabId) {
                content.classList.add('active');
            } else {
                content.classList.remove('active');
            }
        });
    }

    tabButtons.forEach(button => {
        button.addEventListener('click', () => {
            const tabId = button.dataset.tab;
            activateTab(tabId);
        });
    });

    // --- 2. Modal Open/Close Logic ---
    const modalBackdrop = document.querySelector('.modal-backdrop');
    const closeBtn = document.getElementById('close-modal-btn');

    // Close Modal when clicking the 'X' button
    if (closeBtn && modalBackdrop) {
        closeBtn.addEventListener('click', () => {
            modalBackdrop.style.display = 'none';
        });
    }

    // Close Modal when clicking the dark background (backdrop)
    if (modalBackdrop) {
        modalBackdrop.addEventListener('click', (e) => {
            // Ensure we only close if the user clicked the backdrop itself,
            // not the content inside the modal.
            if (e.target === modalBackdrop) {
                modalBackdrop.style.display = 'none';
            }
        });
    }

    // --- 3. SimBrief Integration Auto-Open ---
    // Check URL parameters to see if we are returning from SimBrief.
    const urlParams = new URLSearchParams(window.location.search);
    
    if (urlParams.get('view') === 'view-flight-plan' || urlParams.has('ofp_id')) {
        // Switch to flight plan tab
        activateTab('tab-flightplan');
        
        // Ensure the modal is visible if we just returned from SimBrief
        if (modalBackdrop) {
            modalBackdrop.style.display = 'block'; 
        }
    } else {
        // Default to Welcome tab
        activateTab('tab-welcome');
    }
});