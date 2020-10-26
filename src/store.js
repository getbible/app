import { createStore } from 'vuex'

export const store = createStore({
  state: {
    settings: {
        savedTr: []
    },
    search: '',
  },
  mutations: {
    add_translation (state,translation ) {
        state.settings.savedTr.push(translation)
    },
    remove_translation (state,abbr ) {
        state.settings.savedTr = state.settings.savedTr.filter(tr => tr.abbreviation !==abbr)
        
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
  }
})

// export default store;