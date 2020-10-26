<template>
<div>
  <navbar/>
  <div class="uk-container">
    <options/>
  </div>
</div>
</template>

<script>
// import _ from 'lodash';

import UIkit from 'uikit';
import Icons from 'uikit/dist/js/uikit-icons';

import navbar from './components/NavBar.vue';
import options from './components/Options.vue';

UIkit.use(Icons);
 
export default {
  name: 'App',
  components: {
    navbar,
    options
  },
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
