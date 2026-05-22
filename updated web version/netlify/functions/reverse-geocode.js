// --- [NEW FILE] ---
// File: netlify/functions/reverse-geocode.js

const fetch = require('node-fetch');

exports.handler = async (event) => {
    // 1. Get API Key from Netlify environment variables
    const API_KEY = process.env.LOCATIONIQ_API_KEY;

    if (!API_KEY) {
        return {
            statusCode: 500,
            body: JSON.stringify({ error: 'API key is not configured on the server.' }),
        };
    }

    // 2. Get lat/lon from the query string
    const { lat, lon } = event.queryStringParameters;

    if (!lat || !lon) {
        return {
            statusCode: 400,
            body: JSON.stringify({ error: 'Missing latitude or longitude parameters.' }),
        };
    }

    // 3. Build the API URL for LocationIQ (Geocoding IQ)
    const url = `https://us1.locationiq.com/v1/reverse.php?key=${API_KEY}&lat=${lat}&lon=${lon}&format=json`;

    try {
        // 4. Call the API
        const response = await fetch(url);
        const data = await response.json();

        // 5. Handle errors (e.g., "Unable to geocode" for oceans)
        if (data.error || !data.address) {
            let location = 'Ocean / Remote Area';
            if (data.error) {
                console.warn(`LocationIQ Error: ${data.error}`);
            }
            return {
                statusCode: 200, // Return 200 so the frontend can handle it
                body: JSON.stringify({ location }),
            };
        }

        // 6. Format the location string
        const { address } = data;
        let locationParts = [];

        // Try to find the most specific, useful name
        if (address.city) {
            locationParts.push(address.city);
        } else if (address.town) {
            locationParts.push(address.town);
        } else if (address.village) {
            locationParts.push(address.village);
        } else if (address.state) {
            // If no city, use state (e.g., "Nevada")
            locationParts.push(address.state);
        } else if (address.hamlet) {
            locationParts.push(address.hamlet);
        }

        // Add the country
        if (address.country) {
            locationParts.push(address.country);
        }
        
        let location = 'Remote Area';
        if (locationParts.length > 0) {
            location = locationParts.join(', ');
        }

        // 7. Return the formatted location
        return {
            statusCode: 200,
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ location }),
        };

    } catch (error) {
        console.error('Reverse geocode function error:', error);
        return {
            statusCode: 500,
            body: JSON.stringify({ error: 'Failed to fetch location data.' }),
        };
    }
};