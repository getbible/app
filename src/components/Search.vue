<template>
    
    <div id="offcanvas-slide" uk-offcanvas>
        <div class="uk-offcanvas-bar secondary text-secondary">

            <div class="uk-nav uk-nav-default"> 
                    <div class="uk-margin">
                        <form class="uk-search uk-search-default" action="javascript:void(0)">
                                <!-- <span uk-search-icon></span> -->
                                <input class="uk-search-input text-primary" v-model="search" type="search" placeholder="Search Words...">
                                <div class="uk-margin">
                                    <button class="uk-button uk-button-default uk-button-small text-primary">Search</button>
                                </div>
                        </form>

                    </div>
                    
                    <div class="uk-margin">

                        <div class="uk-margin">
                            <div class="uk-button-group text-primary">
                                <button class="uk-button uk-button-default uk-button-small text-primary uk-active">ALL WORDS</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">ANY WORDS</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">PHRASE</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small text-primary uk-active">BIBLE</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">OT</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">NT</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">CHAPTER</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small text-primary uk-active">EXACT MATCH</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">PARTIAL MATCH</button>
                            </div>
                        </div>
                        <div class="uk-margin">
                            <div class="uk-button-group">
                                <button class="uk-button uk-button-default uk-button-small text-primary uk-active">CASE INSENSITIVE</button>
                                <button class="uk-button uk-button-default uk-button-small text-primary">CASE SENSITIVE</button>
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