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
  // Browser chrome follows the chosen theme, not only the system (the media-scoped metas cover no-JS).
  function wireThemeColor() {
    var metas = document.querySelectorAll('meta[name="theme-color"]');
    var root = document.documentElement;
    var sync = function () {
      var canvas = getComputedStyle(root).getPropertyValue("--canvas").trim();
      if (canvas) for (var i = 0; i < metas.length; i++) metas[i].setAttribute("content", canvas);
    };
    if (window.MutationObserver) new MutationObserver(sync).observe(root, { attributes: true, attributeFilter: ["data-theme"] });
    sync();
  }
  function apply(choice) {
    document.documentElement.dataset.theme = resolveTheme(choice, prefersDark());
  }

  // Radius that covers the whole viewport from (x, y): the wash's final circle.
  function washRadius(x, y, w, h) {
    return Math.ceil(Math.hypot(Math.max(x, w - x), Math.max(y, h - y)));
  }
  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }
  // The new theme washes in as a circle growing from the control that chose it (View Transitions).
  // No API: instant. Reduced motion: the browser's crossfade, shortened in theme.css.
  // A second click skips the running wash: every pending update applies the latest choice, and only
  // the latest wash clears the wash classes.
  var washes = 0, latest = null;
  function applyWithWash(choice, origin) {
    var doc = document, root = doc.documentElement;
    latest = choice;
    if (!doc.startViewTransition || root.dataset.theme === resolveTheme(choice, prefersDark())) { apply(choice); return; }
    var reduce = reducedMotion(), wash = ++washes;
    root.classList.add("theme-washing");
    root.classList.toggle("theme-wash", !reduce && !!origin);
    var done = function () { if (wash === washes) root.classList.remove("theme-washing", "theme-wash"); };
    var vt;
    try { vt = doc.startViewTransition(function () { apply(latest); }); }
    catch (e) { apply(choice); done(); return; }
    vt.finished.then(done, done);
    if (reduce || !origin) return;
    vt.ready.then(function () {
      var r = washRadius(origin.x, origin.y, window.innerWidth, window.innerHeight);
      var at = " at " + origin.x + "px " + origin.y + "px)";
      root.animate({ clipPath: ["circle(0px" + at, "circle(" + r + "px" + at] },
        { duration: 560, easing: "cubic-bezier(.16, 1, .3, 1)", pseudoElement: "::view-transition-new(root)" });
    }, function () { /* transition skipped: the theme is already applied */ });
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
    function set(next, origin) {
      choice = next;
      writeChoice(storage, choice);
      sync();
      applyWithWash(choice, origin);
    }
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener("click", function (e) {
        var r = e.currentTarget.getBoundingClientRect();
        set(e.currentTarget.getAttribute("data-theme-choice"), { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
      });
    }
    if (window.matchMedia) {
      var mq = window.matchMedia("(prefers-color-scheme: dark)");
      var onChange = function () { if (choice === "auto") apply(choice); };
      if (mq.addEventListener) mq.addEventListener("change", onChange);
      else if (mq.addListener) mq.addListener(onChange);
    }
    sync();
    wireThemeColor();
  }

  if (typeof document !== "undefined" && typeof window !== "undefined") {
    apply(readChoice(safeStorage()));
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initThemeSwitch);
    else initThemeSwitch();
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = { STORAGE_KEY: STORAGE_KEY, CHOICES: CHOICES, resolveTheme: resolveTheme, washRadius: washRadius, readChoice: readChoice, writeChoice: writeChoice, initThemeSwitch: initThemeSwitch, wireThemeColor: wireThemeColor };
  }
})();
