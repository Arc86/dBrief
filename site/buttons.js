/* Pause the button spectrum when it cannot be seen. */
(() => {
  const buttons = document.querySelectorAll('.nav-cta, .btn.primary');
  const visibleButtons = new Set();

  function updateMotion() {
    buttons.forEach((button) => {
      button.style.animationPlayState = !document.hidden && visibleButtons.has(button)
        ? 'running'
        : 'paused';
    });
  }

  const observer = new IntersectionObserver((entries) => {
    entries.forEach(({ target, isIntersecting }) => {
      if (isIntersecting) visibleButtons.add(target);
      else visibleButtons.delete(target);
    });
    updateMotion();
  });

  buttons.forEach((button) => observer.observe(button));
  document.addEventListener('visibilitychange', updateMotion);
})();
