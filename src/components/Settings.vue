<template>
    <div id="modal-sections" uk-modal>
            <div class="uk-modal-dialog primary text-secondary rounded-bottom">
                <button class="uk-modal-close-default" type="button" uk-close></button>
                <div class="uk-modal-header secondary ">
                    <h2 class="uk-modal-title text-primary">Settings</h2>
                </div>
                <div class="uk-modal-body">
                    <div class="uk-margin">
                        <h3 class="text-secondary">Saved Translations</h3>
                        <div>
                                <ul class="uk-list uk-list-large uk-list-divider">
                                    <li
                                    v-for="(tr,i) in saved_translations" 
                                    :key="i"
                                    ><div><span>{{tr["language"]?`(${tr["language"]})`:null}} {{tr['translation']}}</span> 
                                    {{" "}}<a @click="remove(tr.abbreviation)" class="uk-position-center-right uk-position-relative"><span  class="uk-button uk-button-danger uk-button-small" uk-icon="icon: close;"></span></a>
                                    </div> </li> 
                                    <li v-if="!saved_translations.length>0">No saved translation</li>
                                    
                                    <li><b>Add: </b>
                                        <div uk-form-custom="target: > * > span:first-child">
                            <select class=" primary text-secondary" v-model="translation">
                                <option class="primary text-secondary" selected value="Add Translation...">Add Translation...</option>
                                <option 
                                class="primary text-secondary"
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
                        <a @click="add(translations[translation])" :class="{disabled:!translations[translation]}"><span class="uk-button uk-button-primary" uk-icon="icon: plus;"></span></a>
                                    </li>
                                </ul>
                                
                            </div>
                        
                    </div>
                </div>
                    <!-- <div class="uk-modal-footer uk-text-right">
                    <button class="uk-button uk-button-default uk-modal-close" type="button">Cancel</button>
                    <button class="uk-button uk-button-primary" @click="saveSettings()" type="button">Save</button>
                </div>  -->
            </div>
    </div>
</template>

<script>
import UIkit from 'uikit';
import {mapGetters} from 'vuex';
import getbible from '../api/getbible_v2_api';

export default {
    data: () => {
        return {
            translation: 'Add Translation...',
            translations:{}
        }
    },
    computed: {
        // saved_translations() {
        //     // console.log(this.$store.state.saved_translations[0]);
        //     return this.$store.state.saved_translations;
        // },
       ...mapGetters(['book_name', 'chapter', 'saved_translations'])
        
    },
    methods: {
        add(tr){
            if(!tr) return;
            let payload = {
                abbreviation: tr.abbreviation,
                saved_translations: {
                    name: 'saved_translations',
                    putObj: tr
                }
            }
            this.$store.dispatch('add', payload)
        },
        remove(abbr){
           let payload = {
            translation:{
                name: 'translations',
                keyPath: abbr
            },
            saved_translations:{
                name: 'saved_translations',
                keyPath: abbr
            }
        }
            this.$store.dispatch('remove', payload)
        },
        saveSettings(){
            this.$store.commit('save_settings', this.$store.state.saved_translations)
            UIkit.modal('#modal-sections').hide()
        }
    },
    async created(){
               
                let response = await getbible.get_translations()
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

<style lang="stylus" scoped>

</style>