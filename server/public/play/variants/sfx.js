// Sound for the landing page: looping BGM (starts once the pile is full) + synthesized keyboard clicks.
// createSfx({ bgmSrc, bgmVolume }) → { startBgm, stopBgm, key(kind), toggleMute, get muted }
// Browsers block audio before the first user gesture, so startBgm() falls back to "start on first tap/key".
export function createSfx({ bgmSrc, bgmVolume = 0.5 } = {}) {
  const LS = 'mecha.muted';
  let muted = false;
  try { muted = localStorage.getItem(LS) === '1'; } catch {}

  // ---- BGM (HTMLAudio: cheap, loops, works on iOS inside a gesture) ----
  const bgm = new Audio(bgmSrc);
  bgm.loop = true; bgm.preload = 'auto'; bgm.volume = bgmVolume; bgm.muted = muted;
  let wantBgm = false, armed = false;
  const tryPlay = () => bgm.play().then(() => { wantBgm = true; }, () => arm());
  function arm() { // autoplay refused → start on the first gesture anywhere
    if (armed) return; armed = true;
    const go = () => { window.removeEventListener('pointerdown', go, true); window.removeEventListener('keydown', go, true); if (wantBgm) tryPlay(); };
    window.addEventListener('pointerdown', go, true); window.addEventListener('keydown', go, true);
  }
  function startBgm() { wantBgm = true; if (bgm.paused) tryPlay(); }
  function stopBgm() { wantBgm = false; bgm.pause(); bgm.currentTime = 0; }

  // ---- keyboard clicks (WebAudio synth, no sample needed) ----
  let ctx = null, master = null;
  function ac() {
    if (!ctx) { const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return null; ctx = new AC(); master = ctx.createGain(); master.gain.value = muted ? 0 : 1; master.connect(ctx.destination); }
    if (ctx.state === 'suspended') ctx.resume().catch(() => {});
    return ctx;
  }
  const P = { click: { f: 2600, body: 260, dur: .06, g: .35 }, type: { f: 3200, body: 330, dur: .045, g: .28 }, enter: { f: 1500, body: 170, dur: .09, g: .5 } };
  function key(kind = 'click') {
    const c = ac(); if (!c) return;
    const p = P[kind] || P.click, t = c.currentTime, jitter = 0.9 + Math.random() * 0.2;
    const buf = c.createBuffer(1, Math.ceil(c.sampleRate * p.dur), c.sampleRate), d = buf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / d.length, 2.5);
    const src = c.createBufferSource(); src.buffer = buf;
    const bp = c.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = p.f * jitter; bp.Q.value = 0.8;
    const g = c.createGain(); g.gain.setValueAtTime(p.g, t); g.gain.exponentialRampToValueAtTime(0.001, t + p.dur);
    src.connect(bp).connect(g).connect(master); src.start(t);
    const o = c.createOscillator(); o.type = 'sine'; const f0 = p.body * jitter;           // the "thock" of the key bottoming out
    o.frequency.setValueAtTime(f0, t); o.frequency.exponentialRampToValueAtTime(f0 * 0.5, t + 0.04);
    const og = c.createGain(); og.gain.setValueAtTime(0.22, t); og.gain.exponentialRampToValueAtTime(0.001, t + 0.05);
    o.connect(og).connect(master); o.start(t); o.stop(t + 0.06);
  }

  // every button / link-button gets a click, typing in inputs gets key taps (delegated: covers the lobby too)
  const SEL = 'button, [role="button"], input[type="submit"], a[href]';
  window.addEventListener('pointerdown', (e) => { if (e.target.closest && e.target.closest(SEL)) key('click'); }, true);
  window.addEventListener('keydown', (e) => {
    if (e.repeat || e.metaKey || e.ctrlKey || e.altKey) return;
    const el = e.target, inField = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA');
    if (e.key === 'Enter') { if (inField || (el.closest && el.closest(SEL))) key('enter'); return; }
    if (e.key === ' ' && el.closest && el.closest(SEL)) { key('click'); return; }
    if (inField && (e.key.length === 1 || e.key === 'Backspace' || e.key === 'Delete')) key('type');
  }, true);

  function setMuted(m) { muted = m; bgm.muted = m; if (master) master.gain.value = m ? 0 : 1; try { localStorage.setItem(LS, m ? '1' : '0'); } catch {} }
  return { startBgm, stopBgm, key, toggleMute: () => { setMuted(!muted); return muted; }, get muted() { return muted; }, bgm };
}
