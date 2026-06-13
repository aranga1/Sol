/* ===========================================================
   Happy Birthday, Ayesha — behaviour
   - splits headline words into individually-popping letters
   - reveals each section on scroll
   - parallaxes the sun + background
   - handles the gift "open" interaction + dot navigation
   =========================================================== */

(function () {
  'use strict';

  var scene = document.getElementById('scene');
  var bg    = document.getElementById('bg');
  var sun   = document.getElementById('sun');
  var dots  = Array.prototype.slice.call(document.querySelectorAll('.dots button'));
  var secs  = Array.prototype.slice.call(document.querySelectorAll('.sec'));

  /* ---- build popping letters ---- */
  function buildLetters(el) {
    var word = el.getAttribute('data-word') || el.textContent;
    el.textContent = '';
    word.split('').forEach(function (ch, i) {
      var outer = document.createElement('span');
      outer.className = 'ltr';
      outer.style.setProperty('--i', i);
      var flt = document.createElement('span');
      flt.className = 'flt';
      var hv = document.createElement('span');
      hv.className = 'hv';
      hv.textContent = ch === ' ' ? '\u00A0' : ch;
      flt.appendChild(hv);
      outer.appendChild(flt);
      el.appendChild(outer);
    });
  }
  Array.prototype.slice.call(document.querySelectorAll('.letters')).forEach(buildLetters);

  /* ---- reveal + parallax on scroll ---- */
  var ticking = false;
  function update() {
    ticking = false;
    var vh = scene.clientHeight;
    var st = scene.scrollTop;

    if (bg)  bg.style.transform  = 'translateY(' + (st * -0.12) + 'px)';
    if (sun) sun.style.transform = 'translate(-50%, calc(-50% + ' + (st * 0.22) + 'px))';

    var current = 0;
    secs.forEach(function (sec, i) {
      var top = sec.offsetTop;
      if (st > top - vh * 0.55) sec.classList.add('in');
      if (st >= top - vh * 0.5) current = i;
    });

    dots.forEach(function (d, i) {
      d.classList.toggle('active', i === current);
    });
  }
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(update);
  }
  scene.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });

  /* initial reveal — run a few times to cover layout / font settle */
  update();
  setTimeout(update, 60);
  setTimeout(update, 300);
  setTimeout(update, 800);

  /* ---- dot navigation ---- */
  dots.forEach(function (d) {
    d.addEventListener('click', function () {
      var i = parseInt(d.getAttribute('data-go'), 10);
      var target = secs[i];
      if (target) scene.scrollTo({ top: target.offsetTop, behavior: 'smooth' });
    });
  });

  /* ---- gift reveal ---- */
  var openBtn = document.getElementById('openBtn');
  var prompt  = document.getElementById('prompt');
  var panel   = document.getElementById('panel');
  if (openBtn) {
    openBtn.addEventListener('click', function () {
      prompt.classList.add('hide');
      panel.classList.add('show');
    });
  }
})();
