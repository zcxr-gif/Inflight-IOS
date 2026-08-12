/**
 * FlightDispatchService
 * A globally accessible bridge to extract filed flight plans from Supabase.
 * Matches live telemetry by Infinite Flight Username (if_username), Departure ICAO, and Arrival ICAO.
 */

export const FlightDispatchService = {
    _supabase: null,
    _cache: new Map(),
    _cacheExpiryMs: 60000, // 1 minute cache TTL

    init(supabaseClient) {
        this._supabase = supabaseClient;
    },

    /**
     * Fetches the filed plan based on the username and routing.
     * @param {string} username - The Infinite Flight username extracted from the live tracker API
     * @param {string} depIcao - Departure Airport ICAO (e.g., "EGSS")
     * @param {string} arrIcao - Arrival Airport ICAO (e.g., "EPSY")
     */
    async getFiledPlan(username, depIcao, arrIcao) {
        if (!this._supabase || !username || !depIcao || !arrIcao) {
            return null;
        }

        const cleanUsername = String(username).trim();
        const cleanDep = String(depIcao).trim().toUpperCase();
        const cleanArr = String(arrIcao).trim().toUpperCase();
        
        const cacheKey = `${cleanUsername.toLowerCase()}-${cleanDep}-${cleanArr}`;

        if (this._cache.has(cacheKey)) {
            const cachedData = this._cache.get(cacheKey);
            if (Date.now() - cachedData.timestamp < this._cacheExpiryMs) {
                return cachedData.plan;
            }
        }

        try {
            // We now query by if_username, making the system immune to UUID mismatches.
            // Using .ilike ensures case-insensitive matching (e.g. "Pilot123" matches "pilot123")
            const { data, error } = await this._supabase
                .from('user_flights')
                .select(`
                    user_id,
                    if_username,
                    callsign,
                    aircraft_type,
                    dep_icao,
                    arr_icao,
                    dep_gate,
                    arr_gate,
                    dep_time,
                    duration_minutes,
                    passengers,
                    fuel_used
                `)
                .ilike('if_username', cleanUsername)
                .ilike('dep_icao', cleanDep)
                .ilike('arr_icao', cleanArr)
                .order('dep_time', { ascending: false })
                .limit(1)
                .maybeSingle();

            if (error) throw error;

            this._cache.set(cacheKey, { plan: data, timestamp: Date.now() });
            return data;

        } catch (err) {
            console.error(`FlightDispatchService: Error retrieving plan for ${cacheKey} -`, err.message);
            return null;
        }
    }
};