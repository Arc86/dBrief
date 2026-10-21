/* Landing page behaviour: transcript timestamps, reading fonts, Homebrew copy, nav border.
   Classic script (loaded with defer); also exported for node tests. Themes live in theme.js. */
(function () {
  "use strict";
  var BREW = "brew install Arc86/dbrief/dbrief";

  // Index of the transcript turn whose timestamp equals ts, or -1.
  function turnForTimestamp(ts, turns) {
    for (var i = 0; i < turns.length; i++) if (turns[i].t === ts) return i;
    return -1;
  }

  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function wireTimestamps() {
    var turns = Array.prototype.slice.call(document.querySelectorAll(".turn[data-t]"));
    var model = turns.map(function (n) { return { t: n.getAttribute("data-t") }; });
    document.querySelectorAll("[data-jump]").forEach(function (link) {
      link.addEventListener("click", function (e) {
        e.preventDefault();
        var i = turnForTimestamp(link.getAttribute("data-jump"), model);
        if (i < 0) return;
        turns.forEach(function (t, j) { t.classList.toggle("hit", j === i); });
        turns[i].scrollIntoView({ block: "nearest", behavior: reducedMotion() ? "auto" : "smooth" });
        turns[i].focus({ preventScroll: true });
      });
    });
  }

  function wireFonts() {
    var reader = document.getElementById("reader");
    var buttons = document.querySelectorAll("[data-font]");
    if (!reader) return;
    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        reader.style.fontFamily = '"' + b.getAttribute("data-font") + '", var(--sys)';
        buttons.forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
      });
    });
  }

  function wireCopy() {
    var btn = document.getElementById("brew-copy");
    if (!btn) return;
    var label = btn.querySelector("[data-label]");
    var timer;
    btn.addEventListener("click", function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(BREW).then(function () {
        label.textContent = "Copied";
        clearTimeout(timer);
        timer = setTimeout(function () { label.textContent = "Copy"; }, 2000);
      }, function () { /* clipboard refused: the command stays selectable */ });
    });
  }

  function wireNav() {
    var nav = document.getElementById("nav");
    if (!nav) return;
    var update = function () { nav.classList.toggle("scrolled", window.scrollY > 8); };
    window.addEventListener("scroll", update, { passive: true });
    update();
  }

  function init() { wireTimestamps(); wireFonts(); wireCopy(); wireNav(); }

  if (typeof document !== "undefined" && typeof window !== "undefined") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = { turnForTimestamp: turnForTimestamp, BREW: BREW };
  }
})();
