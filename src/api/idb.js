const DB_NAME = 'getbibledb';
const DB_VERSION = 1;
let DB;

export default {

	async getDb() {
		return new Promise((resolve, reject) => {

			if(DB) { return resolve(DB); }
			console.log('OPENING DB', DB);
			let request = window.indexedDB.open(DB_NAME, DB_VERSION);
			
			request.onerror = e => {
				console.log('Error opening db', e);
				reject('Error');
			};
	
			request.onsuccess = e => {
				DB = e.target.result;
				resolve(DB);
			};
			
			request.onupgradeneeded = e => {
				console.log('onupgradeneeded');
				let db = e.target.result;
				db.createObjectStore("savedTranslations", { autoIncrement: true, keyPath:'id' });
			};
		});
	},
	async deleteTranslation(tr) {

		let db = await this.getDb();

		return new Promise(resolve => {

			let trans = db.transaction(['savedTranslations'],'readwrite');
			trans.oncomplete = () => {
				resolve();
			};

			let store = trans.objectStore('savedTranslations');
			store.delete(tr.id);
		});	
	},
	async getTranslations() {

		let db = await this.getDb();

		return new Promise(resolve => {

			let trans = db.transaction(['savedTranslations'],'readonly');
			trans.oncomplete = () => {
				resolve(tr);
			};
			
			let store = trans.objectStore('savedTranslations');
			let tr = [];
			
			store.openCursor().onsuccess = e => {
				let cursor = e.target.result;
				if (cursor) {
					tr.push(cursor.value)
					cursor.continue();
				}
			};

		});
	},

	async saveTranslation(tr) {

		let db = await this.getDb();

		return new Promise(resolve => {

			let trans = db.transaction(['savedTranslations'],'readwrite');
			trans.oncomplete = () => {
				resolve();
			};

			let store = trans.objectStore('savedTranslations');
			store.put(tr);

		});
	
    },
    async getTranslation(abbr) {

		let db = await this.getDb();

		return new Promise(resolve => {

			let trans = db.transaction(['savedTranslations'],'readonly');
			trans.oncomplete = () => {
				resolve(tr);
			};
			
			let store = trans.objectStore('savedTranslations');
			let tr = {};
			
			store.openCursor().onsuccess = e => {
				let cursor = e.target.result;
				if (cursor) {
                    if(abbr == cursor.value.abbreviation)
					tr = cursor.value
					cursor.continue();
				}
			};

		});
	},

}