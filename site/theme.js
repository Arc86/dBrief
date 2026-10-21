/* Shared theme logic for the dBrief site. Classic script, loaded in <head>. */
(function () {
  "use strict";
  var STORAGE_KEY = "dbrief-theme";
  var CHOICES = ["auto", "light", "paper", "dark", "darkpaper"];

  function resolveTheme(choice, prefersDark) {
    if (choice === "light" || choice === "paper" || choice === "dark" || choice === "darkpaper") return choice;
    return prefersDark ? "dark" : "light";
  }
  function readChoice(storage) {
    try {
      var v = storage && storage.getItem(STORAGE_KEY);
      return CHOICES.indexOf(v) >= 0 ? v : "auto";
    } catch (e) { return "auto"; }
  }
  function writeChoice(storage, choice) {
    try { storage.setItem(STORAGE_KEY, choice); } catch (e) { /* storage blocked */ }
  }

  function safeStorage() {
    try { return window.localStorage; } catch (e) { return null; }
  }
  function prefersDark() {
    return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  }
  function apply(choice) {
    document.documentElement.dataset.theme = resolveTheme(choice, prefersDark());
  }

  function initThemeSwitch() {
    var storage = safeStorage();
    var choice = readChoice(storage);
    var buttons = document.querySelectorAll("[data-theme-choice]");
    function sync() {
      for (var i = 0; i < buttons.length; i++) {
        buttons[i].setAttribute("aria-pressed", String(buttons[i].getAttribute("data-theme-choice") === choice));
      }
    }
    function set(next) {
      choice = next;
      writeChoice(storage, choice);
      apply(choice);
      sync();
    }
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener("click", function (e) {
        set(e.currentTarget.getAttribute("data-theme-choice"));
      });
    }
    if (window.matchMedia) {
      var mq = window.matchMedia("(prefers-color-scheme: dark)");
      var onChange = function () { if (choice === "auto") apply(choice); };
      if (mq.addEventListener) mq.addEventListener("change", onChange);
      else if (mq.addListener) mq.addListener(onChange);
    }
    sync();
  }

  if (typeof document !== "undefined" && typeof window !== "undefined") {
    apply(readChoice(safeStorage()));
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initThemeSwitch);
    else initThemeSwitch();
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = { STORAGE_KEY: STORAGE_KEY, CHOICES: CHOICES, resolveTheme: resolveTheme, readChoice: readChoice, writeChoice: writeChoice, initThemeSwitch: initThemeSwitch };
  }
})();
