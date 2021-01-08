<template>
    <div id="selection" class="primary text-secondary uk-animation-slide-bottom uk-width-1-1 uk-card uk-card-default uk-card-body rounded" uk-margin>
        <div class="" v-if="!saved_translations.length>0">No translations added. <br/>Please click <a @click="open_settings">HERE</a> to Open Settings</div>
        <div v-else>

    <ul class="uk-nav-default uk-nav-parent-icon uk-witdth-1-1 " uk-nav="multiple: false" >
        <li class="uk-parent uk-witdth-1-1"><a class="text-secondary">Translation</a>
            <ul class="uk-nav-sub uk-subnav uk-subnav-pill uk-pagination" uk-margin>

            <!-- <li><a href="#"><span uk-pagination-previous></span></a></li> -->
                    <li
                    class="uk-card uk-card-hover text-secondary rounded"
                    v-for="(tr,i) in saved_translations" 
                    @click="set_translation(tr.abbreviation)"
                    :key="i"
                    ><a class="text-secondary" href="#">{{tr["language"]?`(${tr["language"]})`:null}} {{tr['translation']}}</a></li>
                 <!-- <li><a href="#"><span uk-pagination-next></span></a></li> -->
            </ul>
        </li>
        <li class="uk-nav-divider uk-witdth-1-1"></li>
        <li v-if="translation" class="uk-parent uk-witdth-1-1"><a class="text-secondary">Books</a>
            <ul class="uk-nav-sub uk-subnav uk-subnav-pill uk-pagination" uk-margin>

            <!-- <li><a href="#"><span uk-pagination-previous></span></a></li> -->
                    <li class="uk-card uk-card-hover text-secondary"
                     v-for="(bk,i) in books" 
                     @click="set_book(bk['nr'])"
                    :key="i"
                    ><a href="#" class="text-secondary">{{bk['name']}}</a></li>
             <!-- <li><a href="#"><span uk-pagination-next></span></a></li> -->
            </ul>
        </li>
        <li class="uk-nav-divider uk-witdth-1-1"></li>
        <li v-if="book_nr" class="uk-parent uk-witdth-1-1 "><a class="text-secondary">Chapters</a>
            <ul class="uk-nav-sub uk-subnav uk-subnav-pill uk-pagination" uk-margin>
                <!-- <li><a href="#"><span uk-pagination-previous></span></a></li> -->
                    <li
                    class="uk-card uk-card-hover "
                     v-for="(ch,i) in chapters" 
                    @click="set_chapter(ch['chapter'])" 
                    :key="i"
                    ><a href="#selection" class="text-secondary" uk-toggle>{{ch['chapter']}}</a></li>
               <!-- <li><a href="#"><span uk-pagination-next></span></a></li> -->
            </ul>
        </li>
     </ul>
    </div>
</div>
</template>
<script>
// import _ from 'lodash';
import UIkit from 'uikit';

import {mapGetters} from 'vuex';
export default {
    components:{
        // verses
    },  
  data: function(){
                return {
                // translation: 'akjv',
             
            }},
            computed: {
                // translations(){
                //     // console.log(this.$store.state.saved_translations);
                //     return this.$store.getters.saved_translations;
                // },
                ...mapGetters(['chapters', 'books', 'translation', 'book_nr', 'saved_translations']),
               
            },
            methods:{
                t(i){
                    return this.translations.find(t =>  t.abbreviation === i)
                },  
                set_translation(a) {
                     console.log("Hello");
                     this.$store.dispatch('set_translation', {selected_translation:a})
                },
                set_book(b){
                    this.$store.dispatch('set_book', b)
                },
                set_chapter(c){
                     this.$store.dispatch('set_chapter', c)
                },
                open_settings(){
                    UIkit.modal('#modal-sections').show()
                }
            },
            created(){
              
            }
}
</script>