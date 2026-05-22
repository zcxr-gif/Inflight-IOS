exports.handler = async (event, context) => {
  try {
    // Read both keys from Netlify's environment variables
    const mapboxToken = process.env.MAPBOX_ACCESS_TOKEN;
    const owmApiKey = process.env.OWM_API_KEY; 

    // Check if both keys were found
    if (!mapboxToken || !owmApiKey) {
      const missing = [
        !mapboxToken ? 'MAPBOX_ACCESS_TOKEN' : '',
        !owmApiKey ? 'OWM_API_KEY' : ''
      ].filter(Boolean).join(' and ');
      
      console.error(`Missing environment variable(s): ${missing}`);
      
      return {
        statusCode: 500,
        body: JSON.stringify({ error: `Server configuration error: Missing ${missing}` }),
      };
    }

    // Send both keys in the JSON response
    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        mapboxToken: mapboxToken,
        owmApiKey: owmApiKey 
      }),
    };

  } catch (error) {
    console.error('Error in config function:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: 'Internal server error' }),
    };
  }
};