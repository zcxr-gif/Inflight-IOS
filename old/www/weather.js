// weather.js

/**
 * Parses a raw METAR string into a more readable object.
 * @param {string} metarString - The raw METAR data.
 * @returns {object} An object containing parsed wind, temperature, and condition.
 */
const parseMetar = (metarString) => {
    if (!metarString || typeof metarString !== 'string') {
        return { wind: '---', temp: '---', condition: '---', raw: 'Not Available' };
    }
    const parts = metarString.split(' ');
    const wind = parts.find(p => p.endsWith('KT'));
    const tempMatch = metarString.match(/M?\d{2}\/M?\d{2}/);
    const temp = tempMatch ? `${tempMatch[0].split('/')[0].replace('M', '-')}°C` : '---';
    const condition = parts.filter(p => /^(FEW|SCT|BKN|OVC|SKC|CLR|NSC)/.test(p)).join(' ');
    return {
        wind: wind || '---',
        temp: temp || '---',
        condition: condition || '---',
        raw: metarString
    };
};

/**
 * Fetches and parses the latest METAR for a given airport ICAO from the VATSIM network.
 * @param {string} icao - The ICAO code of the airport (e.g., "KJFK").
 * @returns {Promise<object>} A promise that resolves to the parsed weather object.
 */
const fetchAndParseMetar = async (icao) => {
    if (!icao || icao.length < 3) {
        return parseMetar(null); // Return default empty object if ICAO is invalid
    }
    try {
        const response = await fetch(`https://metar.vatsim.net/metar.php?id=${icao}`);
        if (!response.ok) {
            throw new Error('Weather data not available for this location.');
        }
        const rawMetar = await response.text();
        return parseMetar(rawMetar);
    } catch (error) {
        console.error(`Failed to fetch METAR for ${icao}:`, error);
        return parseMetar(null); // Return default on error
    }
};

// Expose the service to be used by other scripts
window.WeatherService = {
    fetchAndParseMetar,
    parseMetar
};