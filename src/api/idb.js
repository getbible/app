const DB_NAME = 'getbibledb';
const DB_VERSION = 3;
let DB;
// window.indexedDB = window.indexedDB || window.mozIndexedDB || window.webkitIndexedDB || window.msIndexedDB;

export default {

	async getDb() {
		return new Promise((resolve, reject) => {

			if(DB) { return resolve(DB); }
			console.log('OPENING DB', DB);
			let request = window.indexedDB.open(DB_NAME, DB_VERSION);
			
			request.onerror = (e) => {
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
				db.createObjectStore("saved_translations", { keyPath:'abbreviation' });
				db.createObjectStore("translations", { keyPath:'abbreviation' });
				
				// 	let index = translations.createIndex('book_idx', 'name');
					// let transaction = db.transaction("books"); // readonly
					// let books = transaction.objectStore("books");
				// 	let bookIndex = translations.index("book_idx");

				// 	let request = bookIndex.getAll("Genesis");

				// 	request.onsuccess = function() {
				// 	if (request.result !== undefined) {
				// 		console.log("Books", request.result); // array of books with name="Genesis"
				// 	} else {
				// 		console.log("No such books");
				// 	}
				// }
			};
		});
	},
	async delete(delInfo) { 	

		let db = await this.getDb();

		return new Promise((resolve, reject) => {

			let trans = db.transaction([delInfo.name],'readwrite');
			trans.oncomplete = () => {
				resolve(true);
			};

			let store = trans.objectStore(delInfo.name);
			store.openCursor().onsuccess = e => {
				let cursor = e.target.result;
				if (cursor) {
                    if(delInfo.keyPath == cursor.value['abbreviation']){
						let request =cursor.delete()
						request.onsuccess = e => console.log(e);}
					
					cursor.continue();
				}
			};
			trans.onerror = e => {
				reject(e)
			}
			trans.onabort = e => {
				reject(e)
			}

		});	
	},
	async getAll(name) {

		let db = await this.getDb();

		return new Promise(resolve => {

			let trans = db.transaction([name],'readonly');
			trans.oncomplete = () => {
				resolve(tr);
			};
			
			let store = trans.objectStore(name);
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

	async save(arg) {

		let db = await this.getDb();

		return new Promise((resolve, reject) => {

			let trans = db.transaction([arg.name],'readwrite');
			trans.oncomplete = () => {
				resolve(true);
			};
			console.log(arg.name);
			let store = trans.objectStore(arg.name);
			store.put(arg.putObj);
			trans.onerror = e => reject(e)
		});
	
    },
    async get(name, keyPath) {

		let db = await this.getDb();

		return new Promise((resolve, reject) => {

			let trans = db.transaction([name],'readonly');
			trans.oncomplete = () => {
				resolve(tr);
			};
			
			let store = trans.objectStore(name);
			let tr = {};
			
			store.openCursor().onsuccess = e => {
				let cursor = e.target.result;
				if (cursor) {
                    if(keyPath == cursor.value['abbreviation'])
					tr = cursor.value
					cursor.continue();
				}
			};
			trans.onerror = e => {
				reject(e)
			}
			trans.onabort = e => {
				reject(e)
			}

		});
	},
	// async search(name, keyPath) {

	// 	let db = await this.getDb();

	// 	return new Promise((resolve, reject) => {

	// 		let trans = db.transaction([name],'readonly');
	// 		trans.oncomplete = () => {
	// 			resolve(tr);
	// 		};
			
	// 		let store = trans.objectStore(name);
	// 		let tr = {};
			
	// 		store.openCursor().onsuccess = e => {
	// 			let cursor = e.target.result;
	// 			if (cursor) {
    //                 if (keyPath == cursor.value.keyPath){
	// 				tr = cursor.value
	// 				for (const book in cursor.value.books) {
	// 					for (const chapters in book) {
	// 						for (const verses in chapters) {
	// 							for (const verse in verses) {
	// 								if(verse.text.includes(keyPath)){
	// 									console.log("We found a row with value: " + JSON.stringify(verse.text));
	// 								}										
	// 							}
	// 						}
	// 					}
	// 				}
					
	// 				}
	// 				cursor.continue();
	// 			}
	// 		};
	// 		trans.onerror = e => {
	// 			reject(e)
	// 		}
	// 		trans.onabort = e => {
	// 			reject(e)
	// 		}
	// 		trans.commit();

	// 	});
	// },

}