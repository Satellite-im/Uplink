/* The app's mocks come alive (site/mock/mock.css; every piece in site/mock/kit.html). No framework: markup with the
   kit's classes and data- attributes is wired on load, and window.GM has the helpers a mock's own script uses.

   On load, under any .gm:
     .gm-fit                  scaled so its stage (the app's pixels, --w by --h) fills the box it is given
     [data-gm-tabs]           its tabs ([role=tab], .gm-seg__tab, .gm-dock__btn, .gm-chip) choose one; a
                              .gm-seg__thumb slides to it. Fires `gm:tab` ({detail: {index, tab}}) on the container.
     [role=switch]            toggles aria-checked; fires `change`
     input.gm-slider          keeps its fill (--p) and the value beside it ([data-gm-out] or the row's .gm-set__value)
     [data-gm-ripple]         the voice ripple; data-level (0..1) is how loud, data-talk="auto" talks by itself
     [data-gm-composer]       a composer: words show Send; Enter or Send puts them in the thread its value names
                              (a selector, looked for in the same mock first), as a bubble of yours. Fires `gm:send` ({detail: {text}}).
     [data-gm-chips]          tapping a chip says it in that composer (selector)
     .gm-react                tapped, it is yours (or not) with a bounce; a bubble double-tapped gets a heart
     .gm-row                  tapped, it is read; in [data-gm-select] it is the one chosen
   Everything animated stops off-screen and does not move at all under prefers-reduced-motion. */
