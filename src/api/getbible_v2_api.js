// TO DO
// these should be imported from root config file

let BASE_URL = 'https://getbible.net';
let API_VERSION = 'v2';

export { BASE_URL, API_VERSION };


export default {
    get_translations() {
        return fetch(`${BASE_URL}/${API_VERSION}/translations.json`)
    },
    get_translation(abbreviation) {
        return fetch(`${BASE_URL}/${API_VERSION}/${abbreviation}.json`)
    }
}