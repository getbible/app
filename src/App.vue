<template>
  <div class="secondary-lighten3">
    <navbar />
    <div class="uk-container uk-animation-slide-bottom uk-margin-top">
      <selections />
      <div class="uk-container uk-container-small">
        <verses />
        <options />
      </div>
    </div>
    <div v-if="loading" id="overlay">
      <div class="uk-position-center">
        <span uk-spinner="ratio: 3"></span>
      </div>
    </div>
  </div>
</template>

<script>
// import _ from 'lodash';

import UIkit from "uikit";
import Icons from "uikit/dist/js/uikit-icons";
import { mapGetters } from "vuex";

import navbar from "./components/NavBar.vue";
import options from "./components/Options.vue";
import Selections from "./components/Selection.vue";
import Verses from "./components/Verses.vue";

UIkit.use(Icons);

export default {
  name: "App",
  components: {
    navbar,
    options,
    Selections,
    Verses,
  },
  computed: {
    ...mapGetters(["loading"]),
  },
  created() {
    this.$store.dispatch("initialise");
    console.log("Initialising");
    console.log(JSON.parse(JSON.stringify(this.$store.state)));
  },
};
</script>

<style lang="less">
@import "../node_modules/uikit/src/less/uikit.less";
@import "../node_modules/uikit/src/less/uikit.theme.less";
@global-link-color: #da7d02;
@global-background: #f5f4f4;
@primary: #55828b;
@secondary: #fed18c;
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
  color: gray;
}
.disabled:hover {
  color: gray;
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
  background-color: rgba(255, 255, 255, 0.7);
  z-index: 20000;
  cursor: pointer;
}
.less-opacity {
  background-color: rgba(255, 255, 255, 0.7);
}

.primary {
  // background-color: #813405 !important;
  // background-color: #55828b !important;
  background-color: @primary !important;
}
.secondary {
  // background-color: #f9a03f !important;
  // background-color: #87bba2 !important;
  // background-color: #fed18c !important;
  background-color: @secondary !important;
}
.tertiary {
  background-color: #d45113;
}
.secondary-lighten3 {
  background-color: rgba(224, 222, 221, 1);
}
.text-primary {
  // color: #813405 !important;
  color: #55828b !important;
}
.text-secondary {
  // color: #f9a03f !important;
  // color: #87bba2 !important;
  color: #fed18c !important;
}
.text-tertiary {
  color: #d45113;
}
.rounded {
  border-radius: 10px;
}
.rounded-bottom {
  border-bottom-left-radius: 10px;
  border-bottom-right-radius: 10px;
}
</style>
