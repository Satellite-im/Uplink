/* The pillar cards of #one-app (site/mock/pillars.html): the taps and the little bits of life the kit (mock.js)
   does not do by itself. Runs after mock.js; each part looks only inside its own [data-mock]. */
(() => {
  'use strict';
  const GM = window.GM;
  if (!GM) return;
  const $ = (sel, root) => root.querySelector(sel);
  const $$ = (sel, root) => Array.from(root.querySelectorAll(sel));
  const icon = (svg, name) => { const u = svg && svg.querySelector('use'); if (u) u.setAttribute('href', '/mock/icons.svg#' + name); };
  const now = () => new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  /* --- Messages: the list ---------------------------------------------------------------------------------- */
  function list(m) {
    if (m.__pl) return; m.__pl = 1;
    const rows = $$('.gm-row', m);
    let tab = 0, query = '';
    const show = () => {
      for (const r of rows) {
        const inTab = (r.dataset.tab || '0').split(' ').includes(String(tab));
        const hit = !query || r.textContent.toLowerCase().includes(query);
        const out = !(inTab && hit);
        if (!out && r.classList.contains('pl-out')) { r.classList.remove('pl-in'); r.offsetWidth; r.classList.add('pl-in'); }
        r.classList.toggle('pl-out', out);
      }
    };
    $('.gm-seg', m).addEventListener('gm:tab', (e) => { tab = e.detail.index; show(); });
    $('.pl-search', m).addEventListener('input', (e) => { query = e.target.value.trim().toLowerCase(); show(); });
    $('.pl-markall', m).addEventListener('click', (e) => { rows.forEach((r) => r.classList.remove('is-unread')); GM.pop(e.currentTarget); });

    const bar = $('.pl-callbar', m), mute = $('.pl-mute', m);
    mute.addEventListener('click', () => {
      const on = mute.getAttribute('aria-pressed') !== 'true';
      mute.setAttribute('aria-pressed', String(on));
      mute.setAttribute('aria-label', on ? 'Unmute' : 'Mute');
      bar.classList.toggle('is-muted', on);
      icon($('svg', mute), on ? 'mic-off' : 'mic');
      const me = $('.pl-me', m); if (me) me.dataset.level = on ? '0' : '0.5';
    });
    $('.pl-leave', m).addEventListener('click', () => {
      bar.classList.add('is-gone');
      setTimeout(() => bar.classList.remove('is-gone'), 2600);
    });

    // Maya writes again now and then: typing dots in her row, then her words, unread.
    const maya = $('.pl-maya', m), snip = $('.gm-row__snip', maya), time = $('.gm-row__time', maya);
    const said = ['On my way, ten minutes 🚗', 'Got the popcorn 🍿', 'Which door do we use?', 'Sounds good, see you at 7! Bring the projector cable if you still have it'];
    let n = 0;
    GM.loop(m, async ({ wait }) => {
      await wait(3200);
      snip.innerHTML = '<span class="gm-row__typing"><i></i><i></i><i></i></span>';
      await wait(2000);
      snip.textContent = said[n++ % said.length];
      time.textContent = now();
      maya.classList.add('is-unread');
      maya.classList.remove('pl-bump'); maya.offsetWidth; maya.classList.add('pl-bump');
      await wait(3600);
    }, { gap: 600 });
  }

  /* --- Voice: a space ------------------------------------------------------------------------------------- */
  function hangout(m) {
    if (m.__pl) return; m.__pl = 1;
    const people = $('.pl-people', m), chat = $('.pl-chat', m);
    $('.pl-tabs', m).addEventListener('gm:tab', (e) => {
      people.hidden = e.detail.index !== 0;
      chat.hidden = e.detail.index !== 1;
    });

    const toast = $('.pl-toast', m);
    let toastT = 0;
    const say = (text) => { toast.textContent = text; toast.classList.add('is-on'); clearTimeout(toastT); toastT = setTimeout(() => toast.classList.remove('is-on'), 1600); };
    $('.pl-copy', m).addEventListener('click', () => say('Invite link copied'));

    // The call controls: each one a toggle, its icon saying what it is now.
    const you = $('.pl-you', m), youMute = $('.pl-youmute', m);
    const toggle = (btn, on, off, after) => btn.addEventListener('click', () => {
      const p = btn.getAttribute('aria-pressed') !== 'true';
      btn.setAttribute('aria-pressed', String(p));
      icon($('svg', btn), p ? on : off);
      after && after(p);
    });
    toggle($('.pl-mic', m), 'mic-off', 'mic', (p) => youMute.toggleAttribute('hidden', !p)  /* an <svg> has no .hidden property */);
    toggle($('.pl-sound', m), 'headphone-off', 'headphones');
    toggle($('.pl-cam', m), 'video', 'video-off', (p) => say(p ? 'Camera on' : 'Camera off'));

    const dock = $('.pl-dock', m), join = $('.pl-join', m);
    $('.pl-leave', m).addEventListener('click', () => {
      you.classList.add('pl-leaving');
      setTimeout(() => { you.hidden = true; you.classList.remove('pl-leaving'); }, GM.still.matches ? 0 : 260);
      dock.hidden = true; join.hidden = false;
    });
    join.addEventListener('click', () => {
      you.hidden = false; you.classList.remove('pl-joining'); you.offsetWidth; you.classList.add('pl-joining');
      join.hidden = true; dock.hidden = false;
    });

    // The space's chat: what you write goes in as yours.
    const form = $('.pl-say', chat), input = $('.pl-say__input', chat), lines = $('.js-pl-lines', chat);
    input.addEventListener('input', () => form.classList.toggle('has-text', !!input.value.trim()));
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      const last = lines.lastElementChild;
      const p = document.createElement('p'); p.textContent = text;
      if (last && last.dataset.you) last.append(p);
      else {
        const line = document.createElement('div');
        line.className = 'pl-line is-new'; line.dataset.you = '1';
        line.innerHTML = `<div class="pl-line__who"><b>You</b><span class="gm-tag gm-tag--solid">Owner</span><time>${esc(now())}</time></div>`;
        line.append(p);
        lines.append(line);
      }
      while (lines.children.length > 5) lines.firstElementChild.remove();
      input.value = ''; form.classList.remove('has-text');
    });
    lines.lastElementChild.dataset.you = '1';

    // Sam unmutes now and then, says something, and mutes again.
    const sam = $('.pl-sam', m), samRip = $('.gm-rip', sam);
    GM.loop(m, async ({ wait }) => {
      await wait(4200);
      sam.classList.add('pl-unmuted');
      await wait(500);
      samRip.dataset.talk = 'auto';
      await wait(3200);
      delete samRip.dataset.talk; samRip.dataset.level = '0';
      await wait(700);
      sam.classList.remove('pl-unmuted');
    }, { gap: 2500 });
  }

  /* --- Video: the voice settings ------------------------------------------------------------------------- */
  function voice(m) {
    if (m.__pl) return; m.__pl = 1;
    let touched = false;
    m.addEventListener('pointerdown', () => { touched = true; }, { passive: true });

    // Music mode takes the microphone as it is: echo cancellation, noise suppression and gain go off with it.
    const offRows = $$('.pl-music-off', m), noise = $$('.pl-pick', m)[0];
    const kept = new Map();
    $('.pl-music', m).addEventListener('change', (e) => {
      const on = e.currentTarget.getAttribute('aria-checked') === 'true';
      for (const row of offRows) {
        const sw = $('[role=switch]', row);
        if (on) { kept.set(sw, sw.getAttribute('aria-checked')); sw.setAttribute('aria-checked', 'false'); }
        else if (kept.has(sw)) sw.setAttribute('aria-checked', kept.get(sw));
        row.classList.toggle('is-off', on);
      }
      const v = $('.gm-set__value', noise);
      if (on) { kept.set(noise, v.textContent); v.textContent = 'Off'; } else if (kept.has(noise)) v.textContent = kept.get(noise);
      noise.classList.toggle('is-off', on);
    });

    // A row with a value and a chevron opens a picker in the app; here a tap steps to the next choice.
    for (const row of $$('.pl-pick', m)) {
      row.addEventListener('click', () => {
        const opts = row.dataset.pick.split('|'), v = $('.gm-set__value', row);
        const next = opts[(opts.indexOf(v.textContent) + 1) % opts.length];
        row.classList.add('pl-swap');
        setTimeout(() => { v.textContent = next; row.classList.remove('pl-swap'); }, GM.still.matches ? 0 : 140);
      });
    }

    // Until someone touches it, the microphone slider shows it goes past 100%: a slow boost and back.
    const s = $('.pl-micvol', m);
    const glide = (to, ms) => new Promise((done) => {
      const from = +s.value, t0 = performance.now();
      const step = (t) => {
        if (touched) return done();
        const k = Math.min(1, (t - t0) / ms), e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
        s.value = String(Math.round(from + (to - from) * e));
        s.dispatchEvent(new Event('input'));
        k < 1 ? requestAnimationFrame(step) : done();
      };
      requestAnimationFrame(step);
    });
    GM.loop(m, async ({ wait }) => {
      await wait(3000);
      if (touched) return wait(60000);
      await glide(160, 1300);
      await wait(1400);
      if (touched) return;
      await glide(100, 1100);
    }, { gap: 4000 });
  }

  const parts = { list, hangout, 'voice-settings': voice };
  function wire(root = document) {
    GM.wire(root);
    // Only the pillar cards' own (.pl-shot): the calls section has a hangout of its own (calls.js, .calls-mock).
    for (const m of root.querySelectorAll('.pl-shot[data-mock]')) parts[m.dataset.mock] && parts[m.dataset.mock](m);
  }
  window.GMPillars = { wire };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => wire());
  else wire();
})();
