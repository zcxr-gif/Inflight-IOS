/**
 * ===================================================================
 * Simbrief Integration Module (Local Storage Version)
 * ===================================================================
 * This module encapsulates all logic for initiating a SimBrief flight
 * plan, fetching the data, rendering a preview, and saving the
 * plan to the user's local storage.
 *
 * It is designed for a standalone flight tracker community and
 * contains no logic for a VA backend.
 *
 * It now includes a configurable limit for saved flights and
 * public methods to get or erase all saved data.
 *
 * @author /*_serverNoob
 * @version 2.2.0 (Integrated WeatherService)
 *
 * @usage
 * In your main script, after dependencies are loaded:
 *
 * SimbriefIntegration.init({
 * // URL to your Netlify function (or other proxy) for SimBrief
 * netlifySimbriefUrl: '/.netlify/functions/simbrief',
 *
 * // Your global notification function
 * showNotification: showNotification,
 *
 * // Your dispatch pass renderer
 * // This function must render a button with id="save-from-simbrief-btn"
 * populateDispatchPass: populateDispatchPass,
 *
 * // A callback to run after a flight is saved or all are erased
 * onFlightSaved: refreshSavedFlightList,
 *
 * // (Optional) Max number of flights to save. Defaults to 2.
 * maxFlights: 2
 * });
 *
 * // --- OTHER PUBLIC METHODS ---
 *
 * // Get an array of all saved flights
 * const flights = SimbriefIntegration.getAllSavedFlights();
 *
 * // Erase all flights from storage
 * // (e.g., connect this to a "Clear All" button)
 * SimbriefIntegration.eraseAllSavedFlights();
 *
 * ===================================================================
 */

