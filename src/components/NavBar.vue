<template>
    
            <div  class="secondary" uk-sticky="sel-target: .uk-navbar-container; cls-active: uk-navbar-sticky">
   
        <nav class="uk-navbar-container primary text-secondary uk-margin-small" uk-navbar>
                <div class="uk-navbar-left">
            
                    <!-- <a class="uk-navbar-item uk-logo" href="#">GetBible</a> -->
             <a href="#selection" class="uk-navbar-item uk-search uk-search-default primary text-secondary" uk-toggle><span  class="primary text-secondary" uk-icon="icon: album; ratio:2"></span>{{book_name }} {{chapter}}</a>

                <a href="#offcanvas-slide" class="uk-navbar-item uk-search uk-search-default primary text-secondary" uk-toggle><span class="primary text-secondary"   uk-icon="icon: search; ratio:2"></span>Search</a>

                    <search/>
                        
                    <!-- <span class="uk-label uk-label-primary"><span class="uk-badge uk-badge-danger">{{ num_of_tr}} </span>Translations Available</span> -->
                    <a class="uk-navbar-item" href="#" uk-toggle><span  class="primary text-secondary" uk-icon="icon: history; ratio:2"></span></a>
            
                </div>
                <a class="uk-navbar-item  uk-position-center-right primary text-secondary" href="#modal-sections" uk-toggle><span class="uk-icon-button primary text-secondary" uk-icon="icon: cog; ratio:2"></span></a>

                    <!-- Settings component -->
                     <settings/>
                
            </nav>
        <div class="uk-position-fixed uk-position-bottom-left">
            <ul class="uk-list">
                <li>
                <a href="#" class="uk-icon-button primary uk-margin-small-left primary text-secondary" uk-icon="github"></a>
                </li>
                <li>
                <a href="#" class="uk-icon-button primary uk-margin-small-left primary text-secondary" uk-icon="facebook"></a>
                </li>
                <li>
                <a href="#" class="uk-icon-button primary uk-margin-small-left primary text-secondary" uk-icon="world"></a>
                </li>
            </ul>
        </div>
        </div>
</template>
<script>
import Search from './Search.vue';
import Settings from './Settings.vue';

export default {
    components: {
        Search,
        Settings
    }
}
</script>