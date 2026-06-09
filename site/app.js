/* dBrief landing — subtle motion only */
(() => {
  // Scroll reveal
  const targets = document.querySelectorAll(
    '.section-head, .step, .split-copy, .split-visual, .logo-row, .cta-title, .cta-sub, .btn'
  );
  targets.forEach((el) => el.classList.add('reveal'));

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          io.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
  );
  targets.forEach((el) => io.observe(el));

  // Smooth in-page nav
  document.querySelectorAll('a[href^="#"]').forEach((a) => {
    a.addEventListener('click', (e) => {
      const id = a.getAttribute('href');
      if (id && id.length > 1) {
        const el = document.querySelector(id);
        if (el) {
          e.preventDefault();
          el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      }
    });
  });

  // Parallax orbs on pointer move — gentle
  const orbs = document.querySelectorAll('.orb');
  let raf = null;
  let tx = 0, ty = 0;
  window.addEventListener('pointermove', (e) => {
    tx = (e.clientX / window.innerWidth - 0.5) * 20;
    ty = (e.clientY / window.innerHeight - 0.5) * 20;
    if (!raf) {
      raf = requestAnimationFrame(() => {
        orbs.forEach((o, i) => {
          const k = (i + 1) * 0.6;
          o.style.translate = `${tx * k}px ${ty * k}px`;
        });
        raf = null;
      });
    }
  });
})();
