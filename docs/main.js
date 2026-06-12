/* ─────────────────────────────────────────────────────────────────────────
   Sol · main.js
   - Copy-to-clipboard for code blocks
   - IntersectionObserver for scroll-triggered animations
   - Reduced-motion guard
   ───────────────────────────────────────────────────────────────────────── */

(function () {
  'use strict';

  /* ── Reduced motion ─────────────────────────────────────────────────── */
  const prefersReducedMotion =
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  if (prefersReducedMotion) {
    // Inject a style that collapses all animation durations to near zero
    const style = document.createElement('style');
    style.textContent = `
      *, *::before, *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
      }
    `;
    document.head.appendChild(style);
  }

  /* ── Copy-to-clipboard ──────────────────────────────────────────────── */
  function initCopyButtons() {
    document.querySelectorAll('.copy-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        // Find the associated code element
        var codeBlock = btn.closest('.code-block');
        if (!codeBlock) return;

        var codeEl = codeBlock.querySelector('code');
        if (!codeEl) return;

        var text = codeEl.textContent.trim();
        var originalLabel = btn.getAttribute('aria-label');

        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = 'Copied!';
          btn.setAttribute('aria-label', 'Copied to clipboard');
          btn.classList.add('copied');
          setTimeout(function () {
            btn.textContent = 'Copy';
            btn.setAttribute('aria-label', originalLabel);
            btn.classList.remove('copied');
          }, 2000);
        }).catch(function () {
          // Fallback for older browsers
          var ta = document.createElement('textarea');
          ta.value = text;
          ta.style.position = 'fixed';
          ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand('copy'); } catch (e) {}
          document.body.removeChild(ta);
          btn.textContent = 'Copied!';
          btn.setAttribute('aria-label', 'Copied to clipboard');
          btn.classList.add('copied');
          setTimeout(function () {
            btn.textContent = 'Copy';
            btn.setAttribute('aria-label', originalLabel);
            btn.classList.remove('copied');
          }, 2000);
        });
      });
    });
  }

  /* ── Scroll animation observer ──────────────────────────────────────── */
  function initScrollAnimations() {
    if (prefersReducedMotion) return;

    // Observe both feature cards and step visuals
    var targets = document.querySelectorAll('.feature-card, .step-visual');
    if (!targets.length) return;

    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('animate');
          } else {
            // Remove so animations replay on scroll back
            entry.target.classList.remove('animate');
          }
        });
      },
      {
        threshold: 0.6,   // 60% visible
        rootMargin: '0px'
      }
    );

    targets.forEach(function (el) {
      observer.observe(el);
    });
  }

  /* ── Step circle activation (install page) ───────────────────────────── */
  function initStepObserver() {
    var steps = document.querySelectorAll('.step');
    if (!steps.length) return;

    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('active');
          } else {
            entry.target.classList.remove('active');
          }
        });
      },
      { threshold: 0.35 }
    );

    steps.forEach(function (step) {
      observer.observe(step);
    });
  }

  /* ── Init ────────────────────────────────────────────────────────────── */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      initCopyButtons();
      initScrollAnimations();
      initStepObserver();
    });
  } else {
    initCopyButtons();
    initScrollAnimations();
    initStepObserver();
  }
})();
