/* The calls section's space ("Friday hang", site/mock/calls.html) comes alive. Both phones are the same space, so
   what you do in one shows in the other: the tabs switch People and Chat; mute, deafen, camera and leave/join work;
   the link button copies (a toast says so); a message typed and sent lands in both chats. While on screen, people
   take turns talking (the voice ripple) and the chat gets a message now and then. Needs mock.js (window.GM) first;
   CallsMock.wire() again after injecting the markup. Nothing moves under prefers-reduced-motion. */
(() => {
  'use strict';
  const GM = window.GM;
  if (!GM) return;
  const icons = '/mock/icons.svg#';
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const mocks = () => $$('.calls-mock');
  const people = {
    you: { name: 'You', tag: '<span class="gm-tag gm-tag--solid">Owner</span>' },
    maya: { name: 'Maya Chen', tag: '<span class="gm-tag">Moderator</span>' },
    riley: { name: 'Riley', tag: '' },
    sam: { name: 'Sam', tag: '' },
  };
  const state = { muted: false, deaf: false, cam: false, out: false };
  let minute = 41;
  const clock = () => `7:${String(minute).padStart(2, '0')} PM`;
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  /* --- the call's own state, drawn the same in every phone ---------------------------------------------------- */
  function setIcon(btn, name) { const u = btn.querySelector('use'); if (u) u.setAttribute('href', icons + name); }
  function flip(btn) { btn.classList.remove('is-flip'); btn.offsetWidth; btn.classList.add('is-flip'); }
  function render(changed) {
    const muted = state.muted || state.deaf;
    for (const m of mocks()) {
      m.classList.toggle('is-muted', muted && !state.out);
      m.classList.toggle('is-out', state.out);
      const mic = m.querySelector('.calls-mic'), ears = m.querySelector('.calls-ears'), cam = m.querySelector('.calls-cam');
      mic.setAttribute('aria-pressed', String(muted)); setIcon(mic, muted ? 'mic-off' : 'mic');
      mic.setAttribute('aria-label', muted ? 'Unmute' : 'Mute');
      ears.setAttribute('aria-pressed', String(state.deaf)); setIcon(ears, state.deaf ? 'headphone-off' : 'headphones');
      cam.setAttribute('aria-pressed', String(state.cam)); setIcon(cam, state.cam ? 'video' : 'video-off');
      if (changed) flip(m.querySelector('.calls-' + changed));
      if (muted || state.out) talk(m, 'you', false);
    }
  }

  /* --- who is talking: the ripple on their face ------------------------------------------------------------- */
  function talk(mock, who, on) {
    const row = who === 'you' ? mock.querySelector('.calls-you') : mock.querySelector(`[data-who="${who}"]`);
    const rip = row && row.querySelector('.gm-rip');
    if (!rip) return;
    if (on) rip.dataset.talk = 'auto';
    else { delete rip.dataset.talk; rip.dataset.level = '0'; }
  }
  const talkAll = (who, on) => mocks().forEach((m) => talk(m, who, on));

  /* --- the chat ------------------------------------------------------------------------------------------- */
  function say(from, text) {
    const p = people[from];
    for (const m of mocks()) {
      const chat = m.querySelector('.calls-chat');
      const last = chat.lastElementChild;
      const line = document.createElement('p');
      line.textContent = text;
      if (last && last.dataset.from === from && last.dataset.at === clock()) {
        line.className = 'is-new';
        last.append(line);
      } else {
        const g = document.createElement('div');
        g.className = 'calls-group is-new';
        g.dataset.from = from; g.dataset.at = clock();
        g.innerHTML = `<div class="calls-by"><b>${esc(p.name)}</b>${p.tag}<time>${clock()}</time></div>`;
        g.append(line);
        chat.append(g);
      }
      // The oldest leave the top, so the chat never grows past its page.
      while (chat.children.length > 7) chat.firstElementChild.remove();
    }
  }

  function toast(mock) {
    const t = mock.querySelector('.calls-toast');
    t.classList.add('is-on');
    clearTimeout(t.__t); t.__t = setTimeout(() => t.classList.remove('is-on'), 1600);
  }

  /* --- one phone's wiring ----------------------------------------------------------------------------------- */
  function wireOne(mock) {
    if (mock.__calls) return; mock.__calls = 1;
    GM.wire(mock);
    const panes = { people: mock.querySelector('.calls-pane--people'), chat: mock.querySelector('.calls-pane--chat') };
    mock.querySelector('.calls-seg').addEventListener('gm:tab', (e) => {
      const tab = e.detail.index === 1 ? 'chat' : 'people';
      mock.dataset.callsTab = tab;
      panes.people.setAttribute('aria-hidden', String(tab !== 'people'));
      panes.chat.setAttribute('aria-hidden', String(tab !== 'chat'));
    });
    mock.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      if (b.classList.contains('calls-mic')) { if (state.deaf) state.deaf = false, state.muted = false; else state.muted = !state.muted; render('mic'); }
      else if (b.classList.contains('calls-ears')) { state.deaf = !state.deaf; render('ears'); }
      else if (b.classList.contains('calls-cam')) { state.cam = !state.cam; render('cam'); }
      else if (b.classList.contains('calls-leave')) { state.out = true; render(); }
      else if (b.classList.contains('calls-join')) { state.out = false; render(); }
      else if (b.classList.contains('calls-link')) toast(mock);
    });
    const form = mock.querySelector('.calls-composer'), input = form.querySelector('input');
    const sync = () => form.classList.toggle('has-text', !!input.value.trim());
    input.addEventListener('input', sync);
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      say('you', text);
      input.value = ''; sync();
    });
  }

  /* --- by themselves, while on screen ------------------------------------------------------------------------ */
  function play() {
    const call = document.querySelector('.calls-mock[data-mock="hangout"]');
    const chat = document.querySelector('.calls-mock[data-mock="hangout-chat"]');
    if (call && !call.__play) {
      call.__play = 1;
      // People take turns, with the odd overlap and pause, as a room does. Sam stays muted.
      const turns = [['maya', 3800], [null, 700], ['riley', 2600], ['maya', 1800], [null, 900], ['you', 2200], [null, 500], ['riley', 1500], ['maya', 3000], [null, 1200]];
      GM.loop(call, async ({ wait }) => {
        for (const [who, ms] of turns) {
          ['maya', 'riley', 'you'].forEach((w) => w !== who && talkAll(w, false));
          if (who && !(who === 'you' && (state.muted || state.deaf || state.out))) talkAll(who, true);
          await wait(ms);
        }
      }, { gap: 0 });
    }
    if (chat && !chat.__play) {
      chat.__play = 1;
      const lines = [
        ['riley', 'Parking now'], ['you', 'Door code is 4412'], ['maya', 'Lights off in 2'], ['sam', 'Muted, eating 😅'],
        ['riley', 'Here!'], ['you', 'Popcorn is on the table'], ['maya', 'Pressing play ▶️'],
      ];
      let i = 0;
      GM.loop(chat, async ({ wait, isOn }) => {
        await wait(2600);
        const [from, text] = lines[i++ % lines.length];
        if (i % 3 === 0) minute = minute >= 59 ? 41 : minute + 1;
        const form = chat.querySelector('.calls-composer'), input = form.querySelector('input');
        if (from === 'you') {
          // Typed into the composer and sent, unless someone is typing there themselves.
          if (document.activeElement === input || input.value) return;
          for (const ch of text) {
            input.value += ch; input.dispatchEvent(new Event('input'));
            await GM.sleep(55 * (ch === ' ' ? 1.6 : 0.6 + Math.random() * 0.8));
            while (!isOn()) await GM.sleep(200);
          }
          await wait(350);
          form.requestSubmit();
        } else say(from, text);
      }, { gap: 1800 });
    }
  }

  function wire(root = document) {
    $$('.calls-mock', root).forEach(wireOne);
    render();
    play();
  }
  window.CallsMock = { wire, say, state };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => wire());
  else wire();
})();
