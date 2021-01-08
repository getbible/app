import idb from '../api/idb';
import getbible from '../api/getbible_v2_api';

export default {
  async add({ commit }, payload) {

    // payload = {
    //   abbreviation: '',
    //   saved_translations:{
    //     name: 'saved_translation',
    //     putObj: {}
    //   }
    // }
    commit('toggle_loading', true)
    const response = await getbible.get_translation(payload.abbreviation).catch(err => console.log(err))
    // console.log(response);
    if (!response) return;

    const data = await response.json().catch(err => console.log(err))
    // console.log(JSON.parse(data));
    if (!data) return;
    let dataString = JSON.stringify(data)
    let savet = JSON.stringify(payload.saved_translations.putObj)
    // console.log(dataString);
    payload.translation = {
      name: 'translations',
      putObj: JSON.parse(dataString),
    }
    payload.saved_translations.putObj = JSON.parse(savet)
    let success = false
    //save translation in indexdb
    success = await idb.save(payload.translation).catch(err => console.log(err));

    if (!success)
      return;

    // then save the newly added translation details to the list of saved tr...s
    success = await idb.save(payload.saved_translations).catch(err => console.log(err));

    if (!success) return;

    commit('add_translation', payload);
    commit('toggle_loading', false)
  },
  async remove({ commit }, payload) {
    // payload example
    // payload = {
    //   translation:{
    //     name: 'translation',
    //     keyPath: 'aksjv'
    //   },
    //   saved_translations:{
    //     name: 'saved_translation',
    //     keyPath: "askjv"
    //   }
    // }
    commit('toggle_loading', true)
    const { translation, saved_translations } = payload
    let success = false
    //save translation in indexdb
    success = await idb.delete(translation).catch(err => console.log(err));

    if (!success)
      return;

    // then save the newly added translation details to the list of saved tr...s
    success = await idb.delete(saved_translations).catch(err => console.log(err));


    if (!success) return;

    commit('REMOVE_TRANSLATION', payload);
    setTimeout(() => {
      commit('toggle_loading', false)
    }, 1200)
  },
  async initialise({ commit }) {
    commit('toggle_loading', true)
    let saved_translations = await idb.getAll('saved_translations').catch(err => console.log(err));
    console.log(saved_translations);
    if (!saved_translations) saved_translations = [];


    let translations = await idb.getAll('translations').catch(err => console.log(err));

    if (!translations || !translations.length) translations = [{}];

    commit('initialise', { saved_translations, translation: translations[0] })

    commit('toggle_loading', false)

  },
  set_chapter({ commit }, payload) {
    commit('set_chapter', payload)
  },
  message({ commit }, payload) {
    commit('message', payload)
  },
  set_book({ commit }, payload) {
    commit('set_book', payload)
  },
  async set_translation({ commit }, payload) {
    commit('toggle_loading', true)
    let translation = await idb.get('translations', payload.selected_translation).catch(err => console.log(err));

    if (!translation) return;
    payload.translation = translation
    commit('set_translation', payload)
    // console.log("from acitons", payload);
    setTimeout(() => {
      commit('toggle_loading', false)
    }, 2500)
  },
  search({ commit }, payload) {
    commit('search', payload)
  }
}