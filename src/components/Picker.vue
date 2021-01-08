<template>
  <div>
    <!-- <a href="" uk-marker>
        <input v-model="primary" type="color" name="" id="">
    </a>
    <a href="" uk-marker>
        <input v-model="secondary"  type="color" name="" id="">
    </a> -->
   <label for="primary">Primary Color: </label>
        <input v-model="primary" type="color"  name="primary" id="primary">
   <br/>
   <label for="secondary">Secondary Color: </label>
        <input v-model="secondary"  type="color" name="secondary" id="secondary">
    
  </div>
</template>

<script>
import {dispatch} from 'vuex'
export default {
    data(){
        return {
            primary: '#55828b',
            secondary: '#fed18c'
        }
    },
    methods: {
        updatePrimary(){
            dispatch('primary', this.primary) 
        },
        updateSecondary(){
            dispatch('secondary', this.secondary) 
        }
    }
}
</script>

<style>

</style>