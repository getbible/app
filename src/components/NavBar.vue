<template>
    <nav class="uk-navbar-container uk-navbar-transparent uk-margin" uk-navbar>
            <div class="uk-navbar-left">
        
                <a class="uk-navbar-item uk-logo" href="#">GetBible</a>
        
               <a href="#offcanvas-slide" class="uk-navbar-item uk-search uk-search-default" uk-toggle><span  uk-icon="icon: search; ratio:2"></span></a>

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
                                                <button class="uk-button uk-button-default uk-button-small">All</button>
                                                <button class="uk-button uk-button-default uk-button-small">Any</button>
                                                <button class="uk-button uk-button-default uk-button-small">Phrase</button>
                                            </div>
                                        </div>
                                         <div class="uk-margin">
                                            <div class="uk-button-group">
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                            </div>
                                        </div>
                                         <div class="uk-margin">
                                            <div class="uk-button-group">
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                            </div>
                                        </div>
                                         <div class="uk-margin">
                                            <div class="uk-button-group">
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                                <button class="uk-button uk-button-default uk-button-small">Button</button>
                                                <!-- <button class="uk-button uk-button-default">Button</button> -->
                                            </div>
                                        </div>
                                    </div>
                            </div>

                        </div>
                    </div>
                    
                <!-- <span class="uk-label uk-label-primary"><span class="uk-badge uk-badge-danger">{{ num_of_tr}} </span>Translations Available</span> -->
        
            </div>
            <a class="uk-navbar-item uk-position-center-right" href="#modal-sections" uk-toggle><span  uk-icon="icon: cog; ratio:2"></span></a>

            <div id="modal-sections" uk-modal>
                <div class="uk-modal-dialog">
                    <button class="uk-modal-close-default" type="button" uk-close></button>
                    <div class="uk-modal-header">
                        <h2 class="uk-modal-title">Settings</h2>
                    </div>
                    <div class="uk-modal-body">
                         <div class="uk-margin">
                             <h3>Saved Translations</h3>
                              <div>
                                    <ul class="uk-list uk-list-large uk-list-divider">
                                        <li
                                        v-for="(tr,i) in savedTranslations" 
                                        :key="i"
                                        ><div><span>{{tr["language"]?`(${tr["language"]})`:null}} {{tr['translation']}}</span> 
                                        {{" "}}<a @click="remove(tr.abbreviation)" class="uk-position-center-right uk-position-relative"><span   uk-icon="icon: minus-circle;"></span></a>
                                        </div> </li> 
                                        <li v-if="!savedTranslations.length">No saved translation</li>
                                        
                                        <li>Add
                                            <div uk-form-custom="target: > * > span:first-child">
                                <select v-model="translation">
                                    <option selected value="Add Translation...">Add Translation...</option>
                                    <option 
                                    v-for="(tr,i) in Object.keys(translations)" 
                                    :key="i"
                                    :value="tr"
                                    >{{translations[tr]["language"]?`(${translations[tr]["language"]})`:null}} {{translations[tr]['translation']}}
                                    </option>
                                </select>
                                <button class="uk-button uk-button-default" type="button" tabindex="-1">
                                    <span></span>
                                    <span uk-icon="icon: chevron-down"></span>
                                </button>
                            </div>
                            <a @click="add(translations[translation])" :class="{disabled:!translations[translation]}"><span  uk-icon="icon: plus-circle; ratio:2"></span></a>
                                        </li>
                                    </ul>
                                    
                                </div>
                            
                        </div>
                    </div>
                    <div class="uk-modal-footer uk-text-right">
                        <button class="uk-button uk-button-default uk-modal-close" type="button">Cancel</button>
                        <button class="uk-button uk-button-primary" @click="saveSettings()" type="button">Save</button>
                    </div>  
                </div>
            </div>
            
        </nav>
</template>
<script>
import UIkit from 'uikit';

export default {
    data: () => {
        return {
            translation: 'Add Translation...',
            translations: {},
            
        }
    },
    computed: {
        savedTranslations() {
            // let o = {}
            // let counter = 0
            // for(const tr in this.translations){
            //     if(counter>2)
            //     break;
            //     o = {...o, [tr]:this.translations[tr]}
            //     counter +=1
            //     // Object.assign({}, o,{[tr]: this.translations[tr]})
            // }
            // console.log(o);
            return this.$store.state.settings.savedTr;
        }
    },
    methods: {
        add(tr){
            if(!tr) return;
            this.$store.dispatch('add', tr)
        },
        remove(tr){
            this.$store.dispatch('remove', tr)
        },
        saveSettings(){
            this.$store.commit('set_settings', this.$store.state.settings)
            UIkit.modal('#modal-sections').hide()
        }
    },
    async created(){
                let config = {
                    headers: {'Access-Control-Allow-Origin': '*'}
                };
                let response = await fetch(`https://getbible.net/v2/translations.json`,config)
                    .catch(function(err) { this.translations = err });

                if(!response)
                    return;
                    
                let data = await response.json().catch(err => {console.log(err);})

                if(!data) 
                    return;

                this.translations = data

                
            }
}
</script>