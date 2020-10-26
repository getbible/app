<template>
    <nav class="uk-navbar-container uk-navbar-transparent uk-margin" uk-navbar>
            <div class="uk-navbar-left">
        
                <a class="uk-navbar-item uk-logo" href="#">GetBible</a>
        
                <div class="uk-navbar-item">
                    <form class="uk-search uk-search-default" action="javascript:void(0)">
                        <span uk-search-icon></span>
                        <input class="uk-search-input" v-model="search" type="search" placeholder="Search Chapter...">
                    </form>
                </div>
                <!-- <span class="uk-label uk-label-primary"><span class="uk-badge uk-badge-danger">{{ num_of_tr}} </span>Translations Available</span> -->
        
            </div>
        </nav>
</template>