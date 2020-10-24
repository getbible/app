<template>
    <ul :dir="dir" 
     class="uk-margin-medium-top uk-list uk-list-divider uk-animation-hover">
        <li  v-for="(verse, i) in chapter" :key="i" 
        :class="`uk-animation-slide-bottom uk-animation-15 uk-animation-hover`">
            
            <h4  class="btn btn-primary">
                {{book_name}}  
                <span class="uk-badge badge-light">
                    {{verse.chapter}}:{{verse.verse}}
                </span>
            </h4>
            {{verse.text}} <br/>
            <p></p>
        </li>
    </ul>
</template>
<script>
export default {
    props: {
        dir: {
            type:String,
            required:true},
        book_name: {
            type:String,
            required: true,
        },
        chapter:{
            type: Object,
            required: true,
        }
    }
}
</script>