const SimbriefIntegration = {
    // --- Internal State ---
    ofpData: null, // Stores the full OFP JSON
    ofpId: null,   // Stores the SimBrief OFP ID (e.g., "1234567")
    config: {},    // To store helpers and callbacks
    storageKey: 'communityTrackerFlights', // localStorage key

    /**
     * Initializes the module, stores dependencies, and attaches listeners.
     * @param {object} options - Configuration object with helpers and callbacks.
     */
    init: function(options) {

        this.config = {
            netlifySimbriefUrl: options.netlifySimbriefUrl || '/.netlify/functions/simbrief',
            showNotification: options.showNotification || console.log,
            populateDispatchPass: options.populateDispatchPass,
            onFlightSaved: options.onFlightSaved || (() => {}),
            maxFlights: options.maxFlights || 2 // <-- NEW: Max saved flights
        };

        if (!this.config.populateDispatchPass) {
            console.error("SimbriefIntegration: 'populateDispatchPass' function is missing.");
            return;
        }

        this._attachEventListeners();
        this.checkForSimbriefReturn(); // Check for a return on initialization
    },

    // ===================================================================
    // "PART 2: PUBLIC STORAGE API"
    // ===================================================================

    /**
     * Retrieves all saved flight plans from local storage.
     * @returns {Array} An array of saved flight plan objects.
     */
    getAllSavedFlights: function() {
        try {
            const existingData = localStorage.getItem(this.storageKey);
            return existingData ? JSON.parse(existingData) : [];
        } catch (error) {
            console.error("Error parsing saved flights:", error);
            // Don't show a UI notification, just log and return empty.
            return [];
        }
    },

    /**
     * Erases all saved flight plans from local storage.
     */
    eraseAllSavedFlights: function() {
        try {
            localStorage.removeItem(this.storageKey);
            this.config.showNotification('All saved flight plans have been erased.', 'success');
            
            // Run the callback to (e.g.) refresh the UI
            if (typeof this.config.onFlightSaved === 'function') {
                this.config.onFlightSaved();
            }
        } catch (error) {
            this.config.showNotification(`Error erasing flights: ${error.message}`, 'error');
            console.error("Error erasing local storage:", error);
        }
    },

    // ===================================================================
    // "PART 3: RETURN & FETCH (Internal)"
    // ===================================================================

    /**
     * Checks URL for SimBrief return parameters and fetches the OFP.
     * This is public but typically runs automatically on init.
     */
    checkForSimbriefReturn: async function() {
        const urlParams = new URLSearchParams(window.location.search);
        const ofpId = urlParams.get('ofp_id');

        if (ofpId) {
            this.config.showNotification('Fetching flight plan from SimBrief...', 'info');
            try {
                const response = await fetch(`${this.config.netlifySimbriefUrl}?fetch_ofp=true&ofp_id=${ofpId}`);
                if (!response.ok) {
                    throw new Error('Could not retrieve flight plan from SimBrief.');
                }
                const data = await response.json();
                
                if (!data.OFP) {
                    // Handle cases where SimBrief API returns success but no OFP
                    // (e.g., if the netlify function had an error)
                    console.error("Simbrief fetch error:", data);
                    throw new Error(data.error || 'Failed to parse OFP data.');
                }

                this.ofpData = data.OFP;
                this.ofpId = ofpId;

                this._renderPreview();

                window.history.replaceState({}, document.title, window.location.pathname + '?view=view-flight-plan');

            } catch (error) {
                this.config.showNotification(error.message, 'error');
                this.ofpData = null;
                this.ofpId = null;
            }
        }
    },

    // ===================================================================
    // "PART 4: EVENT LISTENERS & HANDLERS (Private)"
    // ===================================================================

    /**
     * Attaches all necessary event listeners.
     */
    _attachEventListeners: function() {
        document.getElementById('generate-with-simbrief-btn')
            ?.addEventListener('click', this._handleGenerate.bind(this));

        document.body.addEventListener('click', (e) => {
            if (e.target.id === 'save-from-simbrief-btn') {
                e.preventDefault();
                this._handleSaveFlight(e.target);
            } else if (e.target.id === 'dispatch-close-btn') {
                e.preventDefault();
                this._handleClosePreview();
            }
        });
    },

    /**
     * "PART 4.1: INITIATION"
     */
    _handleGenerate: function(e) {
        e.preventDefault();
        this.config.showNotification('Opening SimBrief planner...', 'info');

        const flightNumber = document.getElementById('fp-flightNumber').value.toUpperCase();
        const departure = document.getElementById('fp-departure').value.toUpperCase();
        const arrival = document.getElementById('fp-arrival').value.toUpperCase();
        const aircraft = document.getElementById('fp-aircraft').value;

        const sbForm = document.getElementById('sbapiform');
        sbForm.querySelector('input[name="orig"]').value = departure;
        sbForm.querySelector('input[name="dest"]').value = arrival;
        sbForm.querySelector('input[name="type"]').value = aircraft;
        sbForm.querySelector('input[name="fltnum"]').value = flightNumber;

        const redirectUrl = window.location.origin + window.location.pathname + '?view=view-flight-plan';
        
        if (typeof simbriefsubmit === 'function') {
            simbriefsubmit(redirectUrl);
        } else {
            this.config.showNotification('Simbrief API script not found.', 'error');
        }
    },

    /**
     * "PART 4.2: PREVIEW"
     */
    _renderPreview: function() {
        if (!this.ofpData) return;

        try {
            const previewPlan = this._mapToPreviewPlan(this.ofpData);
            
            const dispatchDisplay = document.getElementById('dispatch-pass-display');
            const manualDispatchContainer = document.getElementById('manual-dispatch-container');

            if (!dispatchDisplay || !manualDispatchContainer) {
                throw new Error('Dispatch or form container not found in the DOM.');
            }

            this.config.populateDispatchPass(dispatchDisplay, previewPlan, { isPreview: true });

            manualDispatchContainer.style.display = 'none';
            dispatchDisplay.style.display = 'block';

            this.config.showNotification('Dispatch Pass generated successfully!', 'success');

        } catch (error) {
            this.config.showNotification(`Error rendering preview: ${error.message}`, 'error');
            console.error("Preview Render Error:", error); // Log the full error
            this._handleClosePreview();
        }
    },

    _handleClosePreview: function() {
        document.getElementById('dispatch-pass-display').style.display = 'none';
        document.getElementById('manual-dispatch-container').style.display = 'block';
        this.ofpData = null;
        this.ofpId = null;
    },

    /**
     * "PART 4.3: SAVING TO LOCAL STORAGE"
     */
    _handleSaveFlight: async function(targetButton) {
        if (!this.ofpData || !this.ofpId) {
            this.config.showNotification('Error: SimBrief data not found. Please regenerate.', 'error');
            return;
        }

        targetButton.disabled = true;
        targetButton.textContent = 'Saving...';

        try {
            const flightToSave = this._mapToStoragePayload(this.ofpData, this.ofpId);

            // Get existing flights using our new public method
            let savedFlights = this.getAllSavedFlights();

            // Check if this flight (by ofpId) already exists
            const existingIndex = savedFlights.findIndex(flight => flight.id === flightToSave.id);

            if (existingIndex > -1) {
                // --- UPDATE EXISTING FLIGHT ---
                savedFlights[existingIndex] = flightToSave;
                this.config.showNotification('Flight plan updated in local storage!', 'success');
            } else {
                // --- ADD NEW FLIGHT (AND CHECK LIMIT) ---
                if (savedFlights.length >= this.config.maxFlights) {
                    // Remove the oldest flight (at the beginning of the array)
                    savedFlights.shift(); 
                    this.config.showNotification(`Flight plan saved! Oldest plan (max ${this.config.maxFlights}) removed.`, 'success');
                } else {
                    this.config.showNotification('Flight plan saved locally!', 'success');
                }
                
                // Add new flight (to the end of the array)
                savedFlights.push(flightToSave);
            }

            // Save the updated array back to local storage
            localStorage.setItem(this.storageKey, JSON.stringify(savedFlights));

            this._handleClosePreview();
            this.config.onFlightSaved(); // Calls the callback

        } catch (err) {
            this.config.showNotification(`Error: ${err.message}`, 'error');
            console.error("Save Error:", err); // Log the full error
            targetButton.disabled = false;
            targetButton.textContent = 'Save This Flight Plan';
        }
    },

    // ===================================================================
    // "PART 5: MAPPERS (Private)"
    // ===================================================================

    /**
     * Maps the full SimBrief OFP to the "previewPlan" object
     */
    _mapToPreviewPlan: function(ofp) {
        const cargoWeight = ofp.weights.payload - (ofp.general.passengers * ofp.weights.pax_weight);
        
        // Ensure weather service is available before trying to parse
        const parse = window.WeatherService ? window.WeatherService.parseMetar : (metar) => ({ raw: metar || '---' }); // <-- CHANGED
        
        return {
            _id: 'simbrief-preview',
            flightNumber: ofp.general.flight_number,
            departure: ofp.origin.icao_code,
            arrival: ofp.destination.icao_code,
            etd: new Date(ofp.times.sched_out * 1000),
            eta: new Date(ofp.times.sched_in * 1000),
            eet: ofp.times.est_time_enroute / 3600,
            aircraft: ofp.aircraft.icaocode,
            route: ofp.general.route,
            alternate: ofp.alternate.icao_code,
            zfw: ofp.weights.est_zfw,
            tow: ofp.weights.est_tow,
            pob: ofp.general.passengers,
            cargo: cargoWeight,
            fuelTaxi: ofp.fuel.taxi,
            fuelTrip: ofp.fuel.enroute_burn,
            fuelTotal: ofp.fuel.plan_ramp,
            squawkCode: ofp.atc.squawk,
            tlr: ofp.tlr,
            departureWeather: parse(ofp.weather.orig_metar), // <-- CHANGED
            arrivalWeather: parse(ofp.weather.dest_metar), // <-- CHANGED & FIXED BUG
            cruiseAltitude: ofp.general.initial_altitude,
            cruiseSpeed: ofp.general.cruise_mach,
            mapData: {
                origin: ofp.origin,
                destination: ofp.destination,
                navlog: ofp.navlog?.fix || []
            }
        };
    },

    /**
     * Maps the full SimBrief OFP to the JSON payload for localStorage.
     */
    _mapToStoragePayload: function(ofp, ofpId) {
        const cargoWeight = ofp.weights.payload - (ofp.general.passengers * ofp.weights.pax_weight);

        // Ensure weather service is available before trying to parse
        const parse = window.WeatherService ? window.WeatherService.parseMetar : (metar) => ({ raw: metar || '---' }); // <-- CHANGED

        return {
            id: ofpId, // Use SimBrief's OFP ID
            flightNumber: ofp.general.flight_number,
            aircraft: ofp.aircraft.icaocode,
            departure: ofp.origin.icao_code,
            arrival: ofp.destination.icao_code,
            alternate: ofp.alternate.icao_code,
            route: ofp.general.route,
            etd: new Date(ofp.times.sched_out * 1000).toISOString(),
            eet: ofp.times.est_time_enroute / 3600,
            pob: parseInt(ofp.general.passengers, 10),
            squawkCode: ofp.atc.squawk,
            zfw: ofp.weights.est_zfw,
            tow: ofp.weights.est_tow,
            cargo: cargoWeight,
            fuelTaxi: ofp.fuel.taxi,
            fuelTrip: ofp.fuel.enroute_burn,
            fuelTotal: ofp.fuel.plan_ramp,
            departureWeather: parse(ofp.weather.orig_metar), // <-- CHANGED
            arrivalWeather: parse(ofp.weather.dest_metar), // <-- CHANGED
            tlr: ofp.tlr,
            cruiseAltitude: ofp.general.initial_altitude,
            cruiseSpeed: ofp.general.cruise_mach,
            mapData: {
                origin: ofp.origin,
                destination: ofp.destination,
                navlog: ofp.navlog?.fix || []
            }
        };
    }
};