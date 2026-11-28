/* The feature cards of #features (site/mock/features.css) play in turn (Matt, 2026-11-28: "animate through making
   different sections grow larger and show an animation going through the feature then shrink back down and expand a
   different feature"). One card is open at a time: it grows, its stage plays the feature through from its first
   frame to its last, and it closes as the next one opens.

   - A card chosen by hand opens at once and is played twice over before the tour goes on.
   - The button under the deck holds everything where it is, and lets it go again. A card chosen while it is held
     opens on its last frame.
   - Nothing plays off-screen or in a hidden tab: a walkthrough waits where it is and carries on when it is seen.
   - Under prefers-reduced-motion nothing plays at all: the cards open when chosen and each stage shows its last
     frame, which is the markup as it is written in index.html.

   Each walkthrough below is a script over its own stage: it sets the first frame, waits for the card to be open
   (x.ready), then goes step by step. Every wait is the deck's (x.wait), which is what lets one be held or cut short.
   Needs mock.js (window.GM) first; GMFeatures.wire() again after injecting the markup. */
(() => {
  'use strict';
  const GM = window.GM;
  if (!GM) return;
  const ICONS = '/mock/icons.svg#';
  const GROW = 640;    // a card is open enough to watch, this long after it starts to grow
  const HOLD = 1100;   // a walkthrough's last frame stays this long
  const Stop = Symbol('stop');   // thrown through a walkthrough's waits when another card takes its place
  const icon = (el, name) => { const u = el && el.querySelector('use'); if (u) u.setAttribute('href', ICONS + name); };

  /* --- shared files: a file dropped into a Files space goes up in pieces, and everyone has it ---------------- */
  async function files(x) {
    const list = x.$('.fd-files'), row = x.$('.fd-file--new'), hint = row.querySelector('.fd-file__hint');
    const pieces = x.$$('.fd-pieces i'), faces = x.$$('.fd-faces .gm-av');
    const drag = x.$('.fd-drag'), room = x.$('.fd-room i'), free = x.$('.js-free'), toast = x.$('.fd-toast');
    // The first frame: the space as it was, the file not in it.
    row.classList.add('is-out'); row.classList.remove('is-done');
    pieces.forEach((p) => p.classList.remove('is-up'));
    faces.forEach((f) => f.classList.remove('is-in'));
    hint.textContent = 'Going up · 0%'; room.style.setProperty('--p', '36%'); free.textContent = '54.2 GB free';
    drag.classList.remove('is-on', 'is-dropped'); list.classList.remove('is-over');
    await x.ready();

    x.step(0);   // dragged in over the list, and let go
    const a = x.pos(list), w = drag.offsetWidth, h = drag.offsetHeight;
    x.put(drag, a.x + a.w - w * 0.55, a.y + a.h + 4, true);
    drag.classList.add('is-on');
    await x.wait(90);
    x.put(drag, a.x + (a.w - w) / 2, a.y + (a.h - h) / 2 - 8);
    await x.wait(380);
    list.classList.add('is-over');
    await x.wait(1050);
    drag.classList.add('is-dropped'); list.classList.remove('is-over'); row.classList.remove('is-out');
    await x.wait(620);

    x.step(1);   // its pieces, one after another
    for (let i = 0; i < pieces.length; i++) {
      pieces[i].classList.add('is-up');
      hint.textContent = `Going up · ${Math.round(((i + 1) / pieces.length) * 100)}%`;
      await x.wait(i < 3 ? 170 : 92);
    }
    await x.wait(280);

    x.step(2);   // there, for everyone in the circle
    row.classList.add('is-done'); hint.textContent = '12.4 GB · You';
    room.style.setProperty('--p', '48%'); free.textContent = '41.8 GB free';
    await x.wait(420);
    for (const f of faces) { f.classList.add('is-in'); await x.wait(240); }
    toast.classList.add('is-on');
    await x.wait(1900);
    toast.classList.remove('is-on');
  }

  /* --- folder sync: a folder chosen on the computer and My files, kept in step both ways ---------------------- */
  async function sync(x) {
    const scr = x.screen, disk = x.$('.js-disk'), drive = x.$('.js-drive'), link = x.$('.fs-link');
    const call = x.$('.fs-call'), path = x.$('.fs-call__path'), state = x.$('.fs-call__state'), act = x.$('.fs-call__act');
    const file = (name, size, ic, hue) => {
      const d = document.createElement('div');
      d.className = 'fs-file'; d.dataset.hue = hue;
      d.innerHTML = `<svg class="gm-i"><use href="${ICONS}${ic}"/></svg><b>${name}</b><small>${size}</small>`;
      return d;
    };
    // Lifts a copy of `from` off its row and sets it down on `to`, which has kept its place empty.
    const fly = async (from, to) => {
      const a = x.pos(from), b = x.pos(to), g = from.cloneNode(true);
      g.classList.remove('is-new', 'is-coming'); g.classList.add('fs-ghost');
      g.style.width = a.w + 'px'; g.style.transition = 'none'; g.style.transform = `translate(${a.x}px, ${a.y}px)`;
      scr.append(g); g.offsetWidth; g.style.transition = '';
      g.style.transform = `translate(${b.x}px, ${b.y}px)`;
      try { await x.wait(780); } finally { g.remove(); }
      to.classList.remove('is-coming'); to.classList.add('is-new');
    };
    const busy = (on) => { link.classList.toggle('is-busy', on); state.textContent = on ? 'Looking for changes' : 'In step.'; };
    // The first frame: a folder with two files in it, and My files with none: no folder chosen yet.
    scr.querySelectorAll('.fs-ghost').forEach((g) => g.remove());
    disk.replaceChildren(file('itinerary.pdf', '212 KB', 'file-text', 'blue'), file('map.png', '1.8 MB', 'image', 'green'));
    drive.replaceChildren();
    call.classList.remove('is-on'); link.classList.remove('is-busy');
    // (its middle words go on a narrow stage: features.css)
    path.innerHTML = 'Keep a folder <i>on this computer </i>in step with My files.'; state.textContent = ''; act.textContent = 'Sync a folder';
    await x.ready();

    x.step(0);   // Sync a folder, and the folder chosen
    await x.wait(700);
    await x.tap(act);
    call.classList.add('is-on'); path.textContent = '~/Documents/Trip'; act.textContent = 'Stop syncing'; busy(true);
    x.lift();
    await x.wait(800);

    x.step(1);   // what is in the folder goes up
    for (const src of Array.from(disk.children)) {
      const copy = src.cloneNode(true);
      copy.classList.add('is-coming'); drive.append(copy);
      await fly(src, copy);
      await x.wait(160);
    }
    busy(false);
    await x.wait(950);

    x.step(2);   // a photo added from the phone comes down into the folder
    const photo = file('IMG_2041.jpg', 'from your phone', 'image', 'amber');
    photo.classList.add('is-new'); drive.append(photo);
    await x.wait(700);
    busy(true);
    await x.wait(450);
    const down = file('IMG_2041.jpg', '3.4 MB', 'image', 'amber');
    down.classList.add('is-coming'); disk.append(down);
    await fly(photo, down);
    photo.querySelector('small').textContent = '3.4 MB';
    busy(false);
    await x.wait(1300);
  }

  /* --- multi-track recording: the recording's timeline (lib/ui/recording_float.dart) -------------------------- */
  // Who speaks when, in the recording's own seconds: `from` is when their yes came, so where their clip starts.
  const REC = {
    span: 10.2,   // the seconds a lane holds
    end: 9.2,     // where the still frame stands
    people: {
      you: { from: 0, talk: [[0.3, 1.4], [4.5, 5.5], [7.7, 8.6]] },
      maya: { from: 1.5, talk: [[1.9, 3.3], [5.4, 6.6], [8.4, 9.4]] },
      jo: { from: 2.5, talk: [[3.2, 4.6], [6.5, 7.5]] },
    },
  };
  const noise = (n) => { const v = Math.sin(n * 127.1 + 311.7) * 43758.5453; return v - Math.floor(v); };
  /* How loud `who` is at t, 0 to 1: speech in bursts with syllables in them, and near nothing between. */
  function level(who, t) {
    const p = REC.people[who];
    if (t < p.from) return 0;
    let env = 0;
    for (const [a, b] of p.talk) if (t >= a - 0.06 && t <= b + 0.14) env = Math.max(env, Math.min(1, (t - a + 0.06) / 0.14, (b + 0.14 - t) / 0.22));
    const syllable = 0.5 + 0.5 * Math.abs(Math.sin(t * 10.5 + who.length * 1.7));
    return Math.max(0.0015, env * syllable * (0.5 + 0.5 * noise(who.charCodeAt(0) * 31 + Math.round(t * 17))));
  }
  const mix = (t) => Math.min(1, Math.hypot(...Object.keys(REC.people).map((w) => level(w, t))));
  /* A level as it is drawn: lifted (a square root), as the app's timeline lifts it. */
  const shape = (lv) => Math.sqrt(lv);
  /* Draws the ruler and each track's whole waveform for the lanes' width as it is now; the clips uncover them as the
     recording goes on. Again whenever the stage is another size. */
  function drawRec(screen) {
    const rows = screen.querySelector('.fr-rows'), lane = rows && rows.querySelector('.fr-lane');
    const width = lane ? lane.clientWidth : 0;
    if (width < 24 || rows.__w === width) return;
    rows.__w = width;
    const pps = width / REC.span;
    rows.style.setProperty('--pps', pps.toFixed(3));
    const ruler = rows.querySelector('.fr-ruler'), every = [1, 2, 5].find((s) => s * pps >= 56) || 10;
    ruler.replaceChildren();
    for (let s = 0; s < REC.span; s += every) {
      const mark = document.createElement('span');
      mark.style.left = (s * pps).toFixed(1) + 'px'; mark.textContent = `0:${String(s).padStart(2, '0')}`;
      ruler.append(mark);
    }
    for (const row of rows.querySelectorAll('.fr-row[data-track]')) {
      const who = row.dataset.track, svg = row.querySelector('.fr-wave');
      let d = '';
      for (let px = 1.5; px < width; px += 3) {
        const t = px / pps, lv = who === 'mix' ? mix(t) : level(who, t);
        if (lv <= 0) continue;
        const half = Math.max(0.9, shape(lv) * 46);
        d += `M${px.toFixed(1)} ${(50 - half).toFixed(1)}V${(50 + half).toFixed(1)}`;
      }
      svg.setAttribute('viewBox', `0 0 ${width} 100`);
      svg.setAttribute('width', String(width));
      svg.querySelector('path').setAttribute('d', d);
    }
  }
  async function rec(x) {
    const scr = x.screen, rows = x.$('.fr-rows'), time = x.$('.fr-time'), count = x.$('.js-count'), stop = x.$('.fr-stop'), toast = x.$('.fd-toast');
    const row = (w) => rows.querySelector(`[data-track="${w}"]`), head = (w) => row(w).querySelector('.fr-head');
    const meter = (w) => row(w).querySelector('.fr-meter i');
    const asked = (w, yes) => {
      head(w).classList.toggle('is-asked', !yes); head(w).classList.toggle('is-yes', yes);
      head(w).querySelector('.fr-ask').innerHTML = yes ? `<svg class="gm-i"><use href="${ICONS}check"/></svg>Said yes` : 'Asked…';
    };
    const settled = (w) => head(w).classList.remove('is-asked', 'is-yes');
    const key = row('jo').querySelector('.fr-m');
    const inIt = { you: true, maya: false, jo: false };
    let t = 0, muted = false, over = false;
    const draw = () => {
      rows.style.setProperty('--t', t.toFixed(2));
      const whole = Math.floor(t + 1e-6);
      time.textContent = `00:00:${String(whole).padStart(2, '0')}.${Math.floor((t - whole) * 10 + 1e-6)}`;
      for (const w of ['you', 'maya', 'jo']) meter(w).style.setProperty('--lv', !inIt[w] || (w === 'jo' && muted) ? '0' : shape(level(w, t)).toFixed(2));
      meter('mix').style.setProperty('--lv', shape(mix(t)).toFixed(2));
    };
    // The first frame: just begun, only your own voice in it yet.
    scr.classList.remove('is-saved'); count.textContent = '1 track';
    for (const w of ['maya', 'jo']) { row(w).classList.add('is-out'); row(w).classList.remove('is-muted'); settled(w); }
    key.classList.remove('is-lit');
    draw();
    await x.ready();
    drawRec(scr);

    x.step(0);   // each person is asked, and their track begins at their yes
    const cues = [
      [0.6, () => { row('maya').classList.remove('is-out'); asked('maya', false); }],
      [1.1, () => { row('jo').classList.remove('is-out'); asked('jo', false); }],
      [REC.people.maya.from, () => { asked('maya', true); inIt.maya = true; count.textContent = '2 tracks'; }],
      [REC.people.jo.from, () => { asked('jo', true); inIt.jo = true; count.textContent = '3 tracks'; }],
      [2.8, () => settled('maya')],
      [3.5, () => { settled('jo'); x.step(1); }],   // every voice on its own track
      [6.3, () => { x.step(2); x.side(async () => { await x.tap(key); muted = true; key.classList.add('is-lit'); row('jo').classList.add('is-muted'); }); }],
      [8.1, () => x.side(async () => { await x.tap(stop); over = true; })],
    ];
    let next = 0;
    while (!over && t < REC.span - 0.3) {
      await x.wait(100);
      t += 0.1;
      while (next < cues.length && t >= cues[next][0]) cues[next++][1]();
      draw();
    }
    x.lift();
    scr.classList.add('is-saved');
    for (const w of ['mix', 'you', 'maya', 'jo']) meter(w).style.setProperty('--lv', '0');
    await x.wait(650);
    toast.classList.add('is-on');
    await x.wait(1900);
    toast.classList.remove('is-on');
  }

  /* --- screen sharing: a window picked, the call looking at it, and its sound going too ---------------------- */
  async function share(x) {
    const scr = x.screen, win = x.$('.js-window'), thumbs = x.$$('.fh-thumb'), faces = x.$$('.fh-watch .gm-av');
    const sound = x.$('.fh-sound'), who = x.$('.js-watching');
    // The first frame: what there is to share.
    scr.dataset.view = 'pick'; scr.classList.remove('is-drawing');
    thumbs.forEach((t) => t.classList.remove('is-picked'));
    faces.forEach((f) => f.classList.remove('is-in'));
    sound.classList.remove('is-on'); who.textContent = 'Nobody yet';
    await x.ready();

    x.step(0);   // one window, not the whole screen
    await x.wait(900);
    await x.tap(win.querySelector('.fh-pic'));
    win.classList.add('is-picked');
    await x.wait(520);
    x.lift();
    scr.dataset.view = 'live'; scr.classList.add('is-drawing');
    await x.wait(700);

    x.step(1);   // the call comes to look
    const names = ['Maya <i>is watching</i>', 'Maya and Jo <i>are watching</i>', 'Maya, Jo and Sam <i>are watching</i>'];   // (the names alone on a narrow stage)
    for (let i = 0; i < faces.length; i++) {
      faces[i].classList.add('is-in'); who.innerHTML = names[i];
      await x.wait(430);
    }
    await x.wait(900);

    x.step(2);   // what the window plays is heard too
    sound.classList.add('is-on');
    await x.wait(2500);
  }

  /* --- watch together: a video picked in a call plays for everyone in step, and pauses for everyone ---------- */
  async function watch(x) {
    const scr = x.screen, film = x.$('.js-film'), menu = x.$('.fd-menu'), item = x.$('.js-together');
    const btn = x.$('.fw-btn'), now = x.$('.fw-now'), seek = x.$('.fw-seek i'), people = x.$$('.fw-who');
    let t = 0;
    const draw = (tick) => {
      const at = `0:${String(Math.floor(t + 1e-6)).padStart(2, '0')}`;
      if (now.textContent !== at) {
        now.textContent = at;
        for (const p of people) {
          p.querySelector('time').textContent = at;
          if (tick) { p.classList.remove('is-tick'); p.offsetWidth; p.classList.add('is-tick'); }
        }
      }
      seek.style.setProperty('--p', (3 + (t / 190) * 97).toFixed(2) + '%');
    };
    const playing = (on) => { scr.classList.toggle('is-playing', on); icon(btn, on ? 'pause' : 'play'); people.forEach((p) => icon(p, on ? 'play' : 'pause')); };
    const roll = async (seconds) => { for (let n = Math.round(seconds * 10); n > 0; n--) { await x.wait(100); t += 0.1; draw(true); } };
    // The first frame: the circle's files, with a call going on.
    scr.dataset.view = 'pick'; now.textContent = ''; playing(false); draw(false);
    people.forEach((p) => p.classList.remove('is-tick'));
    await x.ready();

    x.step(0);   // held for its menu, and Watch together chosen
    await x.wait(700);
    await x.tap(film, { hold: 520 });
    menu.classList.add('is-on');
    await x.wait(750);
    await x.tap(item);
    menu.classList.remove('is-on'); x.lift();
    await x.wait(220);
    scr.dataset.view = 'play';
    await x.wait(520);

    x.step(1);   // the same second on every device
    playing(true);
    await roll(4.2);

    x.step(2);   // paused here is paused for all of them
    await x.tap(btn);
    playing(false);
    await x.wait(1500);
    await x.tap(btn);
    playing(true); x.lift();
    await roll(1.9);
  }

  /* --- live captions: turned on in a call, each line named as it is said -------------------------------------- */
  async function captions(x) {
    const scr = x.screen, more = x.$('.js-more'), menu = x.$('.fd-menu'), item = x.$('.js-captions');
    const box = x.$('.fc-box'), lines = x.$('.fc-lines'), note = x.$('.fc-note');
    const talk = (who, on) => {
      const r = x.$(`.gm-rip[data-who="${who}"]`);
      if (on) r.dataset.talk = 'auto'; else { delete r.dataset.talk; r.dataset.level = '0'; }
    };
    // Someone says a line: their face ripples, and their words come a word at a time under their name.
    const say = async (who, name, text) => {
      const p = document.createElement('p'), b = document.createElement('b'), words = document.createElement('span');
      b.textContent = name; p.append(b, words); lines.append(p);
      while (lines.children.length > 2) lines.firstElementChild.remove();
      talk(who, true);
      try {
        for (const word of text.split(' ')) { words.textContent += (words.textContent ? ' ' : '') + word; await x.wait(130 + word.length * 24); }
      } finally { talk(who, false); }
    };
    // The first frame: a call with no captions.
    scr.classList.remove('is-noted'); box.classList.remove('is-on'); note.classList.remove('is-on'); lines.replaceChildren();
    for (const w of ['maya', 'jo', 'sam']) talk(w, false);
    await x.ready();

    x.step(0);   // the call's menu, and Show captions
    talk('maya', true);
    await x.wait(800);
    await x.tap(more);
    menu.classList.add('is-on');
    await x.wait(700);
    await x.tap(item);
    menu.classList.remove('is-on'); x.lift(); talk('maya', false);
    box.classList.add('is-on');
    await x.wait(550);

    x.step(1);   // who said what
    await say('maya', 'Maya', 'I think we should meet earlier next week');
    await x.wait(380);
    await say('jo', 'Jo', 'Works for me, Tuesday?');
    await x.wait(320);

    x.step(2);   // each written where it was said
    scr.classList.add('is-noted'); note.classList.add('is-on');
    await say('sam', 'Sam', 'Tuesday it is');
    await x.wait(1500);
  }

  const demos = { files, sync, rec, share, watch, captions };
  /* What a stage needs drawn by script even while it is still: the recording's waveforms. */
  const stills = { rec: drawRec };

  /* --- the deck ---------------------------------------------------------------------------------------------- */
  function wireDeck(deck) {
    if (deck.__ft) return; deck.__ft = 1;
    const cards = Array.from(deck.querySelectorAll('.ft-card'));
    if (!cards.length) return;
    const ctl = deck.parentElement.querySelector('.ft-ctl'), hold = ctl && ctl.querySelector('.ft-play'), hint = ctl && ctl.querySelector('.ft-hint');
    deck.style.setProperty('--ft-n', String(cards.length));

    // Each stage's last frame as it was written, to go back to when playing is turned off (the ripples' canvases
    // are mock.js's, drawn again when it wires them).
    const written = cards.map((card) => {
      const copy = card.querySelector('.gm-screen').cloneNode(true);
      copy.querySelectorAll('canvas').forEach((c) => c.remove());
      return copy.innerHTML;
    });
    const still = (card) => { const draw = stills[card.dataset.ft]; if (draw) draw(card.querySelector('.gm-screen')); };
    const ro = 'ResizeObserver' in window ? new ResizeObserver((entries) => entries.forEach((e) => still(e.target.closest('.ft-card')))) : null;
    cards.forEach((card) => { still(card); ro && ro.observe(card.querySelector('.ft-stage')); });

    // A card's name becomes its button: all of the card while it is closed, its head once it is open.
    const tabs = cards.map((card, i) => {
      const name = card.querySelector('.ft-name'), body = card.querySelector('.ft-body');
      const tab = document.createElement('button');
      tab.type = 'button'; tab.className = 'ft-tab';
      tab.append(...name.childNodes);
      name.append(tab);
      if (body && body.id) tab.setAttribute('aria-controls', body.id);
      tab.addEventListener('click', () => choose(i));
      return tab;
    });

    let open = Math.max(0, cards.findIndex((c) => c.classList.contains('is-open')));
    let run = 0;          // which walkthrough is the one playing: one that finds itself an older number stops
    let again = 0;        // how many more times the open card plays before the next opens
    let seen = false, held = false;
    let waiting = false;  // held with no walkthrough begun: the open card plays when it is let go
    const dirty = cards.map(() => false);   // the cards whose stages a walkthrough has changed
    const live = () => seen && !held && !document.hidden;

    function show(i) {
      open = i;
      cards.forEach((c, n) => { c.classList.toggle('is-open', n === i); tabs[n].setAttribute('aria-expanded', String(n === i)); });
    }

    // Puts a card's stage back to its last frame, as it was written.
    function rest(n) {
      const card = cards[n], steps = Array.from(card.querySelectorAll('.ft-steps li'));
      if (dirty[n]) {
        const screen = card.querySelector('.gm-screen');
        screen.innerHTML = written[n];
        GM.wire(screen);
        still(card);
        dirty[n] = false;
      }
      // Held, the last of its steps is the one shown; with nothing playing at all, none is.
      const last = deck.hasAttribute('data-run') ? steps.length - 1 : -1;
      steps.forEach((li, k) => { li.classList.toggle('is-on', k === last); li.classList.toggle('is-done', k < last); });
    }

    /* What a walkthrough is given: its stage, and the deck's ways of waiting, pressing and saying which step it is. */
    function context(card, token) {
      const stage = card.querySelector('.gm-stage'), screen = card.querySelector('.gm-screen');
      const dot = screen.querySelector('.fd-tap'), steps = Array.from(card.querySelectorAll('.ft-steps li'));
      // Counts only while the deck is watched and not held; ends the walkthrough where another has taken its place.
      const wait = async (ms) => {
        let left = ms;
        for (;;) {
          if (token !== run) throw Stop;
          if (!live()) { await GM.sleep(140); continue; }
          if (left <= 0) return;
          const slice = Math.min(left, 80);
          await GM.sleep(slice);
          left -= slice;
        }
      };
      // Where something is on the stage, in the app's own pixels (the stage is scaled to its box).
      const pos = (el) => {
        const s = stage.getBoundingClientRect(), r = el.getBoundingClientRect(), k = s.width / stage.offsetWidth || 1;
        return { x: (r.left - s.left) / k, y: (r.top - s.top) / k, w: r.width / k, h: r.height / k };
      };
      // Moves something placed by --x and --y; `jump` puts it there at once.
      const put = (el, px, py, jump) => {
        if (jump) el.style.transition = 'none';
        el.style.setProperty('--x', px.toFixed(1) + 'px'); el.style.setProperty('--y', py.toFixed(1) + 'px');
        if (jump) { el.offsetWidth; el.style.transition = ''; }
      };
      // The finger goes to `el` and presses it: over when it lets go.
      const tap = async (el, { hold: ms = 170 } = {}) => {
        const p = pos(el), cx = p.x + p.w / 2, cy = p.y + p.h / 2;
        if (dot) {
          if (!dot.classList.contains('is-on')) { put(dot, cx + 30, cy + 42, true); dot.classList.add('is-on'); }
          put(dot, cx, cy);
        }
        await wait(640);
        dot && dot.classList.add('is-down'); el.classList.add('is-pressed');
        try { await wait(ms); } finally { dot && dot.classList.remove('is-down'); el.classList.remove('is-pressed'); }
      };
      return {
        card, stage, screen, wait, pos, put, tap,
        ready: () => wait(GROW),
        lift: () => dot && dot.classList.remove('is-on'),
        step: (n) => steps.forEach((li, i) => { li.classList.toggle('is-on', i === n); li.classList.toggle('is-done', i < n); }),
        // Something done beside the walkthrough's own line; it ends with it.
        side: (job) => { job().catch((e) => { if (e !== Stop) console.error(e); }); },
        $: (sel) => screen.querySelector(sel),
        $$: (sel) => Array.from(screen.querySelectorAll(sel)),
      };
    }

    async function play(i) {
      const token = ++run;
      show(i);
      waiting = held && !GM.still.matches;
      if (GM.still.matches || held) { rest(i); return; }
      dirty[i] = true;
      const card = cards[i], demo = demos[card.dataset.ft], x = context(card, token);
      try {
        x.lift(); x.step(-1);
        for (const el of x.$$('.fd-toast, .fd-menu')) el.classList.remove('is-on');
        if (demo) await demo(x); else await x.wait(4200);
        await x.wait(HOLD);
      } catch (e) {
        if (token !== run) return;
        if (e !== Stop) { console.error(e); await GM.sleep(3000); }
      }
      if (token !== run) return;
      if (again > 0) { again--; play(i); } else play((i + 1) % cards.length);
    }
    // Chosen by hand: played, and once more, before the next.
    function choose(i) { again = 1; play(i); }

    if (hold) hold.addEventListener('click', () => {
      held = !held;
      deck.classList.toggle('is-paused', held);
      hold.setAttribute('aria-pressed', String(held));
      hold.title = held ? 'Play' : 'Pause';
      if (!held && waiting) play(open);
    });

    if ('IntersectionObserver' in window) {
      new IntersectionObserver((entries) => { seen = entries[entries.length - 1].intersectionRatio >= 0.3; }, { threshold: [0, 0.3] }).observe(deck);
    } else seen = true;

    // Playing, or still: as the visitor's own setting says, and again when they change it.
    const start = () => {
      const quiet = GM.still.matches;
      deck.toggleAttribute('data-run', !quiet);
      if (ctl) {
        ctl.hidden = false;
        if (hold) hold.hidden = quiet;
        if (hint) hint.textContent = quiet ? 'Choose a card to open it.' : 'Plays by itself. Choose a card to jump to it.';
      }
      if (!quiet) { play(open); return; }
      run++; waiting = false;
      cards.forEach((card, n) => rest(n));
      show(open);
    };
    GM.still.addEventListener && GM.still.addEventListener('change', start);
    // From the cards all lying open to one open: at once, with nothing seen to move (data-ready lets them move after).
    deck.dataset.live = '';
    show(open);
    deck.offsetWidth;
    deck.dataset.ready = '';
    start();
  }

  function wire(root = document) {
    GM.wire(root);
    for (const deck of root.querySelectorAll('[data-ft-deck]')) wireDeck(deck);
  }
  window.GMFeatures = { wire };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => wire());
  else wire();
})();
