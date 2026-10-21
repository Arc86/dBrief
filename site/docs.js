/* dBrief docs — client-side markdown renderer + nav.
   Docs are stored as plain .md files in /docs/, served from the same origin.
   URL: docs.html#getting-started/quick-start
*/

(() => {
  // Sidebar structure — mirrors the site/docs/ folder exactly.
  // Order matters: this is the order shown in the sidebar.
  const NAV = [
    {
      title: "Getting Started",
      items: [
        { slug: "getting-started/installation",  title: "Installation" },
        { slug: "getting-started/quick-start",   title: "Quick Start" },
        { slug: "getting-started/onboarding",    title: "Onboarding" },
      ],
    },
    {
      title: "Recording",
      items: [
        { slug: "recording/recording-basics", title: "Recording Basics" },
        { slug: "recording/audio-sources",   title: "Audio Sources" },
        { slug: "recording/mini-player",     title: "Floating Recording Window" },
        { slug: "recording/call-detection",  title: "Call Detection" },
        { slug: "recording/calendar",        title: "Calendar Integration" },
        { slug: "recording/youtube-urls",    title: "Video & YouTube URLs" },
        { slug: "recording/watched-folders", title: "Import & Watched Folders" },
      ],
    },
    {
      title: "Transcription",
      items: [
        { slug: "transcription/transcription-overview", title: "Overview" },
        { slug: "transcription/apple-speech",           title: "Apple Speech" },
        { slug: "transcription/local-whisper",          title: "Local Whisper" },
        { slug: "transcription/parakeet",               title: "Parakeet (Local)" },
        { slug: "transcription/remote-endpoint",        title: "Remote Endpoint" },
        { slug: "transcription/live-transcription",     title: "Live Transcription" },
      ],
    },
    {
      title: "AI Analysis",
      items: [
        { slug: "ai-analysis/ai-overview",        title: "Overview" },
        { slug: "ai-analysis/apple-intelligence", title: "Apple Intelligence" },
        { slug: "ai-analysis/local-gemma",        title: "Local Gemma 4" },
        { slug: "ai-analysis/local-cli",          title: "Local CLI" },
        { slug: "ai-analysis/local-vs-remote",    title: "Local vs Remote" },
        { slug: "ai-analysis/transcript-chat",    title: "Ask dBrief AI (Chat)" },
        { slug: "ai-analysis/spoken-summary",     title: "Spoken Summary" },
        { slug: "ai-analysis/remote-endpoint",    title: "Remote Endpoint" },
      ],
    },
    {
      title: "Integrations",
      items: [
        { slug: "integrations/integrations-overview", title: "Overview" },
        { slug: "integrations/obsidian",              title: "Obsidian" },
        { slug: "integrations/apple-notes",           title: "Apple Notes" },
        { slug: "integrations/apple-reminders",       title: "Apple Reminders" },
        { slug: "integrations/webhook",               title: "Webhook" },
        { slug: "integrations/todoist",               title: "Todoist" },
        { slug: "integrations/notion",                title: "Notion" },
        { slug: "integrations/ticktick",              title: "TickTick" },
        { slug: "integrations/claude-cli-calendar",   title: "Claude CLI Calendar" },
        { slug: "integrations/other-integrations",    title: "Other Integrations" },
      ],
    },
    {
      title: "Profiles",
      items: [
        { slug: "profiles/what-are-profiles", title: "What Are Profiles?" },
        { slug: "profiles/using-profiles",    title: "Using Profiles" },
        { slug: "profiles/import-export",     title: "Import & Export" },
      ],
    },
    {
      title: "History",
      items: [
        { slug: "history/recording-history", title: "Recording History" },
        { slug: "history/transcript-viewer", title: "Transcript Viewer" },
        { slug: "history/focus-reader",      title: "Focus Reader" },
        { slug: "history/queue-recovery", title: "Queue & Recovery" },
        { slug: "history/reprocessing", title: "Reprocessing" },
        { slug: "history/voice-library",     title: "Voice Library" },
      ],
    },
    {
      title: "Reference",
      items: [
        { slug: "reference/keyboard-shortcuts", title: "Keyboard Shortcuts" },
        { slug: "reference/language-and-accessibility", title: "Language & Accessibility" },
        { slug: "reference/appearance",         title: "Appearance & Fonts" },
        { slug: "reference/permissions",        title: "Permissions" },
        { slug: "reference/file-locations",     title: "File Locations" },
        { slug: "reference/privacy-receipts", title: "Privacy Receipts" },
        { slug: "reference/benchmark",          title: "Performance" },
      ],
    },
  ];

  // Flat lookup table for prev/next + 404 detection.
  const FLAT = [];
  NAV.forEach((section) => {
    section.items.forEach((item) => FLAT.push({ ...item, section: section.title }));
  });
  const bySlug = Object.fromEntries(FLAT.map((it) => [it.slug, it]));

  // ---- DOM refs ----
  const proseEl    = document.getElementById("docs-prose");
  const navEl      = document.getElementById("docs-nav");
  const searchEl   = document.getElementById("docs-search");
  const breadcrumb = document.getElementById("docs-breadcrumb");
  const pagerEl    = document.getElementById("docs-pager");
  const menuBtn    = document.getElementById("docs-menu-toggle");
  const sidebar    = document.getElementById("docs-sidebar");

  // ---- Marked config ----
  if (window.marked) {
    window.marked.setOptions({
      gfm: true,
      breaks: false,
    });
  }

  // ---- Build sidebar ----
  function buildSidebar(filter = "") {
    const q = filter.trim().toLowerCase();
    navEl.innerHTML = "";
    let visibleSections = 0;

    NAV.forEach((section) => {
      const items = section.items.filter(
        (it) => !q || it.title.toLowerCase().includes(q) || it.slug.toLowerCase().includes(q)
      );
      if (items.length === 0) return;
      visibleSections++;

      const sec = document.createElement("div");
      sec.className = "docs-nav-section";
      sec.innerHTML = `<div class="docs-nav-heading">${escapeHtml(section.title)}</div>`;
      const ul = document.createElement("ul");
      ul.className = "docs-nav-list";
      items.forEach((it) => {
        const li = document.createElement("li");
        const a = document.createElement("a");
        a.href = "#" + it.slug;
        a.textContent = it.title;
        a.dataset.slug = it.slug;
        ul.appendChild(li);
        li.appendChild(a);
      });
      sec.appendChild(ul);
      navEl.appendChild(sec);
    });

    if (visibleSections === 0) {
      navEl.innerHTML = `<div class="docs-nav-empty">No matches for &ldquo;${escapeHtml(filter)}&rdquo;</div>`;
    }
  }

  // ---- Active link highlighting ----
  function highlight(slug) {
    let current = null;
    navEl.querySelectorAll("a").forEach((a) => {
      const active = a.dataset.slug === slug;
      a.classList.toggle("is-active", active);
      if (active) { a.setAttribute("aria-current", "page"); current = a; }
      else a.removeAttribute("aria-current");
    });
    // Keep the current page visible in the sidebar's own scroll area (never scrolls the window).
    if (current && sidebar.scrollHeight > sidebar.clientHeight) {
      const y = current.offsetTop;
      if (y < sidebar.scrollTop || y + current.offsetHeight > sidebar.scrollTop + sidebar.clientHeight) {
        sidebar.scrollTop = y - sidebar.clientHeight / 3;
      }
    }
  }

  // ---- Render a doc ----
  let loadVersion = 0;
  let shownSlug = null; // the page currently rendered, so an anchor on it only scrolls
  async function load(slug, anchor = "", focusTitle = false) {
    const version = ++loadVersion;
    if (!slug) {
      // Default: load the index
      slug = "index";
    }
    const url = `docs/${slug}.md`;
    shownSlug = null;
    proseEl.innerHTML = `
      <div class="docs-loading" role="status">
        <span class="docs-spinner" aria-hidden="true"></span>
        <span>Loading…</span>
      </div>`;
    breadcrumb.innerHTML = "";
    pagerEl.innerHTML = "";

    try {
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) throw new Error(res.status);
      const md = await res.text();
      if (version !== loadVersion) return;
      render(slug, md, anchor);
      shownSlug = slug;
    } catch (err) {
      if (version !== loadVersion) return;
      document.title = "Page not found | dBrief Docs";
      breadcrumb.innerHTML = `<a href="#index">Docs</a><span class="docs-crumb-sep" aria-hidden="true">/</span><span>Page not found</span>`;
      highlight(null);
      proseEl.innerHTML = `
        <div class="docs-empty">
          <h1>Page not found</h1>
          <p>We couldn&rsquo;t find <code>${escapeHtml(slug)}.md</code>.</p>
          <p>Try the <a href="#index">docs home</a> or use the sidebar to find what you need.</p>
        </div>`;
      window.scrollTo({ top: 0, behavior: "instant" });
    }
    // Opened from the drawer, which now closes: continue on the new page instead of losing focus.
    if (focusTitle) {
      const title = proseEl.querySelector("h1");
      if (title) { title.tabIndex = -1; title.focus({ preventScroll: true }); }
    }
  }

  function render(slug, md, anchor) {
    // Strip the leading H1 — we re-add it as the page title for nicer styling.
    let body = md.replace(/^\s*#\s+.+\n+/, "");

    // Resolve Markdown paths relative to this document, preserving section links.
    body = body.replace(/\]\(([^)]+)\)/g, (full, target) => {
      if (/^[a-z][a-z\d+.-]*:/i.test(target) || target.startsWith("/")) return full;
      if (target.startsWith("#")) return `](#${slug}${target})`;
      const [path, section] = target.split("#");
      if (!path.endsWith(".md")) return full;
      const stack = slug.split("/").slice(0, -1);
      for (const part of path.replace(/\.md$/, "").split("/")) {
        if (part === "..") stack.pop();
        else if (part && part !== ".") stack.push(part);
      }
      return `](#${stack.join("/")}${section ? "#" + section : ""})`;
    });

    const html = window.marked.parse(body);
    proseEl.innerHTML = `<div class="prose">${html}</div>`;

    // Build breadcrumb + title
    const meta = bySlug[slug];
    const crumbs = [
      { label: "Docs", href: "#index" },
    ];
    if (meta) {
      crumbs.push({ label: meta.section, href: null });
      crumbs.push({ label: meta.title, href: null });
    } else if (slug === "index") {
      crumbs.push({ label: "Overview", href: null });
    }
    breadcrumb.innerHTML = crumbs
      .map((c, i) => {
        const sep = i < crumbs.length - 1 ? `<span class="docs-crumb-sep" aria-hidden="true">/</span>` : "";
        return c.href
          ? `<a href="${c.href}">${escapeHtml(c.label)}</a>${sep}`
          : `<span>${escapeHtml(c.label)}</span>${sep}`;
      })
      .join("");

    // Inject H1 title at the top if we stripped one
    const h1Match = md.match(/^\s*#\s+(.+)$/m);
    if (h1Match) {
      const titleEl = document.createElement("h1");
      titleEl.className = "docs-title";
      titleEl.tabIndex = -1; // focus target after navigating from the drawer
      titleEl.textContent = h1Match[1].trim();
      proseEl.querySelector(".prose").prepend(titleEl);
    }

    document.title = slug === "index"
      ? "Docs | dBrief"
      : `${h1Match ? h1Match[1].trim() : "Docs"} | dBrief Docs`;
    const headingIds = new Set();
    proseEl.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((heading) => {
      const base = heading.textContent.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s+/g, "-");
      let id = base;
      let suffix = 1;
      while (headingIds.has(id)) id = `${base}-${suffix++}`;
      headingIds.add(id);
      heading.id = id;
    });

    // Prev / next pager
    const idx = FLAT.findIndex((it) => it.slug === slug);
    if (idx >= 0) {
      const prev = idx > 0 ? FLAT[idx - 1] : null;
      const next = idx < FLAT.length - 1 ? FLAT[idx + 1] : null;
      pagerEl.innerHTML = `
        ${prev ? `<a class="docs-pager-prev" href="#${prev.slug}" rel="prev"><span class="docs-pager-label">Previous</span><span class="docs-pager-title"><svg class="ico" aria-hidden="true"><use href="#i-chev-left"/></svg>${escapeHtml(prev.title)}</span></a>` : `<span></span>`}
        ${next ? `<a class="docs-pager-next" href="#${next.slug}" rel="next"><span class="docs-pager-label">Next</span><span class="docs-pager-title">${escapeHtml(next.title)}<svg class="ico" aria-hidden="true"><use href="#i-chev-right"/></svg></span></a>` : `<span></span>`}
      `;
    } else {
      pagerEl.innerHTML = "";
    }

    // Highlight active link
    highlight(slug);

    // Scroll to top
    document.querySelector(".docs-content")?.scrollTo({ top: 0, behavior: "instant" });
    window.scrollTo({ top: 0, behavior: "instant" });
    if (anchor) document.getElementById(anchor)?.scrollIntoView({ block: "start" });
  }

  // ---- Routing ----
  function getSlugFromHash() {
    const h = location.hash.replace(/^#/, "");
    return h || "index";
  }
  function onHashChange() {
    const slug = getSlugFromHash();
    const [page, anchor] = slug.split("#");
    const fromDrawer = drawerNav || (sidebar.classList.contains("is-open") && sidebar.contains(document.activeElement));
    drawerNav = false;
    // Close mobile sidebar after nav
    setDrawer(false);
    // A section of the page already shown: scroll to it, no reload.
    if (page === shownSlug && anchor && document.getElementById(anchor)) {
      document.getElementById(anchor).scrollIntoView({ block: "start" });
      return;
    }
    load(page, anchor, fromDrawer);
  }
  window.addEventListener("hashchange", onHashChange);

  // ---- Search ----
  searchEl.addEventListener("input", (e) => {
    buildSidebar(e.target.value);
    highlight(getSlugFromHash().split("#")[0]);
  });
  // Return opens the first match.
  searchEl.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.isComposing) return;
    const first = navEl.querySelector("a");
    if (!first) return;
    e.preventDefault();
    if (location.hash === first.getAttribute("href")) setDrawer(false);
    else location.hash = first.getAttribute("href");
    if (!sidebar.classList.contains("is-open")) first.focus();
  });

  // ---- Mobile menu ----
  // While the drawer is open the dimmed content is inert, so Tab stays inside the drawer and the toggle.
  function setDrawer(open, restoreFocus) {
    sidebar.classList.toggle("is-open", open);
    menuBtn?.setAttribute("aria-expanded", String(open));
    ["docs-prose", "docs-pager", "docs-breadcrumb"].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.inert = open;
    });
    if (open) searchEl.focus();
    else if (restoreFocus) menuBtn?.focus();
  }
  menuBtn.addEventListener("click", () => setDrawer(!sidebar.classList.contains("is-open")));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && sidebar.classList.contains("is-open")) setDrawer(false, true);
  });
  // A topic picked in the drawer closes it; focus then continues on the page it opens.
  // Clicking the current page changes no hash, so close explicitly.
  let drawerNav = false;
  navEl.addEventListener("click", (e) => {
    const link = e.target.closest("a");
    if (!link || !sidebar.classList.contains("is-open")) return;
    const samePage = link.getAttribute("href") === location.hash;
    drawerNav = !samePage;
    setDrawer(false);
    if (samePage) proseEl.querySelector("h1")?.focus({ preventScroll: true });
  });

  // ---- Helpers ----
  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // ---- Init ----
  buildSidebar();
  onHashChange();
})();
