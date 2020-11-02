<template>
<div >
  <!-- <div class="uk-overlay-default uk-position-cover">
    <div class="uk-position-center">
        <h1>Loading... Please wait...</h1>
    </div>
  </div> -->
  <navbar/>
  <div class="uk-container ">
    <selections/>
    <div class="uk-container uk-container-small">

    <options/>
    </div>
  </div>
</div>

</template>

<script>
// import _ from 'lodash';

import UIkit from 'uikit';
import Icons from 'uikit/dist/js/uikit-icons';

import navbar from './components/NavBar.vue';
import options from './components/Options.vue';
import Selections from  './components/Selection.vue'

UIkit.use(Icons);
 
export default {
  name: 'App',
  components: {
    navbar,
    options,
    Selections,
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
</style>
