<template >
    <div v-if="verses.length">
    <ul :dir="dir" 
     class="uk-margin-medium-top uk-list uk-list-divider uk-animation-hover">
        <li  v-for="(verse, i) in pverses" :key="i" 
        :class="`uk-animation-slide-bottom uk-animation-15 uk-animation-hover`"
     >
            
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

    <div class="uk-position-small uk-position-center-left uk-overlay uk-overlay-default">
        <span @click="prevV" class="uk-icon-button" uk-icon="icon:chevron-left; ratio:2"></span>
</div>
    <div class="uk-position-small uk-position-center-right uk-overlay uk-overlay-default">
        <span @click="nextV" class="uk-icon-button" uk-icon="icon:chevron-right; ratio:2"></span>

    </div>

    <!-- <ul class="uk-pagination" uk-margin>
    <li><a href="#"><span uk-pagination-previous></span></a></li>
    <li><a href="#">1</a></li>
    <li class="uk-disabled"><span>...</span></li>
    <li><a href="#">4</a></li>
    <li><a href="#">5</a></li>
    <li><a href="#">6</a></li>
    <li class="uk-active"><span>7</span></li>
    <li><a href="#">8</a></li>
    <li><a href="#">9</a></li>
    <li><a href="#">10</a></li>
    <li class="uk-disabled"><span>...</span></li>
    <li><a href="#">20</a></li>
    <li><a href="#"><span uk-pagination-next></span></a></li>
</ul> -->
    </div>
</template>
<script>
import {mapGetters} from 'vuex';
export default {
    data: () => {
        return {
        // dir: ''
        prev: 0,
        next:5
        }
    },
    computed: {
       ...mapGetters(['verses', 'dir', 'book_name']),
       pverses(){
           return this.verses.slice(this.prev, this.next)
       }
    },
    methods: {
        nextV(){
            if(this.next> this.verses.length) return;
            this.next = this.next + 5
            this.prev = this.prev+ 5
            // console.log(this.next, this.prev);
        },
        prevV(){
            if(this.prev<1)
            return;
            this.next -=5
            this.prev -=5
        }
    }
}
</script>