export const isArray = function(a) {
    return (!!a) && (a.constructor === Array);
};

export const isObject = function(a) {
    return (!!a) && (a.constructor === Object);
};

export  const isDate = function(o) {
    return o instanceof Object && o.constructor === Date;
  }

export const has = function(o,p){
    let has = true
    for (const prop of p) {
        has = o.hasOwnProperty(prop)
        if(!has) break;
    }
    return has;
}
export const  querablePromise = function(promise) {
    // Don't modify any promise that has been already modified.
    if (promise.isPending) return promise;
  
    // Setup our initial state.
    const state = {
      isPending: true,
      isRejected: false,
      isResolved: false,
  
      // Specified so that we'll generate accessor functions for them.
      err: undefined,
      val: undefined,
    };
  
    // We must actually wait for the promise to either resolve or reject,
    // wrap that value, then let it continue on.
    const result = promise.then(
      function(val) {
        state.isResolved = true;
        state.isPending = false;
        state.val = val;
        return val;
      }, 
      function(err) {
        state.isRejected = true;
        state.isPending = false;
        state.err = err;
        throw err;
      }
    );
  
    for (const val of Object.keys(state)) {
      result[val] = function() { return state[val]; };
    }
  
    return result;
  }
  
  async function get(name, keyPath, transArray) {

		let isValidInput = true
		let validInput = []
		
		if(isObject(transArray) && has(transArray, ['name', 'keyPath'])){
			isValidInput = true
			validInput.push(transArray)
		}else if(isArray(transArray)){
			for (const o of transArray) {
				isValidInput = has(o, ['name', 'keyPath'])
				if(!isValidInput)
				break;
			}
		}else{
			isValidInput = false;
		}

		let db = await this.getDb();

		return new Promise((resolve, reject) => {

			if(!isValidInput) reject("Invalid Input");

			let trans = db.transaction([...validInput.map(v => v.name)],'readonly');
			trans.oncomplete = () => {
				resolve(output);
			};
			let output = []

			for (const o of validInput) {
				let store = trans.objectStore(o.name);
				// let tr = {};
				
				store.openCursor().onsuccess = e => {
					let cursor = e.target.result;
					if (cursor) {
						if(o.keyPath == cursor.value['abbreviation'])
							output.push(cursor.value)
						// tr = cursor.value
						cursor.continue();
					}
				};
			}
			trans.onerror = e => {
				reject(e)
			}
			trans.onabort = e => {
				reject(e)
			}

		});
	}