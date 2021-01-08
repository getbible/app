/* eslint-disable no-debugger */

export default {

  chapter: (state) => {
    return state.selected.chapter
  },

  book_nr: (state) => {
    return state.selected.book
  },
  loading: (state) => {
    return state.loading;
  },
  book_name: (state, getters) => {
    if (!getters.books.length) return null
    let book = getters.books.find(book => book.nr === getters.book_nr)
    if (!book) return null;
    return book.name;
  },

  translation: (state) => {
    return state.selected.translation;
  },
  saved_translations: (state) => {
    return state.saved_translations;
  },
  in_memory_translation: (state) => {
    // console.log("from ", state.in_memory_translation );
    return state.in_memory_translation
  },

  books: (state, getters) => {
    if (!getters.in_memory_translation.books)
      return []
    debugger;
    return getters.in_memory_translation.books.map(book => ({ nr: book.nr, name: book.name }))
  },

  dir: (state, getters) => {
    // console.log(getters.in_memory_translation);
    if (!getters.in_memory_translation.direction)
      return 'ltr'
    return getters.in_memory_translation.direction.toLowerCase();
  },
  search: (state) => {
    console.log(state.search);
    debugger;
    return state.search;
  },
  chapters: (state, getters) => {
    console.log(getters.book_nr);
    debugger;
    if (!getters.book_nr) return [];
    const book = getters.in_memory_translation.books.find(book => book.nr == getters.book_nr)
    console.log("Found the book", book);
    return book.chapters
  },

  verses: (state, getters) => {
    // console.log("Searching for chapter", getters.chapter);
    if (!getters.chapter)
      return []
    const chapter = getters.chapters.find(chapter => chapter.chapter === getters.chapter)
    return chapter.verses;
  }

}