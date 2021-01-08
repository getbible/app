<template>
    
    <div id="offcanvas-slide" uk-offcanvas>
        <div class="uk-offcanvas-bar secondary text-secondary">

            <div class="uk-nav uk-nav-default"> 
                    <div class="uk-margin">
                        <form class="uk-search uk-search-default" action="javascript:void(0)">
                                <!-- <span uk-search-icon></span> -->
                                <input class="uk-search-input text-secondary primary rounded" v-model="search_text" type="search" placeholder="Search Words...">
                                <div class="uk-margin">
                                    <button class="uk-button uk-button-default uk-button-small text-secondary primary rounded">Search</button>
                                </div>
                        </form>

                    </div>
                    
                    <div class="uk-margin">

                        <div class="uk-margin">
                            <div class="uk-button-group text-primary ">
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary uk-active">ALL WORDS</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">ANY WORDS</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">PHRASE</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary uk-active">BIBLE</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">OT</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">NT</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">CHAPTER</button>
                            </div>
                        </div>
                        <div class="uk-button-group" data-uk-button-radio>
                            <label class="uk-button primary">
                                <input class="primary" type="radio" checked="checked" v-model="gender"  value="0" style="display:none;"/>
                                Male
                            </label>
                            <label class="uk-button primary">
                                <input type="radio"  v-model="gender" value="1" style="display:none;"/>
                                Female
                            </label>
                        </div>
                        {{gender}}
                        <!-- <input type="color" name="theme" id=""> -->
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary uk-active">EXACT MATCH</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">PARTIAL MATCH</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary uk-active">CASE INSENSITIVE</button>
                                <button class="uk-button uk-button-default uk-button-small text-secondary primary">CASE SENSITIVE</button>
                            </div>
                        </div>
                    </div>
            </div>

        </div>
    </div>

</template>
<script>
export default {
    data(){
        return {
            search_text: '', 
            search_area: '',
            match: '',
            sensitivity: '',
            words: '',
            gender: '',
        }
    },
    methods: {

    }
}
</script>