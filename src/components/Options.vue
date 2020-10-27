<template>
    <div class="uk-container">
        <div class="uk-flex uk-flex-around">
                <div class="input-group mb-3 cols-3">
                    <div class="input-group-prepend">
                        <label class="input-group-text" for="inputGroupSelect01"><h4>Translation</h4> </label>
                    </div>
                    <select @change="update_bk()" v-model="translation" class="uk-select" id="inputGroupSelect01">
                        <!-- <option selected value="1">Choose...</option> -->
                        <option 
                        class="uk-animation-slide-bottom uk-animation-15" v-for="(tr,i) in translations" 
                        :key="i"
                        :value="tr.abbreviation"
                        >{{tr["language"]?`(${tr["language"]})`:null}} {{tr['translation']}}
                        </option>
                        
                    </select>
                </div> 
                <div class="input-group mb-3 cols-3">
                    <div class="input-group-prepend">
                        <label class="input-group-text" for="inputGroupSelect01"><h4>Book</h4> </label>
                    </div>
                    <select @change="update_ch()" v-model="book" class="uk-select" id="inputGroupSelect01">
                        <!-- <option selected value="1">Choose...</option> -->
                        <option 
                        v-for="(bk,i) in Object.keys(books)" 
                        :key="i"
                        :value="books[bk]['nr']"
                        >{{books[bk]['name']}}
                        </option>
                    </select>
                </div> 
                <div class="input-group mb-3 cols-3">
                    <div class="input-group-prepend">
                        <label class="input-group-text" for="inputGroupSelect01"><h4>Chapter</h4></label>
                    </div>
                    <select @change="update_chapter()" v-model="chapter_num" class="uk-select" id="inputGroupSelect01">
                        <!-- <option selected value="1">Choose...</option> -->
                        <option 
                        v-for="(ch,i) in Object.keys(chapters)" 
                        :key="i"
                        :value="chapters[ch]['chapter']"
                        >{{chapters[ch]['chapter']}}
                        </option>
                        
                    </select>
                </div>
            </div>
            <verses
            v-if="translations.length && books[book]"
            :dir="t(translation).direction.toLowerCase()"
            :book_name="books[book].name"
            :chapter="fchapters"
            />

            <div class="uk-margin">
                <ul class="uk-pagination">
                    <li><a href="#"><span class="uk-margin-small-right" uk-pagination-previous></span> Previous Chapter</a></li>
                    <li class="uk-margin-auto-left"><a href="#">Next Chapter<span class="uk-margin-small-left" uk-pagination-next></span></a></li>
                </ul>
            </div>
    </div>
</template>
<script>
import _ from 'lodash';
import verses from './Verses.vue';

export default {
    components:{
        verses
    },  
  data: function(){
                return {
                translation: 'akjv',
                // translations: {},
                chapter: 1,
                chapter_num: 1,
                chapters:{},
                book: 1,
                books: {},
                progress: 0,
                loading: false,
                links: null,
                search: '',
                message: 'Loading...'
            }},
            computed: {
                translations(){
                    return this.$store.state.settings.savedTr;
                },
                
                fchapters: function (){
                    if(!this.search)
                    return this.chapter.verses
                    return this.filteredChapters
                },
                filteredChapters() {
                    return _.orderBy(this.chapter.verses.filter((item) => 
                            item.verse.toString().toLowerCase().includes(this.search.toLowerCase())
                        || item.chapter.toString().toLowerCase().includes(this.search.toLowerCase())
                        || item.name.toString().toLowerCase().includes(this.search.toLowerCase())
                        || item.text.toLowerCase().includes(this.search.toLowerCase())), 'verse');
                    },
            },
            methods:{
                t(i){
                    return this.translations.find(t =>  t.abbreviation === i)
                },
                async update_chapter() {
                    // this.loading = true
                    this.progress = 95
                    let config = {
                    headers: {'Access-Control-Allow-Origin': '*'}
                                };
            
                    let url =  `https://getbible.net/v2/${this.translation}/${this.book}/${this.chapter_num}.json`
                    
                    let response = await fetch(url, config).catch(function(err) {
                            this.chapter = err
                            this.loading =false
                            this.message = 'Error'
                            
                        });

                    if (!response) return;

                    this.progress = 99
                    let data = await response.json().catch(err => {
                                                    this.chapter = err
                                                    this.loading =false
                                                    this.message = 'Error'
                                                })
                    this.loading =false
                        
                    if (!data) return;

                    this.chapter = data
                    this.progress =0

                },
                async update_tr(){

                },
                async update_bk(){
                    let config = {
                    headers: {'Access-Control-Allow-Origin': '*'}
                };
                    this.loading =true
                    this.progress =25
                    this.message = 'Loading...'
                    let url = `https://getbible.net/v2/${this.translation}/books.json`
                    fetch(url,config)
                    .then(response => response.json())
                    .then(data => {
                        // console.log(data)
                        this.books = data
                        this.progress = 60
                        this.update_ch();
                    }).catch(function(err) {
                        this.chapter = err
                        this.loading =false
                        this.message = 'Error'
                    });
                
                },
                async update_ch(){
                    let config = {
                    headers: {'Access-Control-Allow-Origin': '*'}
                };
                    fetch(`https://getbible.net/v2/${this.translation}/${this.book}/chapters.json`,config)
                    .then(response => response.json())
                    .then(data => {
                        // console.log(data)
                        this.chapters = data
                        this.progress = 85
                        this.update_chapter();
                    }).catch(function(err) {
                        this.chapter = err
                        this.loading =false
                        this.message = 'Error'
                    });
                }
            },
            created(){
                let config = {
                    headers: {'Access-Control-Allow-Origin': '*'}
                };
                // fetch(`https://getbible.net/v2/translations.json`,config)
                // .then(response => response.json())
                // .then(data => {
                //     // console.log(data)
                //     this.translations = data

                    fetch(`https://getbible.net/v2/${this.translation}/books.json`, config)
                    .then(response => response.json())
                    .then(data => {
                        // console.log(data)
                        this.books = data

                        this.update_ch();
                    }).catch(function(err) {
                        this.chapter = err
                    });
                // }).catch(function(err) {
                //     this.chapter = err
                // });

                // fetch(`https://getbible.net/v2/kjv/${this.book}/${this.chapter_num}.json`,config)
                // .then(response => response.json())
                // .then(data => {
                //     console.log(data)
                //     this.chapter = data
                // }).catch(function(err) {
                //     this.chapter = err
                // });
            }
}
</script>