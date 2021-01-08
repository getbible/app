

export default {
    add_translation (state, payload ) {

     state.saved_translations.push(payload.saved_translations.putObj)
       
   },
    REMOVE_TRANSLATION (state, payload ) {
     
     const {keyPath} = payload.saved_translations;

     state.saved_translations = state.saved_translations.filter(tr => tr.abbreviation !== keyPath)

     if(state.in_memory_translation.abbreviation === keyPath){
       state.in_memory_translation = {}
       state.selected = {
         translation: null,
         book: null,
         chapter: null
       }
     }
       
   }, 
   save_settings(state, settings){
     state.settings =  settings;
     localStorage.setItem('settings', JSON.stringify(settings))
   },
   add_search(state, search){
       state.search = search
   },
   initialise(state, payload){
      state.saved_translations = payload.saved_translations
      state.in_memory_translation = payload.translation
      console.log(state.saved_translations);
   },
   set_chapter(state, payload){
       state.selected.chapter = payload;
   },
   set_book(state, payload){
      state.selected.chapter = null;
      state.selected.book =  payload;
   },
   set_translation(state, payload){
      state.selected.book = null
      state.selected.chapter = null
      state.selected.translation = payload.selected_translation;
      state.in_memory_translation = payload.translation;
   },
   toggle_loading(state, payload){
      state.loading = payload;
   },
   search(state, payload){
     state.search = payload;
   }
 }