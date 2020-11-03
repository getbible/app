

export default {

    chapter : (state) =>{
      return state.selected.chapter
    },

    book_nr : (state) =>{
      return state.selected.book
    },
    loading: (state) =>{
      return state.loading;
    },
    book_name:(state, getters)=> {
      return getters.books.find(book => book.nr === getters.book_nr).name
    },

    translation: (state)=>{
      return state.selected.translation;
    },

    in_memory_translation : (state) =>{
      // console.log("from ", state.in_memory_translation );
      return state.in_memory_translation
    },

    books : (state, getters)=>{
      if(!getters.in_memory_translation.books)
      return []

      return getters.in_memory_translation.books.map(book => ({nr: book.nr, name: book.name}))
    },

    dir:(state, getters)=>{
      // console.log(getters.in_memory_translation);
      if(!getters.in_memory_translation.direction)
      return 'ltr'
      return getters.in_memory_translation.direction.toLowerCase();
    },

    chapters : (state, getters) =>{
      console.log(getters.book_nr);
      if(!getters.book_nr) return [];
      const book =  getters.in_memory_translation.books.find(book => book.nr == getters.book_nr)
      console.log("Found the book",book);
      return book.chapters
    },

    verses: (state, getters) => {
      // console.log("Searching for chapter", getters.chapter);
      if(!getters.chapter)
        return []
      const chapter = getters.chapters.find(chapter => chapter.chapter === getters.chapter)
      return chapter.verses;
    }
    
  }