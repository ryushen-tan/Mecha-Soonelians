// Jelly flow — the web twin of Rally/HomeView.swift (code card, host / join identity card) and Rally/LobbyView.swift (the room),
// on the Rally rooms API: POST /rooms, POST /rooms/:code/join, GET /rooms/:code, PATCH /rooms/:code/me {ready},
// PATCH /rooms/:code {locked | status}, DELETE /rooms/:code/members/:id, POST /rooms/:code/leave. No demo fallback (as in the app).
export function createLobby({ overlay, onOpen, onClose, sfx } = {}) {
  const COLORS = ['#c6ff4a', '#4a63ff', '#ff7d8a', '#ffb86b', '#7df0b3', '#d58cff'], COLOR_NAMES = ['Lime', 'Blue', 'Pink', 'Orange', 'Mint', 'Purple'];
  const LS = { server: 'mecha.server', name: 'mecha.nickname', avatar: 'mecha.avatar', session: 'mecha.session' };
  const get = (k, d) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } };
  const put = (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} };
  let server = (new URLSearchParams(location.search).get('server') || get(LS.server, '') || '').replace(/\/$/, '');
  let nickname = get(LS.name, ''), avatar = Math.min(5, Math.max(0, +get(LS.avatar, '0') || 0));
  let session = null; try { session = JSON.parse(sessionStorage.getItem(LS.session) || 'null'); } catch {}   // per tab (the app keeps it in the Keychain): two tabs can be two players
  let room = null, error = null, busy = false, reconnecting = false, entry = 'code', code = '', copied = false, menuOpen = false, pollTimer = null, lastJSON = '';
  const card = h('div', { class: 'lb-card', role: 'dialog', 'aria-modal': 'true' }); overlay.className = 'lb-overlay'; overlay.hidden = true; overlay.append(card);

  function h(tag, attrs = {}, ...kids) { const el = document.createElement(tag); for (const [k, v] of Object.entries(attrs)) { if (v == null || v === false) continue; if (k === 'class') el.className = v; else if (k === 'html') el.innerHTML = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else el.setAttribute(k, v === true ? '' : v); } el.append(...kids); return el; }
  const ICON = {   // the SF Symbols the app uses, as small inline SVGs
    arrow: '<path d="M4 12h14M12 6l6 6-6 6"/>', check: '<path d="M5 12l4 4L19 7"/>', clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>', unlock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 7.5-2"/>',
    copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5h10"/>', share: '<path d="M12 3v12M7 8l5-5 5 5M5 13v7h14v-7"/>',
    exclaim: '<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>', network: '<circle cx="12" cy="5" r="2"/><circle cx="5" cy="19" r="2"/><circle cx="19" cy="19" r="2"/><path d="M12 7v5M12 12l-7 5M12 12l7 5"/>',
    checkfill: '<circle cx="12" cy="12" r="10" fill="currentColor" stroke="none"/><path d="M8 12l3 3 5-6" stroke="#fff"/>', wifi: '<path d="M3 9a14 14 0 0 1 18 0M6 12.5a9 9 0 0 1 12 0M9 16a4 4 0 0 1 6 0"/><circle cx="12" cy="19" r="1" fill="currentColor"/>',
    viewfinder: '<path d="M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4"/><circle cx="12" cy="12" r="3"/>', note: '<path d="M9 18V6l10-2v12"/><circle cx="6" cy="18" r="3"/><circle cx="16" cy="16" r="3"/>',
    speakerSlash: '<path d="M4 10v4h3l4 4V6L7 10zM15 9l5 6M20 9l-5 6"/>'
  };
  const icon = (name, size = 16) => { const s = document.createElement('span'); s.style.cssText = 'display:inline-flex;flex:none'; s.innerHTML = `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON[name]}</svg>`; return s; };   // SVG needs its own namespace: build it from markup
  const key = (k) => sfx?.key?.(k);

  // ---------------- store (LobbyStore.swift)
  const me = () => room?.members.find(m => m.id === session?.memberID) || null;
  const isHost = () => me()?.host === true;
  const validName = () => { const n = nickname.trim().length; return n >= 1 && n <= 20; };
  const displayCode = (c) => c.slice(0, 3) + ' ' + c.slice(3);
  const describe = (e) => e?.status ? e.message : "Couldn’t reach the server. Check the connection settings and make sure the server is running.";
  async function api(method, path, body) {
    const res = await fetch(server + path, { method, headers: { 'Content-Type': 'application/json', ...(session ? { Authorization: 'Bearer ' + session.token } : {}) }, body: body ? JSON.stringify(body) : undefined });
    let data = null; try { data = await res.json(); } catch {}
    if (!res.ok) throw Object.assign(new Error(data?.error || `Server error ${res.status}`), { status: res.status });
    return data;
  }
  const saveSession = () => { try { session ? sessionStorage.setItem(LS.session, JSON.stringify(session)) : sessionStorage.removeItem(LS.session); } catch {} };
  function clearSession() { stopPolling(); session = null; room = null; lastJSON = ''; saveSession(); }
  async function enter(roomCode) {
    busy = true; error = null; render();
    try {
      const r = roomCode ? await api('POST', `/rooms/${roomCode}/join`, { name: nickname.trim(), avatar }) : await api('POST', '/rooms', { name: nickname.trim(), avatar });
      session = { code: r.room.code, token: r.token, memberID: r.memberID }; saveSession(); room = r.room; lastJSON = JSON.stringify(room);
      if (roomCode && me() && !me().ready) await setReady(true);   // guests become ready on entry
      startPolling();
    } catch (e) { error = describe(e); }
    busy = false; render();
  }
  async function refresh() {
    if (!session) return;
    try { const r = await api('GET', `/rooms/${session.code}`); reconnecting = false; const j = JSON.stringify(r.room); if (j !== lastJSON) { room = r.room; lastJSON = j; render(); } else if (card.dataset.reconnecting) render(); }
    catch (e) { if (e.status === 401 || e.status === 404) { clearSession(); entry = 'code'; error = e.message; render(); } else { if (!reconnecting) { reconnecting = true; render(); } } }
  }
  async function mutate(fn) { busy = true; error = null; render(); try { await fn(); await refresh(); } catch (e) { error = describe(e); } busy = false; render(); }
  const setReady = (v) => api('PATCH', `/rooms/${session.code}/me`, { ready: v });
  const toggleReady = () => mutate(() => setReady(!me()?.ready));
  const setLocked = () => mutate(() => api('PATCH', `/rooms/${session.code}`, { locked: !room.locked }));
  const start = () => mutate(() => api('PATCH', `/rooms/${session.code}`, { status: 'started' }));
  const reset = () => mutate(() => api('PATCH', `/rooms/${session.code}`, { status: 'waiting' }));
  const remove = (p) => mutate(() => api('DELETE', `/rooms/${session.code}/members/${p.id}`));
  async function leave() { busy = true; render(); try { await api('POST', `/rooms/${session.code}/leave`, {}); } catch {} clearSession(); busy = false; entry = 'code'; render(); }
  const startPolling = () => { stopPolling(); pollTimer = setInterval(refresh, 1200); };
  const stopPolling = () => { if (pollTimer) clearInterval(pollTimer); pollTimer = null; };
  async function connectionSettings() {
    const a = prompt('Server address — everyone needs the same server. The default is https://mecha-soonelians.vercel.app. For a local server, use http://localhost:3000 in Simulator or your Mac’s Wi‑Fi address on an iPhone.', server || location.origin); if (a == null) return;
    const url = a.trim().replace(/\/$/, '');
    try { const r = await fetch(url + '/health'); const d = await r.json(); if (d.status !== 'ok' || d.service !== 'rally') throw 0; server = url; put(LS.server, url); error = null; }
    catch { error = 'Couldn’t connect. Check the address and make sure the server is running.'; }
    render();
  }

  // ---------------- cards (HomeView.swift / LobbyView.swift)
  function open(step = null) { overlay.hidden = false; onOpen?.(); entry = step || entry; if (session) { render(); refresh().then(() => session && startPolling()); } else { if (entry === 'landing') entry = 'code'; render(); } }
  function close() { stopPolling(); overlay.hidden = true; menuOpen = false; onClose?.(); }
  function render() {
    card.innerHTML = ''; card.dataset.reconnecting = reconnecting ? '1' : '';
    if (session) { room ? lobbyCard() : reconnectCard(); return; }
    if (entry === 'host') identityCard(true, null); else if (entry === 'join') identityCard(false, code); else codeCard();
    if (error) card.append(h('div', { class: 'lb-notice', id: 'lobbyError' }, icon('exclaim'), h('span', {}, error)), h('button', { type: 'button', class: 'lb-link', style: 'text-align:left', onclick: connectionSettings }, 'Connection settings'));
  }
  function codeCard() {
    const input = h('input', { class: 'lb-code', inputmode: 'numeric', pattern: '[0-9]*', maxlength: '6', placeholder: '000000', value: code, 'aria-label': 'Room code', autocomplete: 'one-time-code' });
    const join = h('button', { type: 'button', class: 'lb-btn lb-full lb-display lb-spread', 'data-sfx': 'enter', disabled: code.length !== 6, onclick: () => { entry = 'join'; render(); } }, h('span', {}, 'Join'), icon('arrow', 20));
    input.addEventListener('input', () => { const v = input.value.replace(/\D/g, '').slice(0, 6); if (v !== input.value) input.value = v; code = v; join.disabled = code.length !== 6; });
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && code.length === 6) { e.preventDefault(); join.click(); } });
    card.append(h('h2', { class: 'lb-big', html: 'Mecha <b>Soonelians</b>' }), h('div', { class: 'lb-label lb-wide' }, 'Enter code'), input, join,
      h('div', { class: 'lb-row' }, h('button', { type: 'button', class: 'lb-link', onclick: () => { entry = 'host'; render(); } }, 'host a game'), h('button', { type: 'button', class: 'lb-link', onclick: close }, 'back')));
    setTimeout(() => input.focus(), 60);
  }
  function identityCard(creating, roomCode) {
    const name = h('input', { placeholder: 'Your nickname', maxlength: '20', autocomplete: 'nickname', value: nickname, 'aria-label': 'Nickname', disabled: busy });
    const go = h('button', { type: 'button', class: 'lb-btn lb-full', 'data-sfx': 'enter', disabled: busy || !validName(), onclick: () => enter(roomCode) }, h('span', {}, creating ? 'Create room' : 'Join room'), busy ? h('span', { class: 'lb-spinner' }) : '');
    name.addEventListener('input', () => { nickname = name.value; put(LS.name, nickname); go.disabled = busy || !validName(); });
    name.addEventListener('keydown', (e) => { if (e.key === 'Enter' && validName() && !busy) { e.preventDefault(); enter(roomCode); } });
    const colors = h('div', { class: 'lb-colors', role: 'radiogroup', 'aria-label': 'Pick a color' });
    COLORS.forEach((c, i) => colors.append(h('button', { type: 'button', role: 'radio', 'aria-checked': String(avatar === i), 'aria-pressed': String(avatar === i), 'aria-label': COLOR_NAMES[i] + ' avatar', disabled: busy,
      onclick: () => { avatar = i; put(LS.avatar, String(i)); [...colors.children].forEach((b, j) => { b.setAttribute('aria-pressed', String(i === j)); b.setAttribute('aria-checked', String(i === j)); b.firstChild.replaceChildren(i === j ? icon('check', 13) : ''); if (i === j) b.firstChild.style.color = j === 1 ? '#fff' : ''; }); } },
      h('span', { style: `background:${c}; color:${i === 1 ? '#fff' : ''}` }, avatar === i ? icon('check', 13) : ''))));
    card.append(h('h2', {}, creating ? 'Host a game' : 'Join the room'));
    if (roomCode) card.append(h('div', { class: 'lb-roomcode', 'aria-label': 'Room code ' + roomCode.split('').join(' ') }, roomCode));
    card.append(h('div', { class: 'lb-label' }, 'Your name'), name, h('div', { class: 'lb-hint' }, '1–20 characters'), h('div', { class: 'lb-label' }, 'Pick a color'), colors, go,
      h('div', { class: 'lb-row' }, h('button', { type: 'button', class: 'lb-btn lb-ghost', disabled: busy, onclick: () => { entry = 'code'; error = null; render(); } }, 'Back'),
        h('button', { type: 'button', class: 'lb-btn lb-ghost lb-icon', 'aria-label': 'Connection settings', disabled: busy, onclick: connectionSettings }, icon('network', 18))));
    if (!busy) setTimeout(() => name.focus(), 60);
  }
  function reconnectCard() {
    card.append(h('span', { class: 'lb-spinner lb-ink' }), h('h2', {}, reconnecting ? 'Reconnecting…' : 'Finding your room…'), h('div', { class: 'lb-hint', style: 'font-size:14px' }, 'You’ll return to your seat when the server responds.'),
      h('button', { type: 'button', class: 'lb-btn lb-danger lb-full', disabled: busy, onclick: leave }, 'Leave room'));
  }
  function lobbyCard() {
    const host = isHost(), started = room.status === 'started', n = room.members.length, readyCount = room.members.filter(m => m.ready).length, canStart = n >= 2 && readyCount === n && !started, mine = me();
    const menu = h('div', { class: 'lb-menu' });
    const list = h('ul', { hidden: !menuOpen });
    const item = (label, ic, fn, disabled = false) => h('li', {}, h('button', { type: 'button', disabled, onclick: () => { menuOpen = false; fn(); render(); } }, h('span', { style: 'display:inline-flex;align-items:center;gap:8px' }, icon(ic), label)));
    list.append(item('Share invite', 'share', shareInvite));
    if (host && !started) list.append(item(room.locked ? 'Unlock room' : 'Lock room', room.locked ? 'unlock' : 'lock', setLocked, busy || reconnecting));
    list.append(item(sfx?.muted ? 'Sound on' : 'Sound off', sfx?.muted ? 'note' : 'speakerSlash', () => { sfx?.toggleMute?.(); document.getElementById('sound')?.dispatchEvent(new Event('sfxchange')); }));
    menu.append(h('button', { type: 'button', 'aria-label': 'Room options', 'aria-expanded': String(menuOpen), onclick: () => { menuOpen = !menuOpen; list.hidden = !menuOpen; menu.firstChild.setAttribute('aria-expanded', String(menuOpen)); } }, '⋯'), list);
    card.append(h('div', { class: 'lb-row lb-top' }, h('h2', {}, started ? 'Game on!' : host ? 'Your room code' : `You’re in, ${mine?.name ?? 'friend'}!`), menu));
    if (!host && !started) card.append(h('div', { class: 'lb-ok' }, icon('clock'), h('span', {}, 'Waiting for the host to start…')));
    if (host || started) card.append(h('div', { class: 'lb-codebig', 'aria-label': 'Room code ' + room.code.split('').join(' ') }, room.code));
    else card.append(h('div', { class: 'lb-hint', style: 'font-size:14px' }, `Room ${displayCode(room.code)}`));
    const copy = h('button', { type: 'button', class: 'lb-link', style: 'display:inline-flex;align-items:center;gap:6px;text-decoration:none;font-size:12px', onclick: async () => { try { await navigator.clipboard.writeText(room.code); } catch {} copied = true; render(); } }, icon(copied ? 'check' : 'copy', 14), copied ? 'Copied' : 'Copy code');
    card.append(h('div', { class: 'lb-row lb-hint' }, h('span', { style: 'display:inline-flex;align-items:center;gap:10px' }, `${n} ${n === 1 ? 'player' : 'players'}`, room.locked ? h('span', { style: 'display:inline-flex;align-items:center;gap:4px' }, icon('lock', 13), 'Locked') : ''), copy));
    const players = h('div', { class: 'lb-players', style: `max-height:${Math.min(n * 60, 270)}px` });
    for (const p of room.members) {
      const row = h('div', { class: 'lb-player' }, h('span', { class: 'dot', style: `background:${COLORS[Math.min(5, Math.max(0, p.avatar))]}` }), h('span', { class: 'lb-name' }, p.name), p.id === mine?.id ? h('span', { class: 'you' }, 'you') : '');
      if (p.host) row.append(h('span', { class: 'host' }, 'Host'));
      else row.append(h('span', { class: 'state' + (p.ready ? ' ready' : ''), 'aria-label': p.ready ? 'Ready' : 'Getting ready' }, icon(p.ready ? 'checkfill' : 'clock', 18)));
      if (host && !p.host) row.append(h('button', { type: 'button', class: 'kick', 'aria-label': `Remove ${p.name}`, disabled: busy, onclick: () => { if (confirm(`Remove ${p.name}?`)) remove(p); } }, '✕'));
      players.append(row);
    }
    card.append(players);
    if (reconnecting) card.append(h('div', { class: 'lb-hint lb-13', style: 'display:flex;align-items:center;gap:6px' }, icon('wifi', 14), 'Reconnecting…'));
    if (error) card.append(h('div', { class: 'lb-notice' }, icon('exclaim'), h('span', {}, error)));
    if (started) {
      card.append(h('button', { type: 'button', class: 'lb-btn lb-full', disabled: true, title: 'Studio lives in the iPhone app' }, icon('viewfinder', 18), 'Open Studio'));
      if (host) card.append(h('button', { type: 'button', class: 'lb-btn lb-ghost lb-full', disabled: busy || reconnecting, onclick: reset }, 'Back to lobby'));
    } else if (host) card.append(h('div', { class: 'lb-hint lb-13' }, n < 2 ? 'Share your code to invite a friend.' : canStart ? 'Everyone is ready.' : `${readyCount} of ${n} ready.`));
    const actions = h('div', { class: 'lb-actions' }, h('button', { type: 'button', class: 'lb-btn lb-ghost', disabled: busy, onclick: () => { if (confirm(host ? 'End this room? Everyone will return to the join screen.' : 'Leave this room? You can join again with the same room code.')) leave(); } }, host ? 'End room' : 'Leave room'));
    if (!started) {
      if (host) actions.append(h('button', { type: 'button', class: 'lb-btn', disabled: !canStart || busy || reconnecting, onclick: start }, h('span', {}, 'Start game'), busy ? h('span', { class: 'lb-spinner' }) : ''));
      else actions.append(h('button', { type: 'button', class: 'lb-btn' + (mine?.ready ? ' lb-dark' : ''), disabled: busy || reconnecting, onclick: toggleReady, title: mine?.ready ? 'Tap to undo ready' : 'Tell the host you are ready' }, icon('check', 18), mine?.ready ? 'Ready' : 'I’m ready'));
    }
    card.append(actions);
  }
  async function shareInvite() {
    const text = `Join my room: ${displayCode(room.code)}\nrally://join/${room.code}`;
    try { if (navigator.share) await navigator.share({ text }); else { await navigator.clipboard.writeText(text); copied = true; } } catch {}
  }
  document.addEventListener('pointerdown', (e) => { if (menuOpen && !e.target.closest('.lb-menu')) { menuOpen = false; card.querySelector('.lb-menu ul')?.setAttribute('hidden', ''); } }, true);
  return { open, close, get session() { return session; }, get hasCard() { return !overlay.hidden; } };
}
