/**
 * ===================================================================
 * Panel Tab Logic
 * ===================================================================
 * Handles switching between tabs in the side panel.
 *
 * It also includes a check for SimBrief return parameters to
 * automatically open the correct tab.
 */
document.addEventListener('DOMContentLoaded', () => {
    const tabButtons = document.querySelectorAll('.panel-tab-btn');
    const tabContents = document.querySelectorAll('.tab-content');

    // Function to switch to a specific tab
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

    // Add click event listener to each tab button
    tabButtons.forEach(button => {
        button.addEventListener('click', () => {
            const tabId = button.dataset.tab;
            activateTab(tabId);
        });
    });

    // --- SimBrief Integration Logic ---
    // Check URL parameters on page load to see if we are
    // returning from SimBrief.
    const urlParams = new URLSearchParams(window.location.search);
    if (urlParams.get('view') === 'view-flight-plan' || urlParams.has('ofp_id')) {
        // If so, automatically switch to the flight plan tab
        activateTab('tab-flightplan');
    } else {
        // Otherwise, just show the default active tab (Welcome)
        activateTab('tab-welcome');
    }
});