<template>
    <nav class="uk-navbar-container uk-navbar-transparent uk-margin" uk-navbar>
            <div class="uk-navbar-left">
        
                <a class="uk-navbar-item uk-logo" href="#">GetBible</a>
        
                <ul class="uk-navbar-nav">
                    <li>
                        <a href="#">
                            <!-- <span class="uk-icon uk-margin-small-right" uk-icon="icon: star"></span> -->
                            About
                        </a>
                    </li>
                    <li>
                        <a href="#">
                            <!-- <span class="uk-icon uk-margin-small-right" uk-icon="icon: star"></span> -->
                            API
                        </a>
                    </li>
                    <li>
                        <a href="#">
                            <!-- <span class="uk-icon uk-margin-small-right" uk-icon="icon: star"></span> -->
                            Download
                        </a>
                    </li>
                    <li>
                        <a href="#">Support</a>
                        <div class="uk-navbar-dropdown">
                            <ul class="uk-nav uk-navbar-dropdown-nav">
                                <li class="uk-active"><a href="#">Main Components</a></li>
                                <li><a href="#">Load Scriptures</a></li>
                                <!-- <li class="uk-nav-header">Header</li>
                                <li><a href="#">Item</a></li>
                                <li><a href="#">Item</a></li>
                                <li class="uk-nav-divider"></li>
                                <li><a href="#">Item</a></li> -->
                            </ul>
                        </div>
                    </li>
                </ul>
        
        
                <div class="uk-navbar-item">
                    <form class="uk-search uk-search-default" action="javascript:void(0)">
                        <span uk-search-icon></span>
                        <input class="uk-search-input" v-model="search" type="search" placeholder="Search this Chapter...">
                    </form>
                </div>
                <!-- <span class="uk-label uk-label-primary"><span class="uk-badge uk-badge-danger">{{ num_of_tr}} </span>Translations Available</span> -->
        
            </div>
        </nav>
</template>