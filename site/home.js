/* Landing page behaviour: transcript timestamps, reading fonts, Homebrew copy, nav border, and the
   authored motion ("the brief writes itself", the Ask stream, the record demo, ticking off actions).
   Every animation starts from content that is already visible in the HTML: home.js only hides what it
   is about to reveal, inside a Web Animation, and only when reduced motion is off.
   Classic script (loaded with defer); pure helpers are also exported for node tests. Themes live in theme.js. */
(function () {
  "use strict";
  var BREW = "brew install Arc86/dbrief/dbrief";
  var EASE = "cubic-bezier(.16, 1, .3, 1)";
  var DEMO_LIMIT_S = 60;

  // ---------- pure helpers (tested) ----------

  // Index of the transcript turn whose timestamp equals ts, or -1.
  function turnForTimestamp(ts, turns) {
    for (var i = 0; i < turns.length; i++) if (turns[i].t === ts) return i;
    return -1;
  }

  // Seconds to the app's clock: "00:07", "01:00", "1:02:03".
  function formatElapsed(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
    var two = function (n) { return (n < 10 ? "0" : "") + n; };
    return (h ? h + ":" : "") + two(m) + ":" + two(r);
  }

  // Splits text into words that keep their trailing space, so joining them gives the text back.
  function splitWords(text) {
    if (!text) return [];
    var words = text.match(/\s*\S+\s*/g);
    return words || [text];
  }

  // "N unfinished · M completed" for a list of done flags.
  function actionSummary(doneFlags) {
    var completed = 0;
    for (var i = 0; i < doneFlags.length; i++) if (doneFlags[i]) completed++;
    var unfinished = doneFlags.length - completed;
    return { unfinished: unfinished, completed: completed, text: unfinished + " unfinished · " + completed + " completed" };
  }

  // Clip-path keyframes that write an element line by line: each line wipes left to right, top to bottom.
  // lines: [{ top, bottom, right }] in px relative to the element; right is the line's ink width.
  // Returns WAAPI keyframes plus the total duration in ms.
  function lineRevealFrames(lines, width, msPerFullLine) {
    var n = lines.length, frames = [], total = 0, spans = [];
    if (!n || !width) return { frames: [], duration: 0 };
    for (var i = 0; i < n; i++) {
      var ms = 40 + msPerFullLine * Math.min(1, Math.max(0, lines[i].right) / width);
      spans.push(ms);
      total += ms;
    }
    var poly = function (k, x) {
      var t = k === 0 ? 0 : lines[k - 1].bottom, b = lines[k].bottom;
      return "polygon(0px 0px, 100% 0px, 100% " + t + "px, " + x + " " + t + "px, " + x + " " + b + "px, 0px " + b + "px)";
    };
    var at = 0;
    for (var k = 0; k < n; k++) {
      frames.push({ offset: at / total, clipPath: poly(k, "0px"), easing: EASE });
      at += spans[k];
      frames.push({ offset: k < n - 1 ? at / total - 0.0001 : 1, clipPath: poly(k, Math.ceil(lines[k].right) + 2 + "px") });
    }
    return { frames: frames, duration: total };
  }

  // ---------- browser plumbing ----------

  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }
  function canAnimate() {
    return typeof Element !== "undefined" && typeof Element.prototype.animate === "function" && !reducedMotion();
  }
  function shown(el) { return !!(el && el.getClientRects().length); }
  function inView(el) {
    var r = el.getBoundingClientRect();
    return r.bottom > 0 && r.top < window.innerHeight;
  }
  function token(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

  // Measures an element's line boxes from its text.
  function measureLines(el) {
    var box = el.getBoundingClientRect(), range = document.createRange();
    range.selectNodeContents(el);
    var rects = Array.prototype.slice.call(range.getClientRects())
      .filter(function (r) { return r.width > 0 && r.height > 0; })
      .sort(function (a, b) { return a.top - b.top; });
    var lines = [];
    rects.forEach(function (r) {
      var top = r.top - box.top, bottom = r.bottom - box.top, right = r.right - box.left;
      var last = lines[lines.length - 1];
      if (last && top < last.bottom - 2) { last.bottom = Math.max(last.bottom, bottom); last.right = Math.max(last.right, right); }
      else lines.push({ top: top, bottom: bottom, right: right });
    });
    if (!lines.length) lines.push({ top: 0, bottom: box.height, right: box.width });
    lines[lines.length - 1].bottom = Math.max(lines[lines.length - 1].bottom, box.height);
    return { lines: lines, width: box.width };
  }

  // Writes one element line by line, starting at delay; returns when it ends (ms).
  function writeLines(el, delay, msPerFullLine, anims) {
    var m = measureLines(el), f = lineRevealFrames(m.lines, m.width, msPerFullLine);
    if (!f.duration) return delay;
    anims.push(el.animate(f.frames, { duration: f.duration, delay: delay, fill: "backwards" }));
    return delay + f.duration;
  }

  // Something arriving (a chat bubble, a row): fades and settles up into place.
  function arrive(el, delay, ms, anims, from) {
    anims.push(el.animate([
      { opacity: 0, transform: from || "translateY(6px)" },
      { opacity: 1, transform: "none" }
    ], { duration: ms, delay: delay, easing: EASE, fill: "backwards" }));
    return delay + ms;
  }

  // Streams an answer word by word. The words are wrapped in spans only while it runs; links (timestamps)
  // stream as one word. Returns { end, links }.
  function streamWords(el, delay, msPerWord, anims, onDone) {
    var original = Array.prototype.slice.call(el.childNodes), units = [], frag = document.createDocumentFragment();
    original.forEach(function (node) {
      if (node.nodeType === 3) {
        splitWords(node.nodeValue).forEach(function (w) {
          var span = document.createElement("span");
          span.textContent = w;
          frag.appendChild(span);
          units.push(span);
        });
      } else {
        frag.appendChild(node);
        units.push(node);
      }
    });
    el.textContent = "";
    el.appendChild(frag);
    var t = delay, last = null;
    units.forEach(function (u) {
      if (!/\S/.test(u.textContent)) return;
      last = u.animate([
        { opacity: 0, filter: "blur(2px)" },
        { opacity: 1, filter: "blur(0px)" }
      ], { duration: 220, delay: t, easing: EASE, fill: "backwards" });
      anims.push(last);
      t += msPerWord;
    });
    var restore = function () { el.textContent = ""; original.forEach(function (n) { el.appendChild(n); }); if (onDone) onDone(); };
    if (last) last.finished.then(restore, restore); else restore();
    return t + 220 - msPerWord;
  }

  // A timestamp lights up briefly in the selected tint.
  function lightUp(el, delay, anims) {
    var tint = token("--selected");
    anims.push(el.animate([
      { backgroundColor: "transparent", boxShadow: "0 0 0 2px transparent" },
      { backgroundColor: tint, boxShadow: "0 0 0 2px " + tint, offset: 0.3 },
      { backgroundColor: "transparent", boxShadow: "0 0 0 2px transparent" }
    ], { duration: 700, delay: delay, easing: "ease-out" }));
    return delay + 700;
  }

  function settleAll(anims, done) {
    Promise.all(anims.map(function (a) { return a.finished.catch(function () {}); })).then(done, done);
  }

  // ---------- 1. Hero: the brief writes itself ----------

  function writeHeroBrief() {
    var stage = document.querySelector(".hero-stage"), sum = document.querySelector(".vw .sum");
    if (!stage || !sum || !canAnimate()) return;
    var run = function () {
      if (!inView(stage)) return; // deep-linked further down: the brief is simply there
      var root = document.documentElement, anims = [];
      root.classList.add("brief-writing");
      var t = 350;
      Array.prototype.forEach.call(sum.children, function (el) { t = writeLines(el, t, 90, anims); });
      var chat = document.querySelector(".vw .chat");
      if (shown(chat)) {
        var q = chat.querySelector(".q"), who = chat.querySelector(".who"), ans = chat.querySelector(".ans"), acts = chat.querySelector(".acts");
        var tq = arrive(q, t - 160, 340, anims, "translateY(8px) scale(.96)");
        arrive(who, tq - 120, 220, anims);
        var tEnd = streamWords(ans, tq, 20, anims);
        arrive(acts, tEnd - 80, 220, anims, "none");
        Array.prototype.forEach.call(ans.querySelectorAll(".ts"), function (ts) { lightUp(ts, tEnd + 40, anims); });
      }
      settleAll(anims, function () { root.classList.remove("brief-writing"); });
    };
    if (document.hidden) {
      var onVisible = function () { if (!document.hidden) { document.removeEventListener("visibilitychange", onVisible); run(); } };
      document.addEventListener("visibilitychange", onVisible);
    } else run();
  }

  // ---------- 5. Ask: the answer streams once, then its moment lights up in the transcript ----------

  function streamAskOnce(hit) {
    var chat = document.querySelector(".big-chat");
    if (!chat || !canAnimate() || !("IntersectionObserver" in window)) return;
    var kids = Array.prototype.slice.call(chat.children);
    var ans = chat.querySelector(".ans");
    var rest = kids.slice(kids.indexOf(ans) + 1).filter(function (el) { return !el.classList.contains("chips") && !el.classList.contains("comp"); });
    var anims = [], prepared = false, played = false;
    // Hide (inside paused animations) just before it scrolls in, so the text never flashes and vanishes.
    var prepare = function () {
      prepared = true;
      if (hit.turn) hit.turn.classList.remove("hit");
      var t = streamWords(ans, 0, 26, anims, null);
      var first = ans.querySelector(".ts");
      if (first) lightUp(first, t + 60, anims);
      // An empty effect is the timer for the transcript highlight, so it pauses and plays with the rest.
      var marker = new Animation(new KeyframeEffect(null, null, t + 120));
      marker.finished.then(function () { if (hit.turn && !hit.moved) hit.turn.classList.add("hit"); }, function () {});
      anims.push(marker);
      t = arrive(rest[0], t + 40, 220, anims, "none");
      var q2 = rest[1], who2 = rest[2], ans2 = rest[3], acts2 = rest[4];
      if (q2 && who2 && ans2) {
        var tq = arrive(q2, t + 260, 340, anims, "translateY(8px) scale(.96)");
        arrive(who2, tq - 120, 220, anims);
        var t2 = streamWords(ans2, tq, 26, anims, null);
        if (acts2) arrive(acts2, t2 - 80, 220, anims, "none");
      }
      anims.forEach(function (a) { a.pause(); a.currentTime = 0; });
    };
    var play = function () {
      if (played) return;
      played = true;
      anims.forEach(function (a) { a.play(); });
    };
    var near = new IntersectionObserver(function (entries) {
      if (entries.some(function (e) { return e.isIntersecting; })) { near.disconnect(); if (!prepared) prepare(); }
    }, { rootMargin: "0px 0px 40% 0px" });
    var seen = new IntersectionObserver(function (entries) {
      if (entries.some(function (e) { return e.isIntersecting; })) { seen.disconnect(); if (!prepared) prepare(); play(); }
    }, { threshold: 0.3 });
    near.observe(chat);
    seen.observe(chat);
  }

  function wireTimestamps() {
    var turns = Array.prototype.slice.call(document.querySelectorAll(".turn[data-t]"));
    var model = turns.map(function (n) { return { t: n.getAttribute("data-t") }; });
    var hit = { turn: document.querySelector(".turn.hit"), moved: false };
    document.querySelectorAll("[data-jump]").forEach(function (link) {
      link.addEventListener("click", function (e) {
        e.preventDefault();
        var i = turnForTimestamp(link.getAttribute("data-jump"), model);
        if (i < 0) return;
        hit.moved = true;
        turns.forEach(function (t, j) { t.classList.toggle("hit", j === i); });
        turns[i].scrollIntoView({ block: "nearest", behavior: reducedMotion() ? "auto" : "smooth" });
        turns[i].focus({ preventScroll: true });
      });
    });
    return hit;
  }

  // ---------- 3. Record demo: a pretend recording in the menu panel ----------

  function wireRecordDemo() {
    var desk = document.querySelector(".desk");
    if (!desk) return;
    var idleUI = desk.querySelector(".idle-ui"), recUI = desk.querySelector(".rec-ui");
    var mbIdle = desk.querySelector(".mb-idle"), mbRec = desk.querySelector(".mb-rec");
    var startBtn = desk.querySelector('[data-rec="start"]'), stopBtn = desk.querySelector('[data-rec="stop"]');
    var call = desk.querySelector(".callcard"), live = document.getElementById("rec-live");
    var times = desk.querySelectorAll("[data-rec-time]"), bars = desk.querySelectorAll(".meter i");
    if (!idleUI || !recUI || !startBtn || !stopBtn) return;
    var BASE = [8, 14, 18, 12, 7], SHAPE = [0.55, 0.85, 1, 0.8, 0.5], MAX = 18;
    var recording = false, startedAt = 0, visible = true, ticker = null, meter = null, autoStop = null, callTimer = null, callAnim = null, callHidden = false, level = 0.5;

    var say = function (msg) { if (live) live.textContent = msg; };
    var setTime = function (text) { for (var i = 0; i < times.length; i++) times[i].textContent = text; };
    var tick = function () {
      var s = (Date.now() - startedAt) / 1000;
      setTime(formatElapsed(s));
      if (s >= DEMO_LIMIT_S) stop(false);
    };
    // Speech-like level: a wandering envelope, each bar jittered around the logo's shape.
    var meterStep = function () {
      level = Math.min(1, Math.max(0.15, level + (Math.random() - 0.5) * 0.5));
      if (Math.random() < 0.08) level = 0.15;
      for (var i = 0; i < bars.length; i++) {
        var frac = Math.min(1, Math.max(0.3, level * SHAPE[i] * (0.7 + Math.random() * 0.6) + 0.15));
        bars[i].style.transform = "scaleY(" + (frac * MAX / BASE[i]).toFixed(3) + ")";
      }
    };
    var halt = function () {
      clearInterval(ticker); clearInterval(meter); ticker = meter = null;
      desk.classList.toggle("is-held", recording);
    };
    var resume = function () {
      if (!recording || !visible || document.hidden) { halt(); return; }
      desk.classList.remove("is-held");
      tick();
      if (!ticker) ticker = setInterval(tick, 250);
      if (!meter && !reducedMotion()) { meterStep(); meter = setInterval(meterStep, 110); }
    };
    var hideCall = function () {
      clearTimeout(callTimer);
      if (!call || callHidden) return;
      callHidden = true;
      call.inert = true;
      if (callAnim) callAnim.cancel();
      callAnim = call.animate([
        { opacity: 1, transform: "none" },
        { opacity: 0, transform: reducedMotion() ? "none" : "translateY(8px) scale(.97)" }
      ], { duration: reducedMotion() ? 120 : 160, easing: "ease-in", fill: "forwards" });
    };
    var showCall = function () {
      if (!call || recording || !callHidden) return;
      callHidden = false;
      call.inert = false;
      if (callAnim) callAnim.cancel();
      callAnim = call.animate([
        { opacity: 0, transform: reducedMotion() ? "none" : "translateY(10px) scale(.97)" },
        { opacity: 1, transform: "none" }
      ], { duration: reducedMotion() ? 120 : 320, easing: EASE });
    };
    var focusIn = function (el) { return el && el.contains(document.activeElement); };

    function start() {
      if (recording) return;
      var hadFocus = focusIn(desk);
      recording = true;
      startedAt = Date.now();
      setTime("00:00");
      desk.classList.add("is-rec");
      idleUI.hidden = true; recUI.hidden = false;
      if (mbIdle) mbIdle.hidden = true;
      if (mbRec) mbRec.hidden = false;
      hideCall();
      if (hadFocus) stopBtn.focus();
      say("Recording example started");
      autoStop = setTimeout(function () { stop(false); }, DEMO_LIMIT_S * 1000 + 300);
      resume();
    }
    function stop(userAction) {
      if (!recording) return;
      var hadFocus = focusIn(recUI);
      recording = false;
      clearTimeout(autoStop);
      halt();
      desk.classList.remove("is-rec", "is-held");
      for (var i = 0; i < bars.length; i++) bars[i].style.transform = "";
      idleUI.hidden = false; recUI.hidden = true;
      if (mbIdle) mbIdle.hidden = false;
      if (mbRec) mbRec.hidden = true;
      setTime("00:00");
      if (hadFocus) startBtn.focus();
      say(userAction ? "Recording example stopped" : "Recording example stopped after a minute");
      callTimer = setTimeout(showCall, 1200);
    }

    startBtn.addEventListener("click", start);
    stopBtn.addEventListener("click", function () { stop(true); });
    desk.querySelectorAll("[data-call]").forEach(function (b) {
      b.addEventListener("click", function () {
        if (b.getAttribute("data-call") === "record") { start(); return; }
        var hadFocus = focusIn(call);
        hideCall();
        if (hadFocus) startBtn.focus();
        callTimer = setTimeout(showCall, 2000);
      });
    });
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        visible = entries[entries.length - 1].isIntersecting;
        resume();
      }).observe(desk);
    }
    document.addEventListener("visibilitychange", resume);
  }

  // ---------- 4. Actions: tick them off ----------

  function wireActions() {
    var mock = document.querySelector(".actions-mock");
    if (!mock) return;
    var ticks = Array.prototype.slice.call(mock.querySelectorAll(".todo-tick"));
    var summary = mock.querySelector("[data-action-summary]"), badge = mock.querySelector("[data-unfinished]");
    ticks.forEach(function (b) {
      b.addEventListener("click", function () {
        var done = b.getAttribute("aria-pressed") !== "true";
        b.setAttribute("aria-pressed", String(done));
        b.title = done ? "Mark unfinished" : "Mark complete";
        b.closest(".todo").classList.toggle("done", done);
        var s = actionSummary(ticks.map(function (x) { return x.getAttribute("aria-pressed") === "true"; }));
        if (summary) summary.textContent = s.text;
        if (badge) badge.textContent = String(s.unfinished);
      });
    });
  }

  // ---------- 6. Reading fonts: the specimen comes into focus in the new face ----------

  function wireFonts() {
    var reader = document.getElementById("reader");
    var buttons = document.querySelectorAll("[data-font]");
    if (!reader) return;
    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        if (b.getAttribute("aria-pressed") === "true") return;
        reader.style.fontFamily = '"' + b.getAttribute("data-font") + '", var(--sys)';
        buttons.forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
        if (typeof reader.animate !== "function") return;
        var calm = reducedMotion();
        Array.prototype.forEach.call(reader.children, function (p) {
          p.animate(calm
            ? [{ opacity: 0.55 }, { opacity: 1 }]
            : [{ opacity: 0.35, filter: "blur(3px)" }, { opacity: 1, filter: "blur(0px)" }],
            { duration: calm ? 120 : 240, easing: EASE });
        });
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

  function init() {
    var hit = wireTimestamps();
    wireFonts(); wireCopy(); wireNav(); wireRecordDemo(); wireActions();
    writeHeroBrief();
    streamAskOnce(hit);
  }

  if (typeof document !== "undefined" && typeof window !== "undefined") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = {
      turnForTimestamp: turnForTimestamp, formatElapsed: formatElapsed, splitWords: splitWords,
      actionSummary: actionSummary, lineRevealFrames: lineRevealFrames, BREW: BREW
    };
  }
})();
