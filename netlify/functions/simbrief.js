// netlify/functions/simbrief.js

const crypto = require('crypto');
const { parseStringPromise } = require('xml2js');

exports.handler = async (event) => {
    // This is your secret key stored securely in Netlify's environment variables
    const SIMBRIEF_API_KEY = process.env.SIMBRIEF_API_KEY;

    // Get the query parameters from the request URL
    const { api_req, js_url_check, var: varname = 'phpvar', fetch_ofp, ofp_id } = event.queryStringParameters;

    // Functionality 1: Generate the 'api_code' for the SimBrief popup
    // This replicates the `if (isset($_GET['api_req']))` block
    if (api_req) {
        const api_code = crypto.createHash('md5').update(SIMBRIEF_API_KEY + api_req).digest('hex');
        return {
            statusCode: 200,
            headers: { 'Content-Type': 'application/javascript' },
            body: `var api_code = "${api_code}";`
        };
    }

    // Functionality 2: Check if a flight plan XML file exists
    // This replicates the `if (isset($_GET['js_url_check']))` block
    if (js_url_check) {
        const url = `http://www.simbrief.com/ofp/flightplans/xml/${js_url_check}.xml`;
        try {
            // We use a 'HEAD' request because we only need to know if the file exists (status code),
            // not download its contents. This is much faster.
            const response = await fetch(url, { method: 'HEAD' });
            const fileExists = response.ok; // .ok is true for status codes 200-299
            
            return {
                statusCode: 200,
                headers: { 'Content-Type': 'application/javascript' },
                body: `var ${varname} = "${fileExists ? 'true' : 'false'}";`
            };
        } catch (error) {
            return {
                statusCode: 200, // Still return 200 so the frontend script doesn't break
                headers: { 'Content-Type': 'application/javascript' },
                body: `var ${varname} = "false";`
            };
        }
    }

    // Functionality 3: Fetch and convert the OFP (Operational Flight Plan) XML to JSON
    // This is the part your `handleSimbriefReturn` function will call
    if (fetch_ofp && ofp_id) {
        const url = `http://www.simbrief.com/ofp/flightplans/xml/${ofp_id}.xml`;
        try {
            const response = await fetch(url);
            if (!response.ok) {
                throw new Error('Flight plan not found on SimBrief servers.');
            }
            const xmlData = await response.text();
            
            // Convert the fetched XML data to a JavaScript object
            const jsonData = await parseStringPromise(xmlData, {
                explicitArray: false, // Makes the structure cleaner
                mergeAttrs: true,      // Merges attributes into properties
            });
            
            return {
                statusCode: 200,
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(jsonData)
            };
        } catch (error) {
            return {
                statusCode: 404,
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: error.message || 'Failed to fetch flight plan.' })
            };
        }
    }

    // Default response if no valid parameters are provided
    return {
        statusCode: 400,
        body: 'Bad Request: Missing required query parameters.'
    };
};