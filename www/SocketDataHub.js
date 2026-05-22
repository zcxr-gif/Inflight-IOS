/**
 * SocketDataHub.js
 * * High-performance, decoupled Event Bus for WebSocket data.
 * Allows independent modules to tap into live data streams without
 * modifying the core socket connection file.
 * * ============================================================================
 * 📖 DATA DICTIONARY & SCHEMA DEFINITIONS
 * ============================================================================
 * The following types define the exact structure of the payloads 
 * broadcasted by the hub. 
 * * ----------------------------------------------------------------------------
 * CHANNEL: 'all_flights_update'
 * ----------------------------------------------------------------------------
 * @typedef {Object} AllFlightsUpdatePayload
 * @property {number|string} timestamp - Server-side timestamp of the data packet.
 * @property {string} server - The active server name (e.g., "Expert Server").
 * @property {FlightData[]} flights - Array of all currently active flights.
 * * @typedef {Object} FlightData
 * @property {string} flightId - Unique identifier for the flight session.
 * @property {string} callsign - Aircraft callsign (e.g., "DAL123").
 * @property {string} username - The pilot's community username.
 * @property {string} userId - Unique identifier for the pilot.
 * @property {FlightPosition} position - Real-time spatial telemetry.
 * @property {AircraftDetails} aircraft - Metadata regarding the airframe.
 * @property {string} [departureIcao] - Origin airport 4-letter code.
 * @property {string} [arrivalIcao] - Destination airport 4-letter code.
 * @property {number} pilotState - Numerical pilot state (0=Active, 1=Away, 2=Parked).
 * * @typedef {Object} FlightPosition
 * @property {number} lat - Latitude of the aircraft.
 * @property {number} lon - Longitude of the aircraft.
 * @property {number} alt_ft - Altitude in feet.
 * @property {number} gs_kt - Ground speed in knots.
 * @property {number} vs_fpm - Vertical speed in feet per minute.
 * @property {number} heading_deg - True heading in degrees.
 * @property {number|string} [lastReport] - Timestamp of the last position report.
 * * @typedef {Object} AircraftDetails
 * @property {string} aircraftName - Full name of the aircraft (e.g., "Airbus A320-200").
 * @property {string} liveryName - Airline or livery name (e.g., "Delta Air Lines").
 * @property {string} [registration] - Aircraft tail number or registration.
 * * ----------------------------------------------------------------------------
 * CHANNEL: 'secondary_data_update'
 * ----------------------------------------------------------------------------
 * @typedef {Object} SecondaryDataUpdatePayload
 * @property {string} server - The active server name.
 * @property {AtcFacility[]} atc - Array of active Air Traffic Control facilities.
 * * @typedef {Object} AtcFacility
 * @property {number} type - ATC Type ID (0: GND, 1: TWR, 4/5: APP, 6: Center).
 * @property {string} username - Controller's username.
 * @property {string} airportName - Associated Airport ICAO or FIR identifier.
 * @property {number|string} startTime - When the controller opened the frequency.
 * ============================================================================
 */

class SocketDistributor {
    constructor() {
        this.channels = new Map();
        this.metrics = { published: 0, errors: 0 };
    }

    /**
     * Subscribe to a data channel.
     * @param {string} channel - The socket event name (e.g., 'all_flights_update').
     * @param {Function} listener - Callback receiving the data.
     * @returns {Function} - Unsubscribe method for memory safety.
     */
    subscribe(channel, listener) {
        if (!this.channels.has(channel)) {
            this.channels.set(channel, new Set());
        }
        
        this.channels.get(channel).add(listener);
        
        // Return a self-contained teardown function for premium memory management
        return () => {
            const subs = this.channels.get(channel);
            if (subs) subs.delete(listener);
        };
    }

    /**
     * Broadcasts data to all subscribers on a channel.
     * @param {string} channel - The socket event name.
     * @param {any} payload - The raw data from the WebSocket.
     */
    publish(channel, payload) {
        if (!this.channels.has(channel)) return;

        this.metrics.published++;
        
        for (const listener of this.channels.get(channel)) {
            try {
                // Execute listeners asynchronously to prevent blocking the main socket/map thread
                Promise.resolve().then(() => listener(payload));
            } catch (err) {
                this.metrics.errors++;
                console.error(`[SocketDataHub] Uncaught exception in channel '${channel}':`, err);
            }
        }
    }
    
    getHealth() {
        return {
            activeChannels: this.channels.size,
            totalSubscribers: Array.from(this.channels.values()).reduce((acc, set) => acc + set.size, 0),
            metrics: this.metrics
        };
    }
}

// Export a frozen singleton to prevent external mutation of the instance
export const socketDataHub = new SocketDistributor();
Object.freeze(socketDataHub);