/* A deliberately local prototype. No accounts, backend calls, or real rooms. */
'use strict';
const app = document.querySelector('#app');
const surface = document.querySelector('#app-surface');
const dialog = document.querySelector('#confirm-dialog');
const faceNames = ['Sunny', 'Cool', 'Peppy', 'Dreamer', 'Sprout', 'Peach'];
const state = { screen: 'home', name: '', avatar: 0, capacity: 8, code: '482916', role: 'host', locked: false, players: [], entry: 'create' };
let toastTimer;

const paths = {
  arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  diagonal: '<path d="M6 18 18 6M6 6h12v12"/>',
  down: '<path d="M18 6 6 18M6 6v12h12"/>',
  back: '<path d="m14 6-6 6 6 6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  settings: '<path d="M4 7h9m4 0h3M4 17h3m4 0h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="3"/><path d="M15 5V4H4v11h1"/>',
  share: '<path d="M12 15V3m-4 4 4-4 4 4M7 10H4v11h16V10h-3"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  crown: '<path d="m3 7 5 4 4-7 4 7 5-4-2 13H5L3 7Z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>',
  smile: '<circle cx="12" cy="12" r="9"/><path d="M8 14q4 5 8 0M8 8v2m8-2v2"/>',
  people: '<path d="M3 21v-3a5 5 0 0 1 10 0v3m2-7a5 5 0 0 1 6 4v3"/><circle cx="8" cy="6" r="4"/><path d="M16 2a4 4 0 0 1 0 8"/>',
  star: '<path d="m12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5L12 2Z"/>',
};
function icon(name) { return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.arrow}</svg>`; }
function escapeHTML(value) { return String(value).replace(/[&<>"']/g, x => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[x])); }
function avatar(index, extra = '') { return `<span class="avatar ${extra}" data-face="${index}" aria-hidden="true"><span class="face"><span class="eyes"></span><span class="mouth"></span></span></span>`; }
function brand() { return '<span class="wordmark"><svg viewBox="0 0 32 32" aria-hidden="true"><g stroke="currentColor" stroke-width="5.5" stroke-linecap="round"><path d="M16 4v24M5.6 10l20.8 12M5.6 22l20.8-12"/></g></svg>rally</span>'; }
function formattedCode() { return state.code.slice(0, 3) + ' ' + state.code.slice(3); }
function toast(message) {
  const box = document.querySelector('#toast');
  box.textContent = message;
  box.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => box.classList.remove('show'), 3200);
}
function navigate(screen) {
  state.screen = screen;
  render();
  window.scrollTo({ top: 0, behavior: 'instant' });
  const heading = app.querySelector('h2');
  if (heading) { heading.tabIndex = -1; heading.focus({ preventScroll: true }); }
}
function fixture(role) {
  state.role = role;
  state.code = '482916';
  state.locked = false;
  state.players = role === 'host'
    ? [{ name: state.name || 'Kai', avatar: state.avatar, host: true, ready: true, me: true }, { name: 'Maya', avatar: 1, ready: true }, { name: 'Alex', avatar: 2, ready: false }]
    : [{ name: 'Maya', avatar: 1, host: true, ready: true }, { name: 'Alex', avatar: 2, ready: true }, { name: state.name || 'Kai', avatar: state.avatar, ready: false, me: true }];
}
function render() {
  const inRoom = state.screen === 'lobby' || state.screen === 'started';
  const nav = state.screen === 'profile' && state.entry === 'create' ? 'create' : 'home';
  document.querySelectorAll('.mobile-navigation, .screen-navigation').forEach(navigation => {
    navigation.hidden = inRoom;
  });
  document.querySelectorAll('[data-screen]').forEach(button => {
    if (button.dataset.screen === nav) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  document.querySelector('.mobile-navigation').style.setProperty('--active-index', nav === 'create' ? 1 : 0);
  document.querySelector('#prototype-controls').hidden = state.screen !== 'lobby';
  app.innerHTML = ({ home: home, profile: profile, lobby: lobby, started: started, settings: settings }[state.screen] || home)();
  document.querySelector('#toast').classList.remove('show');
  document.querySelector('#toast').textContent = '';
}
function home() {
  return `<section class="screen home-screen">
    <div class="app-header">${brand()}</div>
    <div class="home-title"><h2>A little code.<br>A whole crew.</h2></div>
    <div class="crew-art" aria-hidden="true">${avatar(1)}${avatar(2)}${avatar(0)}<span class="art-spark">${icon('star')}</span><span class="art-plus">+</span></div>
    <form class="join-card" id="join-form" novalidate>
      <div class="card-title"><h3>Got a room code?</h3>${icon('down')}</div>
      <label class="sr-only" for="room-code">Room code</label>
      <input class="code-input" id="room-code" name="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" placeholder="000000" autocomplete="off" aria-describedby="code-hint">
      <button class="btn spread" type="submit">Join the room ${icon('arrow')}</button>
      <p class="helper" id="code-hint" role="status" hidden></p>
    </form>
  </section>`;
}
function profile() {
  const creating = state.entry === 'create';
  return `<section class="screen profile-screen" aria-label="${creating ? 'Create a room' : 'Join a room'}">
    ${creating ? '' : `<div class="back-header"><button class="icon-button" data-action="home" aria-label="Back to welcome">${icon('back')}</button><button class="text-button" data-action="home">Cancel</button></div>
    <div class="screen-title"><h2>Join room ${formattedCode()}</h2></div>`}
    <div class="profile-hero" id="profile-avatar">${avatar(state.avatar)}</div>
    <form id="profile-form" novalidate>
      <div class="field-group"><span class="field-label" id="face-label">Pick your face</span><div class="avatar-options" role="group" aria-labelledby="face-label">${faceNames.map((name, i) => `<button type="button" class="avatar-option" data-avatar="${i}" aria-label="${name} avatar" aria-pressed="${state.avatar === i}">${avatar(i)}</button>`).join('')}</div></div>
      <div class="field-group"><label class="field-label" for="nickname">Nickname</label><input class="name-input" id="nickname" name="nickname" placeholder="Your nickname" value="${escapeHTML(state.name)}" maxlength="20" autocomplete="nickname" aria-describedby="name-hint"><p class="helper" id="name-hint">1–20 characters</p></div>
      ${creating ? `<div class="field-group"><span class="field-label" id="size-label">Room size</span><div class="size-options" role="group" aria-labelledby="size-label">${[4, 8, 12, 20].map(n => `<button type="button" data-capacity="${n}" aria-pressed="${state.capacity === n}">${n}</button>`).join('')}</div></div>` : ''}
      <button class="btn spread" type="submit">${creating ? 'Create room' : 'Join room'}${icon('arrow')}</button>
    </form>
  </section>`;
}
function lobby() {
  const host = state.role === 'host';
  const readyCount = state.players.filter(p => p.ready).length;
  const canStart = state.players.length >= 2 && readyCount === state.players.length;
  const me = state.players.find(p => p.me);
  return `<section class="screen lobby-screen" aria-label="Lobby">
    <div class="app-header">${brand()}</div>
    <div class="code-ticket"><p class="eyebrow">${state.locked ? 'ROOM LOCKED' : 'ROOM CODE'}</p><div class="room-code">${formattedCode()}</div><div class="ticket-actions"><button data-action="copy">${icon('copy')}Copy code</button><button data-action="share">${icon('share')}Share invite</button></div></div>
    <div class="crew-heading"><h3>Players</h3><span class="count">${state.players.length}/${state.capacity}</span></div>
    <div class="player-grid">${state.players.map((player, index) => `<div class="player-tile">${host && !player.me ? `<button class="remove-player" data-remove="${index}" aria-label="Remove ${escapeHTML(player.name)}">×</button>` : ''}${avatar(player.avatar)}<div class="player-name">${escapeHTML(player.name)} ${player.me ? '<small>(you)</small>' : ''}</div><span class="player-status ${player.ready ? 'is-ready' : ''}">${icon(player.host ? 'crown' : player.ready ? 'check' : 'clock')}${player.host ? 'Host' : player.ready ? 'Ready to go' : 'Getting ready'}</span></div>`).join('')}${state.players.length < state.capacity ? '<div class="player-tile empty"><span class="empty-seat">+</span></div>' : ''}</div>
    <div class="lobby-bottom">${host ? `<div class="room-lock-row"><div><label id="lock-label">Lock the room</label></div><button class="toggle" role="switch" aria-checked="${state.locked}" aria-labelledby="lock-label" data-action="lock"></button></div><button class="btn spread" data-action="start" ${canStart ? '' : 'disabled'}>Start session ${icon('arrow')}</button><p class="fine-print">${state.players.length < 2 ? 'At least 2 players required.' : canStart ? 'Everyone is ready.' : `${readyCount} of ${state.players.length} ready.`}</p>` : `<div class="waiting-note">${icon('clock')}<div><strong>Waiting for the host</strong></div></div><button class="btn ${me.ready ? 'btn-ink' : ''}" data-action="ready">${icon('check')}${me.ready ? 'Ready · tap to undo' : 'I’m ready'}</button>`}
    <button class="text-button end-room" data-action="leave">${host ? 'End room' : 'Leave room'}</button></div>
  </section>`;
}
function started() {
  return `<section class="screen started-screen"><div class="app-header">${brand()}</div><div class="started-content">${avatar(0)}<h2>Session started</h2><p>${state.players.length} players</p><span class="started-badge">${icon('check')}Room ${formattedCode()}</span></div><button class="btn spread" data-action="back-lobby">Back to lobby ${icon('arrow')}</button></section>`;
}
function settings() {
  return `<section class="screen settings-screen"><div class="back-header"><button class="icon-button" data-action="home" aria-label="Back to welcome">${icon('back')}</button><button class="text-button" data-action="home">Done</button></div><h2>About this preview</h2><div class="info-card"><h3>Sample data</h3><p>Rooms and players are simulated. Use code 482916 to join the sample room.</p></div><div class="info-card"><h3>Simulation controls</h3><p>The buttons below the lobby add players and mark them ready.</p></div><button class="btn" data-action="home">Back to home</button></section>`;
}

document.addEventListener('click', async event => {
  const button = event.target.closest('button');
  if (!button || button.disabled) return;
  if (button.dataset.screen) {
    const screen = button.dataset.screen;
    if (screen === 'home') navigate('home');
    if (screen === 'create') { state.entry = 'create'; navigate('profile'); }
    return;
  }
  if (button.dataset.width) {
    document.documentElement.style.setProperty('--preview-width', `${button.dataset.width}px`);
    document.querySelector('.workbench').classList.toggle('wide-preview', button.dataset.width === '768');
    document.querySelector('#viewport-label').textContent = `${button.dataset.width} PT · ${button.dataset.width === '768' ? 'IPAD' : 'IPHONE'} LAYOUT`;
    document.querySelectorAll('[data-width]').forEach(b => b.removeAttribute('aria-pressed'));
    button.setAttribute('aria-pressed', 'true');
    return;
  }
  if (button.dataset.avatar !== undefined) {
    state.avatar = Number(button.dataset.avatar);
    document.querySelector('#profile-avatar').innerHTML = avatar(state.avatar);
    document.querySelectorAll('[data-avatar]').forEach(b => b.setAttribute('aria-pressed', String(Number(b.dataset.avatar) === state.avatar)));
    return;
  }
  if (button.dataset.capacity) {
    state.capacity = Number(button.dataset.capacity);
    document.querySelectorAll('[data-capacity]').forEach(b => b.setAttribute('aria-pressed', String(Number(b.dataset.capacity) === state.capacity)));
    return;
  }
  if (button.dataset.remove !== undefined) {
    const name = state.players[Number(button.dataset.remove)].name;
    state.players.splice(Number(button.dataset.remove), 1);
    render(); toast(`${name} left the room.`); return;
  }
  switch (button.dataset.action) {
    case 'reset': Object.assign(state, { name: '', avatar: 0, capacity: 8, locked: false, players: [], code: '482916', role: 'host' }); navigate('home'); break;
    case 'home': navigate('home'); break;
    case 'settings': navigate('settings'); break;
    case 'create': state.entry = 'create'; navigate('profile'); break;
    case 'copy':
      try { await navigator.clipboard.writeText(state.code); toast('Room code copied. Pass it around.'); }
      catch { toast(`Room code: ${formattedCode()}`); }
      break;
    case 'share':
      try { await navigator.clipboard.writeText(`Join my Rally room: ${formattedCode()} (design preview)`); toast('Invite copied. Send it to your people.'); }
      catch { toast(`Invite your friends with code ${formattedCode()}.`); }
      break;
    case 'lock': state.locked = !state.locked; render(); toast(state.locked ? 'Room locked. Just your crew.' : 'Room unlocked. Come on in.'); break;
    case 'ready': { const me = state.players.find(p => p.me); me.ready = !me.ready; render(); break; }
    case 'start': if (state.players.length >= 2 && state.players.every(p => p.ready)) navigate('started'); break;
    case 'back-lobby': state.locked = false; state.players.forEach(p => p.ready = !!p.host); navigate('lobby'); break;
    case 'add-player': {
      if (state.locked) { toast('The room is locked. Unlock it to let someone in.'); break; }
      if (state.players.length >= state.capacity) { toast('Every spot is taken. This room is full.'); break; }
      const names = ['Maya', 'Alex', 'Jules', 'Sam', 'Robin', 'Remy', 'Casey', 'Ari', 'Noah', 'Quinn', 'Jamie', 'River', 'Blair', 'Reese', 'Sky', 'Drew', 'Lee', 'Ash', 'Cameron'];
      const name = names.find(n => !state.players.some(p => p.name === n)) || 'Friend';
      state.players.push({ name, avatar: state.players.length % 6, ready: false });
      render(); toast(`${name} just joined. The crew is growing.`); break;
    }
    case 'ready-all': state.players.forEach(p => p.ready = true); render(); toast('Everyone’s ready to go.'); break;
    case 'leave':
      document.querySelector('#dialog-title').textContent = state.role === 'host' ? 'End this room?' : 'Heading out?';
      document.querySelector('#dialog-description').textContent = state.role === 'host' ? 'Everyone will return to the welcome screen.' : 'You can join again with the same room code.';
      document.querySelector('#confirm-leave').textContent = state.role === 'host' ? 'End room' : 'Leave room';
      dialog.showModal(); break;
    case 'cancel-leave': dialog.close(); break;
    case 'confirm-leave': dialog.close(); state.players = []; navigate('home'); break;
  }
});

document.addEventListener('input', event => {
  if (event.target.id === 'room-code') {
    event.target.value = event.target.value.replace(/\D/g, '').slice(0, 6);
    event.target.removeAttribute('aria-invalid');
    const hint = document.querySelector('#code-hint');
    hint.classList.remove('error');
    hint.textContent = '';
    hint.hidden = true;
  }
  if (event.target.id === 'nickname') {
    state.name = event.target.value;
    event.target.removeAttribute('aria-invalid');
    document.querySelector('#name-hint').classList.remove('error');
    document.querySelector('#name-hint').textContent = '1–20 characters';
  }
});

document.addEventListener('submit', event => {
  event.preventDefault();
  if (event.target.id === 'join-form') {
    const input = document.querySelector('#room-code');
    if (input.value !== '482916') {
      input.setAttribute('aria-invalid', 'true');
      const hint = document.querySelector('#code-hint');
      hint.hidden = false;
      hint.textContent = input.value.length !== 6 ? 'Room codes have 6 digits. Try 482916.' : 'This preview uses room 482916. Give that a try.';
      hint.classList.add('error'); input.focus(); return;
    }
    state.code = input.value; state.entry = 'join'; navigate('profile');
  }
  if (event.target.id === 'profile-form') {
    state.name = document.querySelector('#nickname').value.trim();
    if (!state.name || [...state.name].length > 20 || /[\p{Cc}\p{Cf}]/u.test(state.name)) {
      const hint = document.querySelector('#name-hint'); hint.textContent = 'Choose a name between 1 and 20 characters.'; hint.classList.add('error'); document.querySelector('#nickname').focus(); return;
    }
    if (state.entry === 'join' && ['maya', 'alex'].includes(state.name.toLowerCase())) {
      const hint = document.querySelector('#name-hint'); hint.textContent = 'That name is taken. Try another.'; hint.classList.add('error'); return;
    }
    if (state.entry === 'create') {
      state.role = 'host'; state.code = '482916'; state.locked = false;
      state.players = [{ name: state.name, avatar: state.avatar, host: true, ready: true, me: true }];
    } else fixture('guest');
    navigate('lobby');
  }
});
dialog.addEventListener('click', event => { if (event.target === dialog) dialog.close(); });
render();
