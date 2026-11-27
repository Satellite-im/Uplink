/* One inbox (site/mock/inbox.html) comes alive, on top of mock.js (window.GM).
   inbox-list: the two tabs swap the list for the spaces' empty note; "read all" reads every row; and while it is on
   screen, Telegram chats among the texts get new messages: typing first, then the row rises to the top, unread.
   inbox-chat: Jo types, says more, you answer, Jo hearts it; then the chat quietly starts over.
   Nothing moves by itself under prefers-reduced-motion (GM.loop never starts), and the markup is the still picture. */
(() => {
  'use strict';
  const $$ = (sel, root) => Array.from(root.querySelectorAll(sel));
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  /* Moves a row to the top of its list, the others sliding down to make room (first, last, invert, play). */
  function toTop(list, row) {
    const rows = $$(':scope > .gm-row', list);
    const before = new Map(rows.map((r) => [r, r.getBoundingClientRect().top]));
    list.prepend(row);
    const k = list.getBoundingClientRect().height / (list.offsetHeight || 1) || 1;
    for (const r of rows) {
      const dy = (before.get(r) - r.getBoundingClientRect().top) / k;
      if (Math.abs(dy) < 0.5) continue;
      r.animate([{ transform: `translateY(${dy}px)` }, { transform: 'none' }], { duration: 520, easing: 'cubic-bezier(0.16, 1, 0.3, 1)' });
    }
    row.classList.remove('ib-bump'); row.offsetWidth; row.classList.add('ib-bump');
  }

  function list(mock) {
    if (mock.__ib) return; mock.__ib = 1;
    const GM = window.GM;
    const rows = mock.querySelector('.ib-list');
    const start = rows.innerHTML;
    // The tabs: chats, or the spaces (none yet).
    mock.addEventListener('gm:tab', (e) => mock.classList.toggle('ib-spaces', e.detail.index === 1));
    // Read all: every row read, and the button settles back.
    const all = mock.querySelector('.ib-readall');
    all && all.addEventListener('click', () => $$('.gm-row', rows).forEach((r) => r.classList.remove('is-unread')));
    const row = (id) => rows.querySelector(`.gm-row[data-id="${id}"]`);
    const snip = (r, html) => { r.querySelector('.gm-row__snip').innerHTML = html; };
    const typing = '<span class="gm-row__typing"><i></i><i></i><i></i></span>';
    const onChats = async (wait) => { while (mock.classList.contains('ib-spaces')) await wait(300); };
    async function arrive(wait, id, text, time) {
      await onChats(wait);
      const r = row(id);
      if (!r) return;
      snip(r, typing);
      await wait(1700);
      await onChats(wait);
      snip(r, esc(text));
      r.querySelector('.gm-row__time').textContent = time;
      r.classList.add('is-unread');
      toTop(rows, r);
    }
    GM.loop(mock, async ({ wait }) => {
      await wait(2200);
      await arrive(wait, 'crew', "Ana: who's bringing the stove?", '11:47 PM');
      await wait(2600);
      await arrive(wait, 'sam', 'count me in for Saturday', '11:48 PM');
      await wait(2400);
      await arrive(wait, 'jo', 'starts at 8, bring a blanket', '11:49 PM');
      await wait(3600);
      // Back to the start, faded through so it does not jump.
      await onChats(wait);
      rows.style.opacity = '0';
      await wait(320);
      rows.innerHTML = start;
      rows.style.opacity = '';
    }, { gap: 600 });
  }

  function chat(mock) {
    if (mock.__ib) return; mock.__ib = 1;
    const GM = window.GM;
    const thread = mock.querySelector('.ib-thread');
    const start = thread.innerHTML;
    GM.loop(mock, async ({ wait }) => {
      await wait(2400);
      // Jo is typing: the three dots, in a bubble of theirs under the last.
      const dots = document.createElement('div');
      dots.className = 'gm-msg gm-msg--in is-new';
      dots.dataset.g = 'solo';
      dots.innerHTML = '<div class="gm-bubble gm-typing"><i></i><i></i><i></i></div>';
      thread.append(dots);
      await wait(1900);
      dots.remove();
      GM.say(thread, { text: 'starts at 8, bring a blanket', out: false, meta: '11:47 PM' });
      await wait(2200);
      const mine = GM.say(thread, { text: "I'm in! See you there 🙌", out: true, meta: '11:48 PM' });
      await wait(1500);
      GM.react(mine, '❤️', false);
      await wait(4200);
      thread.classList.add('ib-fade');
      await wait(420);
      thread.innerHTML = start;
      thread.classList.remove('ib-fade');
    }, { gap: 400 });
  }

  function wire(root = document) {
    $$('[data-mock="inbox-list"]', root).forEach(list);
    $$('[data-mock="inbox-chat"]', root).forEach(chat);
  }
  window.GMInbox = { wire };
  const go = () => (window.GM ? wire() : setTimeout(go, 50));
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go);
  else go();
})();
