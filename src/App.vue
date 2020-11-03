<template>
<div >
  <!-- <div v-if="loading" class="uk-overlay-default uk-position-cover">
    <div class="uk-position-center">
        <h1>Loading... Please wait...</h1>
    </div>
  </div> -->
  <navbar/>
  <div class="uk-container ">
    <selections/>
    <div class="uk-container uk-container-small">
      <verses/>
    <options/>

    </div>
  </div>
  <div v-if="loading" id="overlay">
    <div  class="uk-position-center less-opacity">
        <h1>Loading... Please wait.</h1>
    </div>
  </div>
</div>

</template>

<script>
// import _ from 'lodash';

import UIkit from 'uikit';
import Icons from 'uikit/dist/js/uikit-icons';
import {mapGetters} from 'vuex';

import navbar from './components/NavBar.vue';
import options from './components/Options.vue';
import Selections from  './components/Selection.vue'
import Verses from './components/Verses.vue'

UIkit.use(Icons);
 
export default {
  name: 'App',
  components: {
    navbar,
    options,
    Selections,
    Verses,
  },
  computed: {
    ...mapGetters(['loading'])
  },
  created(){
    
    this.$store.dispatch('initialise')
  //  console.log(JSON.parse(JSON.stringify(this.$store.state)));
  }
}
</script>

<style lang="less">
@import "../node_modules/uikit/src/less/uikit.less";
#app {
  font-family: Avenir, Helvetica, Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  // text-align: center;
  color: #2c3e50;
  // margin-top: 60px;
}
.disabled {
  cursor: not-allowed;
  color: gray
}
.disabled:hover {
  color:gray 
}
#overlay {
  position: fixed;
  display: block;
  width: 100%;
  height: 100%;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: rgba(255,255,255,0.7);
  z-index: 20000;
  cursor: pointer;
}
.less-opacity{
  background-color: rgba(255,255,255,0.7);
}
</style>
