<template>
    <div class=" uk-width-1-1">
    <ul class="uk-nav-default uk-nav-parent-icon uk-witdth-1-1 "  uk-nav>
        <li class="uk-parent uk-witdth-1-1"><a>Translation</a>
            <ul class="uk-nav-sub uk-subnav uk-subnav-pill uk-pagination" uk-margin>

            <!-- <li><a href="#"><span uk-pagination-previous></span></a></li> -->
                    <li
                    v-for="(tr,i) in translations" 
                    @change="update_bk(tr.abbreviation)"
                    :key="i"
                    :value="tr.abbreviation"
                    ><a href="#">{{tr["language"]?`(${tr["language"]})`:null}} {{tr['translation']}}</a></li>
                 <!-- <li><a href="#"><span uk-pagination-next></span></a></li> -->
            </ul>
        </li>
        <li class="uk-nav-divider uk-witdth-1-1"></li>
        <li class="uk-parent uk-witdth-1-1"><a>Books</a>
            <ul class="uk-nav-sub uk-subnav uk-subnav-pill uk-pagination" uk-margin>

            <!-- <li><a href="#"><span uk-pagination-previous></span></a></li> -->
                    <li class="uk-card uk-card-hover "
                     v-for="(bk,i) in Object.keys(books)" 
                     @change="update_ch(books[bk]['nr'])"
                    :key="i"
                    :value="books[bk]['nr']"
                    ><a href="#">{{books[bk]['name']}}</a></li>
             <!-- <li><a href="#"><span uk-pagination-next></span></a></li> -->
            </ul>
        </li>
        <li class="uk-nav-divider uk-witdth-1-1"></li>
        <li class="uk-parent uk-witdth-1-1 "><a>Chapters</a>
            <ul class="uk-nav-sub uk-subnav uk-subnav-pill uk-pagination" uk-margin>
                <li><a href="#"><span uk-pagination-previous></span></a></li>
                    <li
                     v-for="(ch,i) in Object.keys(chapters)" 
                    @change="update_chapter(chapters[ch]['chapter'])" 
                    :key="i"
                    ><a >{{chapters[ch]['chapter']}}</a></li>
               <li><a href="#"><span uk-pagination-next></span></a></li>
            </ul>
        </li>
     </ul>
</div>
</template>
<script>
import _ from 'lodash';
// import verses from './Verses.vue';

export default {
    components:{
        // verses
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
                    return this.$store.state.saved_translations;
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
                async update_chapter(c) {
                    console.log(c);
                    this.chapter_num = c
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
                async update_bk(a){
                    this.translation = a
                    console.log(a);
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
                        this.update_ch(this.book);
                    }).catch(function(err) {
                        this.chapter = err
                        this.loading =false
                        this.message = 'Error'
                    });
                
                },
                async update_ch(b){
                    this.book = b
                    console.log(b);
                    let config = {
                    headers: {'Access-Control-Allow-Origin': '*'}
                };
                    fetch(`https://getbible.net/v2/${this.translation}/${this.book}/chapters.json`,config)
                    .then(response => response.json())
                    .then(data => {
                        // console.log(data)
                        this.chapters = data
                        this.progress = 85
                        this.update_chapter(this.chapter_num);
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

                        this.update_ch(this.book);
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