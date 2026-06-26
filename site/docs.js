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
        { slug: "recording/mini-player",     title: "Mini Player" },
        { slug: "recording/call-detection",  title: "Call Detection" },
        { slug: "recording/calendar",        title: "Calendar Integration" },
        { slug: "recording/youtube-urls",    title: "Video & YouTube URLs" },
        { slug: "recording/watched-folders", title: "Watched Folders" },
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
        { slug: "ai-analysis/transcript-chat",    title: "Transcript Chat" },
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
        { slug: "history/voice-library",     title: "Voice Library" },
      ],
    },
    {
      title: "Reference",
      items: [
        { slug: "reference/keyboard-shortcuts", title: "Keyboard Shortcuts" },
        { slug: "reference/permissions",        title: "Permissions" },
        { slug: "reference/file-locations",     title: "File Locations" },
        { slug: "reference/benchmark",          title: "Benchmark & Performance" },
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
    navEl.querySelectorAll("a").forEach((a) => {
      a.classList.toggle("is-active", a.dataset.slug === slug);
    });
  }

  // ---- Render a doc ----
  async function load(slug) {
    if (!slug) {
      // Default: load the index
      slug = "index";
    }
    const url = `docs/${slug}.md`;
    proseEl.innerHTML = `
      <div class="docs-loading">
        <div class="docs-spinner" aria-hidden="true"></div>
        <span>Loading…</span>
      </div>`;
    breadcrumb.innerHTML = "";
    pagerEl.innerHTML = "";

    try {
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) throw new Error(res.status);
      const md = await res.text();
      render(slug, md);
    } catch (err) {
      proseEl.innerHTML = `
        <div class="docs-empty">
          <h1>Page not found</h1>
          <p>We couldn&rsquo;t find <code>${escapeHtml(slug)}.md</code>.</p>
          <p>Try the <a href="#index">docs home</a> or use the sidebar to find what you need.</p>
        </div>`;
    }
  }

  function render(slug, md) {
    // Strip the leading H1 — we re-add it as the page title for nicer styling.
    let body = md.replace(/^\s*#\s+.+\n+/, "");

    // Convert .md links to in-app hash links. E.g. [Foo](apple-notes.md) → [Foo](#integrations/apple-notes)
    // We need to resolve them via the FLAT map (basename → full slug).
    const byBasename = {};
    FLAT.forEach((it) => {
      const base = it.slug.split("/").pop();
      byBasename[base] = it.slug;
    });
    byBasename["index"] = "index";
    byBasename["README"] = "index";

    body = body.replace(/\]\(([^)]+)\)/g, (full, target) => {
      // External link or absolute path: leave alone
      if (/^[a-z]+:\/\//i.test(target) || target.startsWith("/") || target.startsWith("#")) {
        return full;
      }
      // Strip .md, normalize ../ segments
      const cleaned = target.replace(/\.md$/, "");
      const parts = cleaned.split("/");
      const stack = (slug.includes("/") ? slug.split("/").slice(0, -1) : []);
      for (const p of parts) {
        if (p === "..") stack.pop();
        else if (p && p !== ".") stack.push(p);
      }
      const resolved = stack.join("/");
      // If we know this slug, use it; otherwise best-effort
      const hashSlug = byBasename[resolved.split("/").pop()] || resolved;
      return `](#${hashSlug})`;
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
      titleEl.textContent = h1Match[1].trim();
      proseEl.querySelector(".prose").prepend(titleEl);
    }

    // Prev / next pager
    const idx = FLAT.findIndex((it) => it.slug === slug);
    if (idx >= 0) {
      const prev = idx > 0 ? FLAT[idx - 1] : null;
      const next = idx < FLAT.length - 1 ? FLAT[idx + 1] : null;
      pagerEl.innerHTML = `
        ${prev ? `<a class="docs-pager-prev" href="#${prev.slug}"><span class="docs-pager-label">Previous</span><span class="docs-pager-title">&larr; ${escapeHtml(prev.title)}</span></a>` : `<span></span>`}
        ${next ? `<a class="docs-pager-next" href="#${next.slug}"><span class="docs-pager-label">Next</span><span class="docs-pager-title">${escapeHtml(next.title)} &rarr;</span></a>` : `<span></span>`}
      `;
    } else {
      pagerEl.innerHTML = "";
    }

    // Highlight active link
    highlight(slug);

    // Scroll to top
    document.querySelector(".docs-content")?.scrollTo({ top: 0, behavior: "instant" });
    window.scrollTo({ top: 0, behavior: "instant" });
  }

  // ---- Routing ----
  function getSlugFromHash() {
    const h = location.hash.replace(/^#/, "");
    return h || "index";
  }
  function onHashChange() {
    const slug = getSlugFromHash();
    load(slug);
    // Close mobile sidebar after nav
    sidebar.classList.remove("is-open");
    menuBtn?.setAttribute("aria-expanded", "false");
  }
  window.addEventListener("hashchange", onHashChange);

  // ---- Search ----
  searchEl.addEventListener("input", (e) => buildSidebar(e.target.value));

  // ---- Mobile menu ----
  menuBtn.addEventListener("click", () => {
    const open = sidebar.classList.toggle("is-open");
    menuBtn.setAttribute("aria-expanded", String(open));
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
