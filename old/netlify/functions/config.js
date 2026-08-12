exports.handler = async (event, context) => {
  // Define allowed origins (Your production site + local development/app schemes)
  const headers = {
    'Access-Control-Allow-Origin': '*', // OR specific origins like 'capacitor://localhost'
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Content-Type': 'application/json'
  };

  // Handle preflight OPTIONS request (browser checking permissions)
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 200,
      headers,
      body: ''
    };
  }

  try {
    const mapboxToken = process.env.MAPBOX_ACCESS_TOKEN;
    const owmApiKey = process.env.OWM_API_KEY; 

    if (!mapboxToken || !owmApiKey) {
      const missing = [
        !mapboxToken ? 'MAPBOX_ACCESS_TOKEN' : '',
        !owmApiKey ? 'OWM_API_KEY' : ''
      ].filter(Boolean).join(' and ');
      
      console.error(`Missing environment variable(s): ${missing}`);
      
      return {
        statusCode: 500,
        headers, // Include headers even on error
        body: JSON.stringify({ error: `Server configuration error: Missing ${missing}` }),
      };
    }

    return {
      statusCode: 200,
      headers, // <--- CRITICAL: Send headers with the keys
      body: JSON.stringify({
        mapboxToken: mapboxToken,
        owmApiKey: owmApiKey 
      }),
    };

  } catch (error) {
    console.error('Error in config function:', error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: 'Internal server error' }),
    };
  }
};