import { createStore } from 'vuex'

import idb from './api/idb';

export const store = createStore({
  state: {
    settings: {
        savedTr: []
    },
    trs: [],
    search: '',
  },
  mutations: {
    add_translation (state,translation ) {
        state.settings.savedTr.push(translation)
    },
    remove_translation (state,abbr ) {
        state.settings.savedTr = state.settings.savedTr.filter(tr => tr.abbreviation !==abbr)
        
    }, 
    set_settings(state, settings){
      state.settings =  settings;
      localStorage.setItem('settings', JSON.stringify(settings))
    },
    add_search(state, search){
        state.search = search
    }
  },
  actions:{
      add({commit}, tr){
        commit('add_translation', tr);
      },
      remove({commit}, abbr){
        commit('remove_translation', abbr);
      },
      add_s({commit}, sr){
        commit('add_search', sr);
      },
      async deleteTranslation(context, tr) {
        await idb.deleteCat(tr); 
      },
      async getTranslations(context) {
        context.state.trs = [];
        let trs = await idb.getTranslations();
        trs.forEach(t => {
          context.state.trs.push(t);
        });
      },
      async getTranslation(context, abbr) {
        
        let tr = await idb.getTranslation(abbr);
        return tr;
      },
      async saveTranslation(context, tr) {
        await idb.saveCat(tr);
      }
  }
})

// export default store;