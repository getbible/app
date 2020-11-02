<template>
    
    <div id="offcanvas-slide" uk-offcanvas>
        <div class="uk-offcanvas-bar">

            <div class="uk-nav uk-nav-default"> 
                    <div class="uk-margin">
                        <form class="uk-search uk-search-default" action="javascript:void(0)">
                                <!-- <span uk-search-icon></span> -->
                                <input class="uk-search-input" v-model="search" type="search" placeholder="Search Words...">
                                <div class="uk-margin">
                                    <button class="uk-button uk-button-default uk-button-small">Search</button>
                                </div>
                        </form>

                    </div>
                    
                    <div class="uk-margin">

                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small uk-active">ALL WORDS</button>
                                <button class="uk-button uk-button-default uk-button-small">ANY WORDS</button>
                                <button class="uk-button uk-button-default uk-button-small">PHRASE</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small uk-active">BIBLE</button>
                                <button class="uk-button uk-button-default uk-button-small">OT</button>
                                <button class="uk-button uk-button-default uk-button-small">NT</button>
                                <button class="uk-button uk-button-default uk-button-small">CHAPTER</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small uk-active">EXACT MATCH</button>
                                <button class="uk-button uk-button-default uk-button-small">PARTIAL MATCH</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small uk-active">CASE INSENSITIVE</button>
                                <button class="uk-button uk-button-default uk-button-small">CASE SENSITIVE</button>
                            </div>
                        </div>
                    </div>
            </div>

        </div>
    </div>

</template>
<script>
export default {
    
}
</script>