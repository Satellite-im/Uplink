/* The hero's exploded conversation (site/mock/hero.html), alive across its layers. Needs mock.js (window.GM) first.
   Each set of layers is found by the stack it sits in (.stack, or anything marked data-hero):
     - the composer sends: what you send becomes your newest bubble (x-out2), rising in; the heart under the old one
       leaves, and the receipt under it goes Sent, Delivered, Read. Some seconds later the conversation is as it was.
     - a chip tapped is typed into the composer and sent.
     - a bubble double-tapped: its reaction (the heart, the laugh) bounces and is yours or not; the kit's own
       double-tap (a new reaction row) is kept out, since each reaction is its own layer here.
     - by itself (not under reduced motion, only on screen, never while someone is using it) the composer now and
       then types a reply and sends it. */
(() => {
  'use strict';
  const GM = window.GM;
  if (!GM) return;
  const LINES = ["Popcorn's on me 🍿", 'Leaving now, see you soon', 'Found the cable!'];
  const emojiOnly = (s) => /^(\p{Extended_Pictographic}|\p{Emoji_Modifier}|️|‍|\s)+$/u.test(s);

  function setUp(root) {
    if (root.__hero) return; root.__hero = 1;
    const q = (name) => root.querySelector(`[data-mock="${name}"]`);
    const out2 = q('x-out2'), ticks = q('x-ticks'), heart = q('x-heart'), laugh = q('x-laugh'), compose = q('x-compose'), chips = q('x-chips');
    if (!out2 || !compose) return;
    const form = compose.querySelector('.gm-composer'), input = form.querySelector('.gm-composer__input');
    const msg = out2.querySelector('.gm-msg');
    const was = { msg: msg.innerHTML, ticks: ticks && ticks.querySelector('.gm-meta').innerHTML };
    let typing = false, touched = 0, back = 0, steps = [], showing = false, restoredAt = 0;
    const later = (fn, ms) => { const t = setTimeout(fn, GM.still.matches ? 0 : ms); steps.push(t); };
    const clear = () => { steps.forEach(clearTimeout); steps = []; clearTimeout(back); };

    // The receipt under your newest message: words, one tick or two, read or not.
    function receipt(words, icon, read) {
      if (!ticks) return;
      const state = ticks.querySelector('.hero-state'), edited = ticks.querySelector('.hero-edited'), svg = ticks.querySelector('.gm-ticks');
      if (edited) edited.classList.add('is-fading');
      state.classList.add('is-fading');
      setTimeout(() => {
        state.textContent = words;
        svg.querySelector('use').setAttribute('href', '/mock/icons.svg#' + icon);
        svg.classList.toggle('is-read', !!read);
        state.classList.remove('is-fading');
      }, GM.still.matches ? 0 : 180);
    }
    function arrive(el) { el.classList.remove('is-new'); el.offsetWidth; el.classList.add('is-new'); }

    function sent(text) {
      clear();
      showing = true;
      msg.innerHTML = emojiOnly(text) ? `<div class="gm-jumbo"></div>` : `<div class="gm-bubble"></div>`;
      msg.firstElementChild.textContent = text;
      arrive(msg);
      heart && heart.querySelector('.gm-react').classList.add('is-gone');
      receipt('Sent · now', 'check');
      later(() => receipt('Delivered · now', 'check-check'), 900);
      later(() => receipt('Read · now', 'check-check', true), 2600);
      back = setTimeout(restore, 9000);
    }
    // As it was: the screenshot's conversation, the end state every loop returns to.
    function restore() {
      clear();
      showing = false; restoredAt = Date.now();
      msg.innerHTML = was.msg;
      arrive(msg);
      if (ticks) {
        const meta = ticks.querySelector('.gm-meta');
        meta.style.opacity = '0';
        setTimeout(() => { meta.innerHTML = was.ticks; meta.style.opacity = ''; }, GM.still.matches ? 0 : 200);
        meta.style.transition = 'opacity 250ms';
      }
      if (heart) { const r = heart.querySelector('.gm-react'); if (r.classList.contains('is-gone')) { r.classList.remove('is-gone'); GM.pop(r); } }
    }

    form.addEventListener('gm:send', (e) => sent(e.detail.text));
    async function say(text, isOn) {
      if (typing) return;
      typing = true;
      input.value = ''; input.dispatchEvent(new Event('input'));
      try { await GM.type(form, text, { send: true, speed: 50, isOn }); } finally { typing = false; }
    }

    // Someone using it: the loop keeps out of the way for a while.
    for (const ev of ['pointerdown', 'keydown', 'input']) root.addEventListener(ev, (e) => { if (e.isTrusted) touched = Date.now(); }, true);

    // A chip: typed in, then sent.
    if (chips) chips.addEventListener('click', (e) => {
      const chip = e.target.closest('.gm-chip');
      if (!chip) return;
      GM.pop(chip);
      say(chip.textContent.trim());
    });

    // A double tap: the reaction that is that message's layer, not a new row inside a box too small for it.
    root.addEventListener('dblclick', (e) => {
      const b = e.target.closest && e.target.closest('.gm-bubble, .gm-jumbo');
      if (!b || !root.contains(b)) return;
      e.stopPropagation(); e.preventDefault();
      const layer = b.closest('[data-mock]').dataset.mock;
      const r = (layer === 'x-in' || layer === 'x-emoji' || layer === 'x-link' ? laugh : heart);
      const em = r && r.querySelector('.gm-react');
      if (!em) return;
      em.classList.remove('is-gone');
      em.classList.toggle('is-mine');
      GM.pop(em);
    }, true);

    // By itself, now and then.
    let n = 0;
    GM.loop(compose, async ({ wait, isOn }) => {
      await wait(3500);
      if (typing || showing || Date.now() - touched < 8000 || Date.now() - restoredAt < 4000 || input.value) return;
      await say(LINES[n++ % LINES.length], isOn);
    }, { gap: 2500 });
  }

  function wireHero(doc = document) {
    for (const c of doc.querySelectorAll('[data-mock="x-compose"]')) {
      const root = c.closest('.stack, [data-hero]');
      if (root) setUp(root);
    }
  }
  window.GM.hero = wireHero;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => wireHero());
  else wireHero();
})();
