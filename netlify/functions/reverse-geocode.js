const fetch = require('node-fetch');

exports.handler = async (event) => {
  // Define CORS headers
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json'
  };

  // Handle preflight
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  const API_KEY = process.env.LOCATIONIQ_API_KEY;

  if (!API_KEY) {
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: 'Server config error.' }),
    };
  }

  const { lat, lon } = event.queryStringParameters;

  if (!lat || !lon) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: 'Missing lat/lon.' }),
    };
  }

  const url = `https://us1.locationiq.com/v1/reverse.php?key=${API_KEY}&lat=${lat}&lon=${lon}&format=json`;

  try {
    const response = await fetch(url);
    const data = await response.json();

    if (data.error || !data.address) {
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({ location: 'Ocean / Remote Area' }),
      };
    }

    // Format the location string
    const { address } = data;
    let locationParts = [];
    if (address.city) locationParts.push(address.city);
    else if (address.town) locationParts.push(address.town);
    else if (address.village) locationParts.push(address.village);
    else if (address.hamlet) locationParts.push(address.hamlet);
    
    if (address.state) locationParts.push(address.state);
    if (address.country) locationParts.push(address.country);
    
    let location = locationParts.length > 0 ? locationParts.join(', ') : 'Remote Area';

    return {
      statusCode: 200,
      headers, // <--- CRITICAL: Return headers so app accepts data
      body: JSON.stringify({ location }),
    };

  } catch (error) {
    console.error('Reverse geocode error:', error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: 'Failed to fetch location data.' }),
    };
  }
};