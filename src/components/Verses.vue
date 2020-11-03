<template>
    <ul :dir="dir" 
     class="uk-margin-medium-top uk-list uk-list-divider uk-animation-hover">
        <li  v-for="(verse, i) in verses" :key="i" 
        :class="`uk-animation-slide-bottom uk-animation-15 uk-animation-hover`">
            
            <h5  class=" uk-primary">
              <span class="uk-heading-bullet">  {{book_name}}  </span>
                <span class="uk-badge badge-light">
                    {{verse.chapter}}:{{verse.verse}}
                </span>
            </h5>
            {{verse.text}} <br/>
            <p></p>
        </li>
    </ul>
</template>
<script>
import {mapGetters} from 'vuex';
export default {
    data: () => {
        return {
        // dir: ''
        // book_name: ''
        // chapter:''
        }
    },
    computed: {
       ...mapGetters(['verses', 'dir', 'book_name'])
    }
}
</script>