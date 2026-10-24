// Shared Join / Host lobby. Talks to the Rally server (POST /rooms, /rooms/:code/join, GET /rooms/:code, PATCH …);
// when no server answers it runs a demo room so the design can be reviewed anywhere.
export function createLobby({ overlay, onOpen, onClose, demoNames = ['Kai', 'Ryushen', 'Balawal'] } = {}) {
  const API = new URLSearchParams(location.search).get('server')?.replace(/\/$/, '') || '';
  const AVATARS = ['#c6ff4a', '#4a63ff', '#ff7d8a', '#ffb86b', '#7df0b3', '#d58cff'];
  const card = document.createElement('div'); card.className = 'lb-card'; overlay.className = 'lb-overlay'; overlay.append(card); overlay.hidden = true;
  let session = null, lastRoom = null, pollTimer = null, demo = null;
  try { session = JSON.parse(sessionStorage.getItem('mecha.session') || 'null'); } catch {}
  const save = () => { try { session ? sessionStorage.setItem('mecha.session', JSON.stringify(session)) : sessionStorage.removeItem('mecha.session'); } catch {} };
  const h = (tag, attrs = {}, ...kids) => { const el = document.createElement(tag); for (const [k, v] of Object.entries(attrs)) { if (v == null) continue; if (k === 'class') el.className = v; else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else el.setAttribute(k, v); } el.append(...kids); return el; };

  // ---- demo backend (same shapes as the Rally server)
  function demoApi(method, path, body) {
    demo ??= { rooms: {} };
    const code = path.match(/\/rooms\/(\d{6})/)?.[1];
    const room = code && demo.rooms[code];
    if (method === 'POST' && path === '/rooms') {
      const c = String(100000 + Math.floor(Math.random() * 900000));
      const me = { id: 'me-' + c, name: body.name, avatar: body.avatar, host: true, ready: true };
      demo.rooms[c] = { code: c, locked: false, status: 'waiting', members: [me], t: 0 };
      return { room: demo.rooms[c], memberID: me.id, token: 'demo' };
    }
    if (!room) { if (method === 'POST' && path.endsWith('/join')) { const c2 = code; const host = { id: 'h', name: 'Host', avatar: 2, host: true, ready: true }; demo.rooms[c2] = { code: c2, locked: false, status: 'waiting', members: [host], t: 0 }; return demoApi(method, path, body); } throw Object.assign(new Error('Room not found (demo).'), { status: 404 }); }
    if (method === 'POST' && path.endsWith('/join')) { const me = { id: 'me-' + Math.random().toString(36).slice(2), name: body.name, avatar: body.avatar, host: false, ready: true }; room.members.push(me); return { room, memberID: me.id, token: 'demo' }; }
    if (method === 'GET') { room.t++; if (room.status === 'waiting' && room.t % 2 === 0 && room.members.length < 4) { const n = demoNames[room.members.length - 1]; if (n && !room.members.some(m => m.name === n)) room.members.push({ id: 'd' + room.t, name: n, avatar: room.members.length % 6, host: false, ready: true }); } return { room }; }
    if (method === 'PATCH' && !path.endsWith('/me')) { if (body.status === 'started') room.status = 'started'; return { room }; }
    return { ok: true };
  }
  let useDemo = false;
  async function api(method, path, body, token) {
    if (useDemo) return demoApi(method, path, body);
    let res;
    try { res = await fetch(API + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined }); }
    catch { useDemo = true; return demoApi(method, path, body); }
    if (res.status === 404 && !path.match(/\/rooms\/\d{6}/)) { useDemo = true; return demoApi(method, path, body); }
    let data = null; try { data = await res.json(); } catch {}
    if (!res.ok) throw Object.assign(new Error(data?.error || `Server error ${res.status}`), { status: res.status });
    return data;
  }

  function open(step = null, state = {}) { overlay.hidden = false; onOpen?.(); show(step ?? (session ? (session.host ? 'host' : 'joined') : 'choose'), state); if (session && !step) { poll().then(() => session && startPolling()); } }
  function close() { overlay.hidden = true; onClose?.(); }

  function show(step, state = {}) {
    card.innerHTML = '';
    const err = h('div', { class: 'lb-err' }); const fail = (e) => { err.textContent = e.message || String(e); };
    if (step === 'choose') {
      card.append(h('h2', {}, 'Ready to disappear?'), h('p', {}, '一台手机当主机建房间，其他人用 6 位房间码加入，像 Kahoot 一样。'),
        h('div', { class: 'lb-choice' }, h('button', { type: 'button', onclick: () => show('name', { mode: 'join' }) }, 'Join a game', h('span', {}, '输入房间码')), h('button', { type: 'button', class: 'lb-alt', onclick: () => show('name', { mode: 'host' }) }, 'Host a game', h('span', {}, '创建房间'))),
        h('div', { class: 'lb-actions' }, h('button', { type: 'button', class: 'lb-ghost', onclick: close }, '返回')));
    } else if (step === 'name') {
      const join = state.mode === 'join'; let avatar = Math.floor(Math.random() * 6);
      const name = h('input', { maxlength: '20', placeholder: '你的名字', autocomplete: 'nickname', value: session?.name || '' });
      const code = h('input', { class: 'lb-code', inputmode: 'numeric', pattern: '[0-9]*', maxlength: '6', placeholder: '000000', value: state.code || '' });
      const avatars = h('div', { class: 'lb-avatars' });
      AVATARS.forEach((c, i) => avatars.append(h('button', { type: 'button', style: `background:${c}`, 'aria-label': `avatar ${i + 1}`, class: i === avatar ? 'on' : '', onclick: () => { avatar = i; [...avatars.children].forEach((x, j) => x.classList.toggle('on', j === i)); } })));
      const go = h('button', { type: 'button', onclick: async () => {
        const n = name.value.trim(); if (!n) return fail(new Error('先起个名字。'));
        if (join && !/^\d{6}$/.test(code.value)) return fail(new Error('房间码是 6 位数字。'));
        go.disabled = true; err.textContent = '';
        try {
          const r = join ? await api('POST', `/rooms/${code.value}/join`, { name: n, avatar }) : await api('POST', '/rooms', { name: n, avatar });
          session = { code: r.room.code, token: r.token, memberID: r.memberID, name: n, host: !join }; save();
          if (join) { try { await api('PATCH', `/rooms/${session.code}/me`, { ready: true }, session.token); } catch {} }
          lastRoom = r.room; show(join ? 'joined' : 'host'); startPolling();
        } catch (e) { fail(e); go.disabled = false; }
      } }, join ? 'Join' : 'Create room');
      card.append(h('h2', {}, join ? 'Join a game' : 'Host a game'), h('label', {}, 'Name'), name);
      if (join) card.append(h('label', {}, 'Room code'), code);
      card.append(h('label', {}, 'Avatar'), avatars, err, h('div', { class: 'lb-actions' }, h('button', { type: 'button', class: 'lb-ghost', onclick: () => show('choose') }, '返回'), go));
      setTimeout(() => (join && !state.code ? code : name).focus(), 50);
    } else {
      const room = lastRoom, hostM = room?.members.find(m => m.host), count = room?.members.length || 0;
      const list = h('div', { class: 'lb-players' });
      for (const m of room?.members || []) list.append(h('div', { class: 'lb-player' }, h('span', { class: 'dot', style: `background:${AVATARS[m.avatar] || '#999'}` }), h('span', {}, m.name + (m.id === session.memberID ? '（你）' : '')), m.host ? h('span', { class: 'host' }, 'HOST') : h('span', { class: 'wait' }, m.ready ? 'ready' : '…')));
      if (room?.status === 'started') card.append(h('h2', {}, 'Game on! 🎮'), h('p', {}, `房间 ${session.code} 已开始。打开 Mecha Soonelians App 继续。`), list, h('div', { class: 'lb-actions' }, h('button', { type: 'button', class: 'lb-ghost', onclick: leave }, '离开')));
      else if (step === 'host') {
        const start = h('button', { type: 'button', onclick: async () => { start.disabled = true; try { await api('PATCH', `/rooms/${session.code}`, { status: 'started' }, session.token); await poll(); } catch (e) { fail(e); start.disabled = false; } } }, 'Start game');
        start.disabled = count < 2;
        card.append(h('h2', {}, 'Your room code'), h('div', { class: 'lb-codebig' }, session.code), h('p', {}, `让大家打开这个页面，点 Join a game 输入房间码。${count} 人在房间里。`), list, err, h('div', { class: 'lb-actions' }, h('button', { type: 'button', class: 'lb-ghost', onclick: leave }, 'End room'), start));
      } else card.append(h('h2', {}, `You're in, ${session.name}!`), h('div', { class: 'lb-waiting' }, h('span', { class: 'lb-spinner' }), h('span', {}, `等 ${hostM?.name || '主机'} 开始…`)), h('p', {}, `房间 ${session.code} · ${count} 人`), list, err, h('div', { class: 'lb-actions' }, h('button', { type: 'button', class: 'lb-ghost', onclick: leave }, 'Leave')));
    }
    card.append(h('div', { class: 'lb-srv' }, useDemo ? 'demo mode · 没有连到服务器，房间是模拟的' : `server: ${API || location.origin}`));
  }
  async function poll() {
    if (!session) return;
    try { const r = await api('GET', `/rooms/${session.code}`, null, session.token); const changed = JSON.stringify(r.room) !== JSON.stringify(lastRoom); lastRoom = r.room; if (changed) show(session.host ? 'host' : 'joined'); }
    catch (e) { if (e.status === 401 || e.status === 404) { stopPolling(); session = null; save(); show('choose'); card.querySelector('.lb-err')?.replaceChildren(e.message); } }
  }
  const startPolling = () => { stopPolling(); pollTimer = setInterval(poll, 1500); };
  const stopPolling = () => { if (pollTimer) clearInterval(pollTimer); pollTimer = null; };
  async function leave() { stopPolling(); try { await api('POST', `/rooms/${session.code}/leave`, {}, session.token); } catch {} session = null; lastRoom = null; save(); show('choose'); }
  return { open, close, get session() { return session; } };
}