(() => {
  'use strict';
  const still = matchMedia('(prefers-reduced-motion: reduce)');
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  /* A selector looked for in the mock the element is in first (so a mock can be copied), then the page. */
  const near = (el, sel) => (sel ? (el.closest('.gm-stage') || el.closest('.gm') || document).querySelector(sel) || document.querySelector(sel) : null);

  /* --- seen: one IntersectionObserver for everything that animates by itself ---------------------------------- */
  const seenFns = new WeakMap();
  const io = 'IntersectionObserver' in window
    ? new IntersectionObserver((entries) => {
        for (const e of entries) for (const fn of seenFns.get(e.target) || []) fn(e.isIntersecting);
      }, { rootMargin: '80px' })
    : null;
  function onSeen(el, fn) {
    if (!io) { fn(true); return; }
    if (!seenFns.has(el)) { seenFns.set(el, []); io.observe(el); }
    seenFns.get(el).push(fn);
  }

  /* --- fit: the stage at the app's size, scaled to the box -------------------------------------------------- */
  const ro = 'ResizeObserver' in window ? new ResizeObserver((entries) => entries.forEach((e) => (e.target.classList.contains('gm-fit') ? fitOne(e.target) : placeThumb(e.target)))) : null;
  function fitOne(box) {
    const w = parseFloat(getComputedStyle(box).getPropertyValue('--w')) || 412;
    const k = box.clientWidth / w;
    if (k > 0) { box.style.setProperty('--k', String(k)); box.dataset.fit = ''; }
  }
  function fit(root) {
    for (const box of $$('.gm-fit', root)) { fitOne(box); ro && ro.observe(box); }
  }

  /* --- tabs ----------------------------------------------------------------------------------------------- */
  const tabSel = '[role=tab], .gm-seg__tab, .gm-dock__btn, .gm-chip, .gm-tab';
  function placeThumb(group) {
    const thumb = group.querySelector(':scope > .gm-seg__thumb');
    const on = group.querySelector(':scope > [aria-selected=true]');
    if (!thumb || !on) return;
    thumb.style.width = on.offsetWidth + 'px';
    thumb.style.transform = `translateX(${on.offsetLeft}px)`;
    group.dataset.ready = '';
  }
  function choose(group, tab) {
    const tabs = $$(':scope > ' + tabSel.split(', ').join(', :scope > '), group);
    tabs.forEach((t) => t.setAttribute('aria-selected', String(t === tab)));
    placeThumb(group);
    group.dispatchEvent(new CustomEvent('gm:tab', { bubbles: true, detail: { index: tabs.indexOf(tab), tab } }));
  }
  function tabsIn(root) {
    for (const group of $$('[data-gm-tabs]', root)) {
      if (group.__gm) continue; group.__gm = 1;
      // A thumb placed without its slide the first time, then sliding.
      const thumb = group.querySelector(':scope > .gm-seg__thumb');
      if (thumb) { thumb.style.transition = 'none'; placeThumb(group); thumb.offsetWidth; thumb.style.transition = ''; }
      group.addEventListener('click', (e) => {
        const tab = e.target.closest(tabSel);
        if (tab && tab.parentElement === group) choose(group, tab);
      });
      ro && ro.observe(group);
    }
  }

  /* --- switches and sliders ------------------------------------------------------------------------------ */
  function setSlider(input) {
    const min = +input.min || 0, max = +input.max || 100;
    input.style.setProperty('--p', ((input.value - min) / (max - min)) * 100 + '%');
    const row = input.closest('.gm-set__row');
    const out = input.parentElement.querySelector('[data-gm-out]') || (row && row.querySelector('.gm-set__value'));
    if (out) out.textContent = input.value + (input.dataset.unit ?? '%');
  }
  function controlsIn(root) {
    for (const sw of $$('[role=switch]', root)) {
      if (sw.__gm) continue; sw.__gm = 1;
      sw.addEventListener('click', () => {
        sw.setAttribute('aria-checked', String(sw.getAttribute('aria-checked') !== 'true'));
        sw.dispatchEvent(new Event('change', { bubbles: true }));
      });
    }
    for (const s of $$('input.gm-slider', root)) {
      if (s.__gm) continue; s.__gm = 1;
      setSlider(s);
      s.addEventListener('input', () => setSlider(s));
    }
  }

  /* --- the voice ripple: ripple_avatar.dart's _Ripples, line for line ------------------------------------ */
  function ripple(el) {
    if (el.__gm) return; el.__gm = 1;
    const canvas = document.createElement('canvas');
    el.prepend(canvas);
    const letter = el.firstChild && el.childNodes[1];
    if (letter && letter.nodeType === 3) { const s = document.createElement('span'); s.textContent = letter.textContent; letter.replaceWith(s); }
    const ctx = canvas.getContext('2d');
    let strength = 0, t0 = performance.now(), seen = false, raf = 0, talkAt = 0, talkLevel = 0;
    const color = () => getComputedStyle(el).getPropertyValue('--online').trim() || '#2fb35a';
    const level = () => {
      if (el.dataset.talk === 'auto') {
        // Speech: bursts of a second or two with short gaps, louder and softer within them.
        const now = performance.now();
        if (now > talkAt) { talkLevel = talkLevel > 0.05 ? (Math.random() < 0.35 ? 0 : 0.2 + Math.random() * 0.5) : 0.25 + Math.random() * 0.45; talkAt = now + 380 + Math.random() * 900; }
        return talkLevel;
      }
      return parseFloat(el.dataset.level || '0');
    };
    function frame(now) {
      raf = 0;
      const size = el.offsetWidth, dpr = Math.min(3, (window.devicePixelRatio || 1) * 2);
      const box = size * 2.2;
      if (canvas.width !== Math.round(box * dpr)) { canvas.width = canvas.height = Math.round(box * dpr); }
      const lv = level();
      const want = lv <= 0.04 ? 0 : Math.min(1, Math.max(0, 0.35 + lv * 1.6));
      strength += (want - strength) * (want > strength ? 0.35 : 0.08);
      if (still.matches) strength = want;
      el.classList.toggle('is-speaking', strength > 0.05);
      const time = still.matches ? 0.35 : ((now - t0) / 1800) % 1;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, box, box);
      if (strength >= 0.02) {
        const ink = color(), c = box / 2, radius = size / 2, reach = radius * 0.85;
        ctx.strokeStyle = ink;
        for (let i = 0; i < 3; i++) {
          const phase = (time + i / 3) % 1, out = phase * reach;
          const wobble = 0.06 * strength * (1 - phase * 0.5);
          const r = radius + out;
          ctx.beginPath();
          for (let s = 0; s <= 64; s++) {
            const a = (s / 64) * Math.PI * 2;
            const d = r * (1 + wobble * Math.sin(a * 5 + time * Math.PI * 4 + i) + wobble * 0.6 * Math.sin(a * 3 - time * Math.PI * 6));
            const x = c + Math.cos(a) * d, y = c + Math.sin(a) * d;
            s === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
          }
          ctx.closePath();
          ctx.lineWidth = 2.2 * (1 - phase) + 0.6;
          ctx.globalAlpha = (1 - phase) * 0.7 * strength;
          ctx.stroke();
        }
        ctx.globalAlpha = 1;
      }
      if (seen && !still.matches) raf = requestAnimationFrame(frame);
    }
    onSeen(el, (v) => { seen = v; if (v && !raf) raf = requestAnimationFrame(frame); });
    still.addEventListener?.('change', () => { if (!raf) raf = requestAnimationFrame(frame); });
    new MutationObserver(() => { if (!raf) raf = requestAnimationFrame(frame); }).observe(el, { attributes: true, attributeFilter: ['data-level', 'data-talk'] });
    requestAnimationFrame(frame);
  }

  /* --- messages ------------------------------------------------------------------------------------------ */
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  /* Puts a message in a thread (.gm-thread): {text, out, html, meta, g}. Runs of one side regroup their corners. */
  function say(thread, { text = '', html, out = true, meta, emoji } = {}) {
    if (typeof thread === 'string') thread = document.querySelector(thread);
    const msg = document.createElement('div');
    msg.className = 'gm-msg is-new ' + (out ? 'gm-msg--out' : 'gm-msg--in');
    msg.innerHTML = emoji
      ? `<div class="gm-jumbo">${esc(text)}</div>`
      : `<div class="gm-bubble">${html ?? esc(text)}</div>` + (meta ? `<div class="gm-meta">${meta}</div>` : '');
    // The one before, if it is the same side's and has nothing under it, joins this run.
    const prev = thread.lastElementChild;
    if (prev && prev.classList.contains('gm-msg') && prev.classList.contains(out ? 'gm-msg--out' : 'gm-msg--in') && !prev.querySelector('.gm-meta, .gm-reacts') && !emoji) {
      prev.dataset.g = prev.dataset.g === 'mid' || prev.dataset.g === 'bottom' ? 'mid' : 'top';
      msg.dataset.g = 'bottom';
    } else msg.dataset.g = 'solo';
    thread.append(msg);
    msg.addEventListener('animationend', () => msg.classList.remove('is-new'), { once: true });
    return msg;
  }
  /* Keeps a bottom-anchored thread from growing past its box: the oldest leave the top. */
  function trim(thread, keep) {
    const kids = Array.from(thread.children);
    while (kids.length > keep) kids.shift().remove();
  }

  /* A composer: Send shows with words; sending says them in its thread. */
  function composer(form) {
    if (form.__gm) return; form.__gm = 1;
    const input = form.querySelector('.gm-composer__input');
    const sync = () => form.classList.toggle('has-text', !!(input && input.value.trim()));
    input && input.addEventListener('input', sync);
    const send = () => {
      const text = input.value.trim();
      if (!text) return;
      const thread = near(form, form.dataset.gmComposer);
      if (thread) say(thread, { text, out: true });
      input.value = ''; sync();
      form.dispatchEvent(new CustomEvent('gm:send', { bubbles: true, detail: { text } }));
    };
    form.addEventListener('submit', (e) => { e.preventDefault(); send(); });
    const btn = form.querySelector('.gm-composer__send');
    btn && btn.addEventListener('click', (e) => { e.preventDefault(); send(); });
    sync();
  }
  /* Types into a composer letter by letter, as a person would; resolves when done. */
  async function type(form, text, { speed = 55, send = false, isOn = () => true } = {}) {
    if (typeof form === 'string') form = document.querySelector(form);
    const input = form.querySelector('.gm-composer__input');
    if (still.matches) { input.value = text; input.dispatchEvent(new Event('input')); }
    else for (const ch of text) {
      input.value += ch; input.dispatchEvent(new Event('input'));
      await sleep(speed * (ch === ' ' ? 1.6 : 0.6 + Math.random() * 0.8));
      while (!isOn()) await sleep(200);
    }
    if (send) { await sleep(still.matches ? 0 : 350); form.requestSubmit ? form.requestSubmit() : form.dispatchEvent(new Event('submit', { cancelable: true })); }
  }

  /* Adds a reaction under a message (a .gm-msg), or bounces it if it is there. */
  function react(msg, emoji, mine = true) {
    let row = msg.querySelector('.gm-reacts');
    if (!row) { row = document.createElement('div'); row.className = 'gm-reacts'; msg.querySelector('.gm-bubble')?.after(row); }
    let r = Array.from(row.children).find((x) => x.textContent.trim() === emoji);
    if (!r) { r = document.createElement('span'); r.className = 'gm-react'; r.textContent = emoji; row.append(r); }
    r.classList.toggle('is-mine', mine);
    pop(r);
    return r;
  }
  function pop(el) { el.classList.remove('is-pop'); el.offsetWidth; el.classList.add('is-pop'); }

  function wire(root = document) {
    fit(root);
    tabsIn(root);
    controlsIn(root);
    $$('[data-gm-ripple]', root).forEach(ripple);
    $$('[data-gm-composer]', root).forEach(composer);
  }

  /* One listener for the taps that need no setup. */
  document.addEventListener('click', (e) => {
    const t = e.target;
    if (!t.closest || !t.closest('.gm')) return;
    const r = t.closest('.gm-react');
    if (r) { r.classList.toggle('is-mine'); pop(r); return; }
    const chip = t.closest('.gm-chip');
    const chips = chip && chip.closest('[data-gm-chips]');
    if (chips) {
      const form = near(chips, chips.dataset.gmChips);
      const thread = form && near(form, form.dataset.gmComposer);
      if (thread) say(thread, { text: chip.textContent.trim(), out: true, emoji: chip.classList.contains('gm-chip--emoji') });
      return;
    }
    const row = t.closest('.gm-row');
    if (row) {
      row.classList.remove('is-unread');
      const list = row.closest('[data-gm-select]');
      if (list) $$('.gm-row', list).forEach((x) => x.classList.toggle('is-selected', x === row));
    }
    const close = t.closest('.gm-card__close');
    if (close) {
      const card = close.closest('.gm-card');
      card.animate([{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'scale(.96)' }], { duration: still.matches ? 1 : 220, easing: 'ease-out' })
        .onfinish = () => { card.style.visibility = 'hidden'; setTimeout(() => { card.style.visibility = ''; }, 2500); };
    }
  });
  // A double tap on a bubble is a heart, not a word selected.
  document.addEventListener('mousedown', (e) => { if (e.detail > 1 && e.target.closest && e.target.closest('.gm .gm-bubble')) e.preventDefault(); });
  document.addEventListener('dblclick', (e) => {
    const b = e.target.closest && e.target.closest('.gm .gm-bubble');
    if (b) { e.preventDefault(); react(b.closest('.gm-msg'), '❤️'); }
  });

  /* A scripted loop that plays while its mock is on screen and waits where it is while not:
       GM.loop(el, async ({wait, isOn}) => { …; await wait(1200); … })
     The script runs again from the top each time it ends. Under reduced motion it never starts. */
  function loop(el, script, { gap = 1500 } = {}) {
    if (typeof el === 'string') el = document.querySelector(el);
    let on = false, running = false;
    const isOn = () => on && !document.hidden;
    const wait = async (ms) => {
      let left = ms;
      while (left > 0) { const step = Math.min(left, 100); await sleep(step); if (isOn()) left -= step; }
    };
    const run = async () => {
      if (running || still.matches) return;
      running = true;
      while (true) {
        while (!isOn()) await sleep(250);
        try { await script({ wait, isOn, el }); } catch (err) { console.error(err); break; }
        await wait(gap);
      }
    };
    onSeen(el, (v) => { on = v; if (v) run(); });
  }

  window.GM = { near, wire, fit, say, trim, type, react, pop, loop, ripple, choose, sleep, still };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => wire());
  else wire();
  // Inter arriving moves the thumbs' widths.
  document.fonts && document.fonts.ready.then(() => $$('[data-gm-tabs]').forEach(placeThumb));
})();
