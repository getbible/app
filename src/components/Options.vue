<template>
  <div class="uk-container">
    <div class="uk-margin" uk-margin>
      <ul class="uk-pagination" v-if="chapter">
        <li @click="prev">
          <a class="text-primary" href="#"
            ><span class="uk-margin-small-right" uk-pagination-previous></span>
            Previous Chapter</a
          >
        </li>
        <li class="uk-margin-auto-left" @click="next">
          <a class="text-primary" href="#"
            >Next Chapter<span
              class="uk-margin-small-left"
              uk-pagination-next
            ></span
          ></a>
        </li>
      </ul>
    </div>
  </div>
</template>
<script>
import _ from "lodash";
import { mapGetters } from "vuex";
import { BASE_URL, API_VERSION } from "../api/getbible_v2_api";

export default {
  components: {},
  data: function () {
    return {
      progress: 0,
      loading: false,
    };
  },
  computed: {
    translations() {
      return this.$store.state.saved_translations;
    },
    saved_translations() {
      console.log(this.$store.state.saved_translations);
      return this.$store.state.saved_translations;
    },
    ...mapGetters(["chapters", "chapter"]),
    fchapters: function () {
      if (!this.search) return this.chapter.verses;
      return this.filteredChapters;
    },
    filteredChapters() {
      return _.orderBy(
        this.chapter.verses.filter(
          (item) =>
            item.verse
              .toString()
              .toLowerCase()
              .includes(this.search.toLowerCase()) ||
            item.chapter
              .toString()
              .toLowerCase()
              .includes(this.search.toLowerCase()) ||
            item.name
              .toString()
              .toLowerCase()
              .includes(this.search.toLowerCase()) ||
            item.text.toLowerCase().includes(this.search.toLowerCase())
        ),
        "verse"
      );
    },
  },
  methods: {
    t(i) {
      return this.translations.find((t) => t.abbreviation === i);
    },
    next() {
      if (this.chapter < this.chapters.length)
        this.$store.dispatch("set_chapter", this.chapter + 1);
    },
    prev() {
      if (this.chapter > 1)
        this.$store.dispatch("set_chapter", this.chapter - 1);
    },
    async update_chapter() {
      // this.loading = true
      this.progress = 95;
      let config = {
        headers: { "Access-Control-Allow-Origin": "*" },
      };

      let url = `${BASE_URL}/${API_VERSION}/${this.translation}/${this.book}/${this.chapter_num}.json`;

      let response = await fetch(url, config).catch(function (err) {
        this.chapter = err;
        this.loading = false;
        this.message = "Error";
      });

      if (!response) return;

      this.progress = 99;
      let data = await response.json().catch((err) => {
        this.chapter = err;
        this.loading = false;
        this.message = "Error";
      });
      this.loading = false;

      if (!data) return;

      this.chapter = data;
      this.progress = 0;
    },
    async update_tr() {},
    async update_bk() {
      let config = {
        headers: { "Access-Control-Allow-Origin": "*" },
      };
      this.loading = true;
      this.progress = 25;
      this.message = "Loading...";
      let url = `${BASE_URL}/${API_VERSION}/${this.translation}/books.json`;
      fetch(url, config)
        .then((response) => response.json())
        .then((data) => {
          // console.log(data)
          this.books = data;
          this.progress = 60;
          this.update_ch();
        })
        .catch(function (err) {
          this.chapter = err;
          this.loading = false;
          this.message = "Error";
        });
    },
    async update_ch() {
      let config = {
        headers: { "Access-Control-Allow-Origin": "*" },
      };
      fetch(
        `${BASE_URL}/${API_VERSION}/${this.translation}/${this.book}/chapters.json`,
        config
      )
        .then((response) => response.json())
        .then((data) => {
          // console.log(data)
          this.chapters = data;
          this.progress = 85;
          this.update_chapter();
        })
        .catch(function (err) {
          this.chapter = err;
          this.loading = false;
          this.message = "Error";
        });
    },
  },
};
</script>