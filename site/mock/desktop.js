/* The desktop section's window (desktop.html, data-mock="wide"): picking a conversation in the list opens it beside
   it, and while Maya's is open she writes back now and then. Needs mock.js (window.GM) first. */
(() => {
if (!window.GM) return;
document.querySelectorAll('[data-mock="wide"]').forEach(wireWide);

function wireWide(box) {
  const $ = (s) => box.querySelector(s);
  const thread = $('.js-dk-thread'), list = $('.dk-list'), av = $('.dk-av'), name = $('.dk-name'), sub = $('.dk-sub'), offer = $('.dk-offer');
  const msg = (side, text, extra = '', g = 'solo') => `<div class="gm-msg gm-msg--${side}" data-g="${g}"><div class="gm-bubble">${text}</div>${extra}</div>`;
  const meta = (t) => `<div class="gm-meta">${t}</div>`;
  const read = (t) => `<div class="gm-meta"><span class="gm-row-flex">Read · ${t}&nbsp;<svg class="gm-i gm-ticks is-read"><use href="/mock/icons.svg#check-check"/></svg></span></div>`;
  const people = {
    maya: { hue: 'magenta', ini: 'MC', name: 'Maya Chen', sub: '+15551230001', offer: true, html: thread.innerHTML },
    dad: { hue: 'coral', ini: 'D', name: 'Dad', sub: '+15551230002', offer: false, html:
      '<div class="gm-day">Yesterday</div>' + msg('in', 'Did you pack the charger this time?', meta('9:12 PM')) + msg('out', 'Yes 😅 and the spare one', read('9:20 PM')) +
      '<div class="gm-day">Today</div>' + msg('out', 'Heading to the airport', '', 'top') + msg('out', 'Boarding now, landing around 6', '', 'mid') + msg('out', 'Flight\'s on time ✈️', read('3:41 PM'), 'bottom') +
      msg('in', 'Safe flight!', '', 'top') + msg('in', 'Mum says bring an umbrella, it\'s pouring here', '', 'mid') + msg('in', 'Call me when you land', meta('3:59 PM'), 'bottom') },
    riley: { hue: 'indigo', ini: 'RF', name: 'Riley Fox', sub: 'Encrypted · Uplink', offer: false, html:
      '<div class="gm-day">Today</div>' + msg('in', 'Did you see the offer to encrypt our chat?', meta('8:18 PM')) + msg('out', 'Yes, tapping Turn on now', '', 'top') + msg('out', 'Done. It says the keys match', read('8:24 PM'), 'bottom') +
      msg('in', 'Nice. So nobody in between can read it?', meta('8:26 PM')) + msg('out', 'Not even the relay. Just your phone and mine', read('8:27 PM')) +
      msg('in', 'Only our two phones can read this now', '<div class="gm-reacts"><span class="gm-react is-mine">🔒</span></div>' + meta('8:29 PM')) },
    group: { hue: 'slate', ini: 'JD', name: 'Jordan, Sam, Alex', sub: '3 people', offer: false, html:
      '<div class="gm-day">Today</div>' + msg('in', 'Who\'s bringing snacks for Saturday?', meta('Sam · 7:58 PM')) + msg('out', 'I\'ll grab chips and drinks', read('8:02 PM')) +
      msg('in', 'I\'ve got the board games', meta('Alex · 8:04 PM')) + msg('in', 'View from the spot we booked', meta('Jordan · 8:06 PM')) +
      '<div class="gm-msg gm-msg--in" data-g="solo"><div class="gm-pic dk-pic"></div><div class="gm-meta">Jordan · 8:07 PM</div></div>' },
    noor: { hue: 'orange', ini: 'NH', name: 'Noor Haddad', sub: '+15551230005', offer: false, html:
      '<div class="gm-day">Today</div>' + msg('in', 'Hey! Got your number from Riley', meta('6:40 PM')) + msg('out', 'Hi Noor 👋', '', 'top') + msg('out', 'Can you send me your key so we can switch to encrypted?', read('6:52 PM'), 'bottom') +
      msg('in', 'Sure, one sec', '', 'top') + msg('in', 'Sending it now', meta('6:58 PM'), 'bottom') +
      '<div class="gm-msg gm-msg--in" data-g="solo"><div class="gm-bubble"><div class="gm-file"><span class="gm-file__tile"><svg class="gm-i"><use href="/mock/icons.svg#key-round"/></svg></span><span><span class="gm-file__name">Encryption key</span><span class="gm-file__size">Tap to check it</span></span></div></div><div class="gm-meta">6:59 PM</div></div>' },
  };
  let open = 'maya';

  function show(id) {
    const p = people[id];
    if (!p || id === open) return;
    people[open].html = thread.innerHTML; // what was sent stays in that conversation
    open = id;
    av.dataset.hue = p.hue; av.textContent = p.ini;
    name.textContent = p.name; sub.textContent = p.sub;
    offer.hidden = !p.offer;
    thread.innerHTML = p.html;
    thread.classList.remove('is-swap'); thread.offsetWidth; thread.classList.add('is-swap');
  }
  list.addEventListener('click', (e) => { const row = e.target.closest('.gm-row'); if (row) show(row.dataset.dk); });
  list.addEventListener('keydown', (e) => {
    const row = e.target.closest('.gm-row');
    if (row && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); row.click(); }
  });
  // Mark all read clears every row's dot.
  $('.dk-readall').addEventListener('click', () => list.querySelectorAll('.gm-row.is-unread').forEach((r) => r.classList.remove('is-unread')));
  // A word sent from the composer shows in the list's row too.
  box.addEventListener('gm:send', (e) => {
    const snip = list.querySelector(`[data-dk="${open}"] .gm-row__snip`);
    if (snip) snip.textContent = 'You: ' + e.detail.text;
  });

  // While Maya's conversation is open: she types, writes back, and the window settles back as the picture was.
  GM.loop(box, async ({ wait }) => {
    await wait(2600);
    if (open !== 'maya') return;
    const row = list.querySelector('[data-dk="maya"]'), snip = row.querySelector('.gm-row__snip'), was = snip.textContent;
    const dots = document.createElement('div');
    dots.className = 'gm-msg gm-msg--in is-new'; dots.dataset.g = 'solo';
    dots.innerHTML = '<div class="gm-bubble gm-typing"><i></i><i></i><i></i></div>';
    thread.append(dots);
    snip.innerHTML = '<span class="gm-row__typing"><i></i><i></i><i></i></span>';
    await wait(1900);
    if (open !== 'maya') { dots.remove(); snip.textContent = was; return; }
    dots.remove();
    const m = GM.say(thread, { text: 'Leaving now, see you soon', out: false, meta: '8:59 PM' });
    snip.textContent = 'Leaving now, see you soon';
    if (!row.classList.contains('is-selected')) row.classList.add('is-unread');
    await wait(1400);
    if (open === 'maya') GM.react(m, '👍', true);
    await wait(4200);
    if (open !== 'maya') return;
    await m.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 300, easing: 'ease-out' }).finished;
    m.remove();
    snip.textContent = was;
  }, { gap: 5000 });
}
})();
