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
                                        v-for="(tr,i) in Object.keys(savedTranslations)" 
                                        :key="i"
                                        ><div><span>{{savedTranslations[tr]["language"]?`(${savedTranslations[tr]["language"]})`:null}} {{savedTranslations[tr]['translation']}}</span> <a class="uk-position-center-right uk-position-relative"><span   uk-icon="icon: minus-circle;"></span></a>
                                        </div> </li> 
                                        
                                        <li>
                                            <div uk-form-custom="target: > * > span:first-child">
                                <select>
                                    <option value="">Add Translation...</option>
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
                            <a><span  uk-icon="icon: plus-circle; ratio:2"></span></a>
                                        </li>
                                    </ul>
                                    
                                </div>
                            
                        </div>
                    </div>
                    <div class="uk-modal-footer uk-text-right">
                        <button class="uk-button uk-button-default uk-modal-close" type="button">Cancel</button>
                        <button class="uk-button uk-button-primary" type="button">Save</button>
                    </div>  
                </div>
            </div>
            
        </nav>
</template>
<script>
export default {
    data: () => {
        return {
            translations: {},
            
        }
    },
    computed: {
        savedTranslations() {
            let o = {}
            let counter = 0
            for(const tr in this.translations){
                if(counter>2)
                break;
                o = {...o, [tr]:this.translations[tr]}
                counter +=1
                // Object.assign({}, o,{[tr]: this.translations[tr]})
            }
            console.log(o);
            return o
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