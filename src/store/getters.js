export default {

    chapter : (state) =>{
      return state.selected.chapter
    },

    book_nr : (state) =>{
      return state.selected.book
    },

    book_name:(state, getters)=> {
      return getters.books.find(book => book.nr === getters.book_nr).name
    },

    translation: (state)=>{
      return state.selected.translation;
    },

    in_memory_translation : (state) =>{
      return state.in_memory_translation
    },

    books : (state)=>{
      if(!state.in_memory_translation.books)
      return []

      return state.in_memory_translation.books.map(book => ({nr: book.nr, name: book.name}))
    },

    dir:(state, getters)=>{
      if(getters.in_memory_translation.dir)
      return getters.in_memory_translation.dir.toLowerCase();
      return 'ltr'
    },

    chapters : (state, getters) =>{
      if(!getters.book) return [];
      const book =  getters.books.find(book => book.nr === getters.book)
      return book.chapters
    },

    verses: (state, getters) => {
      if(!getters.chapter)
        return []
      const chapter = getters.chapters.find(chapter => chapter.chapter === getters.chapter)
      return chapter.verses;
    }
    
  }