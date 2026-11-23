/* Morphlo — site interactions. Vanilla JS, no dependencies. */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const ease = (t) => 1 - Math.pow(1 - t, 3);
  document.documentElement.classList.add('js');

  /* ---------- nav border on scroll ---------- */
  const nav = $('.nav');
  const onScroll = () => nav && nav.classList.toggle('scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  /* ---------- scroll reveal ---------- */
  const reveals = $$('.reveal');
  if ('IntersectionObserver' in window && !reduce) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add('in'));
  }

  /* ---------- copy buttons ---------- */
  function legacyCopy(text) {
    return new Promise((resolve, reject) => {
      const ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy') ? resolve() : reject(new Error('copy failed')); } catch (err) { reject(err); }
      ta.remove();
    });
  }
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text).catch(() => legacyCopy(text));
    return legacyCopy(text);
  }
  function selectCode(btn) { // last resort: select the command so ⌘C works
    const code = btn.parentElement && btn.parentElement.querySelector('code');
    const sel = window.getSelection && window.getSelection();
    if (!code || !sel) return;
    const range = document.createRange();
    range.selectNodeContents(code);
    sel.removeAllRanges(); sel.addRange(range);
  }
  $$('[data-copy]').forEach((btn) => {
    const lbl = $('.copy-lbl', btn);
    let t;
    btn.addEventListener('click', () => {
      copyText(btn.dataset.copy).then(() => {
        btn.classList.add('copied');
        if (lbl) lbl.textContent = 'Copied';
        clearTimeout(t);
        t = setTimeout(() => { btn.classList.remove('copied'); if (lbl) lbl.textContent = 'Copy'; }, 1600);
      }).catch(() => {
        selectCode(btn);
        if (lbl) lbl.textContent = 'Press ⌘C';
        clearTimeout(t);
        t = setTimeout(() => { if (lbl) lbl.textContent = 'Copy'; }, 2400);
      });
    });
  });

  /* ---------- generic tabs (install) ---------- */
  const itabs = $$('.itab');
  function selectTab(tab) {
    itabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      const panel = document.getElementById(t.getAttribute('aria-controls'));
      if (panel) panel.hidden = !on;
    });
  }
  itabs.forEach((t, i) => {
    t.addEventListener('click', () => selectTab(t));
    t.addEventListener('keydown', (e) => {
      const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!d) return;
      e.preventDefault();
      const next = itabs[(i + d + itabs.length) % itabs.length];
      next.focus(); selectTab(next);
    });
  });

  /* ---------- FAQ: one open at a time ---------- */
  const faqs = $$('.faq details');
  faqs.forEach((d) => d.addEventListener('toggle', () => {
    if (d.open) faqs.forEach((o) => { if (o !== d) o.open = false; });
  }));

  /* =====================================================
     DRAG DEMO
     ===================================================== */
  const demo = $('#demo');
  if (demo) initDemo(demo);

  function initDemo(demo) {
    const scene = $('#scene'), chat = $('#chat'), thread = $('#thread'), toast = $('#toast');
    const ghost = $('#ghost'), gThumb = $('.g-thumb', ghost), gBase = $('.g-base', ghost), gExt = $('.g-ext', ghost);
    const cursor = $('#cursor'), sw = $('#demo-switch'), state = $('#demo-state'), live = $('#demo-live');
    const tiles = { heic: $('.tile[data-kind="heic"]', demo), mov: $('.tile[data-kind="mov"]', demo) };
    const FILES = {
      heic: { base: 'IMG_0464', ext: '.HEIC', bg: 'g2' },
      mov: { base: 'IMG_0465', ext: '.MOV', bg: 'g4' }
    };
    let on = false, drag = null, morphed = false, toastT, replyT;

    function setOn(v) {
      on = v;
      sw.setAttribute('aria-checked', String(v));
      demo.classList.toggle('is-on', v);
      state.textContent = v ? 'On' : 'Off';
      sw.classList.remove('pulse'); void sw.offsetWidth; if (v) sw.classList.add('pulse');
    }
    function resetThread() {
      clearTimeout(replyT); clearTimeout(toastT);
      toast.classList.remove('show');
      thread.innerHTML = '<p class="empty mono">Drop a photo or video here</p>';
    }

    const sceneRect = () => scene.getBoundingClientRect();
    function centerOf(el) {
      const r = el.getBoundingClientRect(), s = sceneRect();
      return [r.left - s.left + r.width / 2, r.top - s.top + r.height / 2];
    }
    function overChat(x, y) { // scene-relative coords
      const r = chat.getBoundingClientRect(), s = sceneRect();
      const cx = x + s.left, cy = y + s.top;
      return cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom;
    }
    function placeGhost(x, y) { ghost.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%) rotate(-3deg)`; }

    function startGhost(kind, x, y) {
      const f = FILES[kind];
      morphed = false;
      ghost.className = 'ghost show';
      gThumb.className = 'g-thumb ' + f.bg;
      gBase.textContent = f.base; gExt.textContent = f.ext; gExt.className = 'g-ext';
      placeGhost(x, y);
    }
    function moveGhost(kind, x, y, dist) {
      placeGhost(x, y);
      chat.classList.toggle('hot', overChat(x, y));
      if (on && !morphed && dist > 46) {
        morphed = true;
        if (kind === 'heic') {
          gExt.textContent = '.jpg';
          ghost.classList.add('morphed');
          gExt.classList.add('flash');
        } else {
          ghost.classList.add('full');
        }
      }
    }
    function hideGhost() { ghost.className = 'ghost'; chat.classList.remove('hot'); }
    function release(kind, x, y) {
      const hit = overChat(x, y);
      chat.classList.remove('hot');
      ghost.classList.add('drop');
      setTimeout(hideGhost, 200);
      if (hit) deliver(kind);
    }

    function say(text) { live.textContent = text; }
    function reply(text, ms) { // neutral upload status line, not an AI quote
      replyT = setTimeout(() => {
        const p = document.createElement('div');
        p.className = 'msg sys mono';
        p.textContent = text;
        thread.appendChild(p);
      }, ms);
    }
    function deliver(kind) {
      resetThread();
      thread.innerHTML = '';
      let html;
      if (!on && kind === 'heic') {
        html = `<div class="att broken"><div class="att-th">?</div><div class="att-meta mono"><span class="n">IMG_0464.HEIC</span><span class="s">upload failed</span></div></div>`;
        toast.textContent = 'Unsupported file type (.heic)';
        requestAnimationFrame(() => toast.classList.add('show'));
        toastT = setTimeout(() => toast.classList.remove('show'), 2800);
        say('Without Morphlo: the chat rejects the HEIC photo. Unsupported file type.');
      } else if (!on) {
        html = `<div class="att still"><div class="att-th g4"></div><div class="att-meta mono"><span class="n">IMG_0465.MOV</span><span class="s">still image only</span></div></div>`;
        reply('IMG_0465.MOV · 1 frame · still image · uploaded', 700);
        say('Without Morphlo: the video arrives as one still frame.');
      } else if (kind === 'heic') {
        html = `<div class="att ok"><div class="att-th g2"><span class="ok-badge"><svg><use href="#i-check"/></svg></span></div><div class="att-meta mono"><span class="n">IMG_0464.jpg</span><span class="s">full-quality JPEG</span></div></div>`;
        reply('IMG_0464.jpg · 2.1 MB · uploaded', 800);
        say('With Morphlo: the photo arrives as a full-quality JPEG.');
      } else {
        html = `<div class="att vid"><div class="att-th g4"><span class="play"></span></div><div class="vbar mono"><span class="bar"><i></i></span><span>0:18</span></div><div class="vtag mono"><span>IMG_0465.MOV</span><span class="s">full video + audio</span></div></div>`;
        reply('IMG_0465.MOV · 0:18 · video + audio · uploaded', 900);
        say('With Morphlo: the full 18 second video with audio arrives.');
      }
      thread.insertAdjacentHTML('beforeend', `<div class="msg">${html}</div>`);
    }

    /* --- autoplay --- */
    let token = 0, idleT, visible = false, cur = [40, 60];
    function placeCursor(x, y) { cur = [x, y]; cursor.style.transform = `translate(${x - 2}px, ${y - 1}px)`; }
    function stopAuto() {
      token++;
      clearTimeout(idleT);
      if (demo.classList.contains('auto')) { hideGhost(); tiles.heic.classList.remove('lifted'); tiles.mov.classList.remove('lifted'); }
      demo.classList.remove('auto');
      cursor.classList.remove('show');
    }
    function scheduleAuto(ms) {
      clearTimeout(idleT);
      if (reduce) return;
      idleT = setTimeout(() => { if (visible && !drag) runAuto(); }, ms);
    }
    function tween(from, to, ms, my, fn) {
      return new Promise((resolve) => {
        const t0 = performance.now();
        const step = (now) => {
          if (my !== token) return resolve(false);
          const t = Math.min(1, (now - t0) / ms), k = ease(t);
          fn(from[0] + (to[0] - from[0]) * k, from[1] + (to[1] - from[1]) * k, t);
          if (t < 1) requestAnimationFrame(step); else resolve(true);
        };
        requestAnimationFrame(step);
      });
    }
    async function autoDrag(kind, my) {
      const tile = tiles[kind];
      const a = centerOf(tile), b = centerOf(thread);
      if (!(await tween(cur, a, 650, my, placeCursor))) return false;
      await sleep(180); if (my !== token) return false;
      tile.classList.add('lifted');
      startGhost(kind, a[0], a[1]);
      const ok = await tween(a, b, 1300, my, (x, y) => {
        placeCursor(x, y);
        moveGhost(kind, x, y, Math.hypot(x - a[0], y - a[1]));
      });
      tile.classList.remove('lifted');
      if (!ok) return false;
      await sleep(220); if (my !== token) return false;
      release(kind, b[0], b[1]);
      return true;
    }
    async function clickSwitch(v, my) {
      const s = sceneRect(), r = sw.getBoundingClientRect();
      // the switch sits above the scene; move the cursor to the scene's top edge near it
      const target = [Math.max(16, r.left - s.left + 20), 14];
      if (!(await tween(cur, target, 600, my, placeCursor))) return false;
      await sleep(150); if (my !== token) return false;
      setOn(v); resetThread();
      return true;
    }
    async function runAuto() {
      const my = ++token;
      const alive = () => my === token;
      demo.classList.add('auto');
      const c = centerOf(thread); placeCursor(c[0], c[1]);
      cursor.classList.add('show');
      while (alive()) {
        if (on) { if (!(await clickSwitch(false, my))) return; await sleep(500); }
        resetThread();
        if (!(await autoDrag('heic', my))) return;
        await sleep(2300); if (!alive()) return;
        if (!(await autoDrag('mov', my))) return;
        await sleep(2300); if (!alive()) return;
        if (!(await clickSwitch(true, my))) return;
        await sleep(600); if (!alive()) return;
        if (!(await autoDrag('heic', my))) return;
        await sleep(2400); if (!alive()) return;
        if (!(await autoDrag('mov', my))) return;
        await sleep(4200); if (!alive()) return;
      }
    }

    function userTouched() { demo.classList.add('touched'); stopAuto(); }
    demo.addEventListener('pointerdown', userTouched, true);
    demo.addEventListener('keydown', userTouched, true);
    demo.addEventListener('pointerup', () => scheduleAuto(12000));
    demo.addEventListener('keyup', () => scheduleAuto(12000));

    if ('IntersectionObserver' in window) {
      new IntersectionObserver((entries) => {
        entries.forEach((e) => {
          visible = e.isIntersecting;
          if (visible) scheduleAuto(demo.classList.contains('touched') ? 12000 : 4000);
          else if (demo.classList.contains('auto')) stopAuto();
          else clearTimeout(idleT);
        });
      }, { threshold: 0.35 }).observe(scene);
    }

    /* --- user pointer drag --- */
    Object.keys(tiles).forEach((kind) => {
      const t = tiles[kind];
      t.addEventListener('pointerdown', (e) => {
        if (e.button > 0) return;
        e.preventDefault();
        try { t.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
        const s = sceneRect();
        drag = { kind, id: e.pointerId, sx: e.clientX, sy: e.clientY };
        t.classList.add('lifted');
        startGhost(kind, e.clientX - s.left, e.clientY - s.top);
      });
      t.addEventListener('pointermove', (e) => {
        if (!drag || drag.id !== e.pointerId || drag.kind !== kind) return;
        const s = sceneRect();
        moveGhost(kind, e.clientX - s.left, e.clientY - s.top, Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy));
      });
      const end = (e, cancel) => {
        if (!drag || drag.id !== e.pointerId || drag.kind !== kind) return;
        drag = null;
        t.classList.remove('lifted');
        const s = sceneRect();
        if (cancel) hideGhost(); else release(kind, e.clientX - s.left, e.clientY - s.top);
      };
      t.addEventListener('pointerup', (e) => end(e, false));
      t.addEventListener('pointercancel', (e) => end(e, true));
    });

    sw.addEventListener('click', () => { setOn(!on); resetThread(); say(on ? 'Morphlo is on.' : 'Morphlo is off.'); });
    $$('[data-send]', demo).forEach((b) => b.addEventListener('click', () => deliver(b.dataset.send)));
  }

  /* =====================================================
     CONVERT WHEEL
     ===================================================== */
  const wheel = $('#wheel');
  if (wheel) initWheel(wheel);

  function initWheel(svg) {
    const NS = 'http://www.w3.org/2000/svg';
    const R = 160, RI = 74, RH = 64, RL = (R + RI) / 2;
    // [label, sub, output extension, 'dim']
    // Like the app (FormatWheel.swift), the same-format target stays on the wheel, dimmed and last.
    const TYPES = {
      heic: { file: 'IMG_0464.HEIC', base: 'IMG_0464', fmts: [['JPEG', '', 'jpg'], ['PNG', '', 'png'], ['AVIF', '', 'avif'], ['TIFF', '', 'tiff'], ['GIF', '', 'gif'], ['BMP', '', 'bmp'], ['PDF', '', 'pdf'], ['HEIC', '', 'heic', 'dim']] },
      mov: { file: 'clip.MOV', base: 'clip', fmts: [['MP4', 'H.264', 'mp4'], ['MP4', 'HEVC', 'mp4'], ['GIF', 'animated', 'gif'], ['Audio', 'only', 'm4a'], ['MOV', 'ProRes', 'mov', 'dim']] },
      wav: { file: 'voice.WAV', base: 'voice', fmts: [['M4A', 'AAC', 'm4a'], ['M4A', 'HE-AAC', 'm4a'], ['AIFF', '', 'aiff'], ['FLAC', '', 'flac'], ['ALAC', '', 'm4a'], ['WAV', '', 'wav', 'dim']] },
      docx: { file: 'notes.DOCX', base: 'notes', fmts: [['PDF', '', 'pdf'], ['DOC', '', 'doc'], ['ODT', '', 'odt'], ['RTF', '', 'rtf'], ['TXT', '', 'txt'], ['HTML', '', 'html'], ['DOCX', '', 'docx', 'dim']] },
      pdf: { file: 'report.PDF', base: 'report', fmts: [['PNG', 'per page', 'png'], ['JPEG', 'per page', 'jpg'], ['DOCX', '', 'docx'], ['ODT', '', 'odt'], ['RTF', '', 'rtf'], ['TXT', '', 'txt']] },
      woff2: { file: 'Brand.WOFF2', base: 'Brand', fmts: [['WOFF', '', 'woff'], ['TTF/OTF', '', 'ttf'], ['WOFF2', '', 'woff2', 'dim']] }
    };
    const out = $('#conv-out');
    let type = 'heic', typeT, replacing = false, hovered = null;

    const el = (name, attrs) => {
      const n = document.createElementNS(NS, name);
      Object.keys(attrs || {}).forEach((k) => n.setAttribute(k, attrs[k]));
      return n;
    };
    const pt = (r, deg) => { const a = (deg * Math.PI) / 180; return [(r * Math.cos(a)).toFixed(2), (r * Math.sin(a)).toFixed(2)]; };
    function sector(a0, a1) {
      const large = a1 - a0 > 180 ? 1 : 0;
      const [x0, y0] = pt(R, a0), [x1, y1] = pt(R, a1), [x2, y2] = pt(RI, a1), [x3, y3] = pt(RI, a0);
      return `M${x0} ${y0}A${R} ${R} 0 ${large} 1 ${x1} ${y1}L${x2} ${y2}A${RI} ${RI} 0 ${large} 0 ${x3} ${y3}Z`;
    }

    let hubS;
    function draw() {
      const t = TYPES[type], n = t.fmts.length, step = 360 / n;
      svg.textContent = '';
      svg.appendChild(el('circle', { r: R, fill: '#0a0a0a' }));
      const segs = el('g', {});
      t.fmts.forEach((f, i) => {
        const a0 = -90 + i * step, a1 = a0 + step, mid = a0 + step / 2; // a boundary sits at 12 o'clock
        const g = el('g', { class: f[3] ? 'seg dim' : 'seg', tabindex: '0', role: 'button', 'aria-label': `Convert ${t.file} to ${f[0]}${f[1] ? ' ' + f[1] : ''}${f[3] ? ' (same format)' : ''}` });
        g.style.animationDelay = (reduce ? 0 : i * 35) + 'ms';
        g.appendChild(el('path', { d: sector(a0, a1) }));
        const [lx, ly] = pt(RL, mid);
        const label = el('text', { x: lx, y: f[1] ? (ly - 6).toFixed(2) : ly, 'font-size': n > 6 ? 12.5 : 13.5 });
        label.textContent = f[0];
        g.appendChild(label);
        if (f[1]) {
          const sub = el('text', { x: lx, y: (+ly + 9).toFixed(2), class: 'sm' });
          sub.textContent = f[1];
          g.appendChild(sub);
        }
        g.addEventListener('mouseenter', () => hint(f));
        g.addEventListener('focus', () => hint(f));
        g.addEventListener('mouseleave', () => hint(null));
        g.addEventListener('blur', () => hint(null));
        g.addEventListener('click', (e) => pick(g, f, e.altKey || replacing));
        g.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(g, f, e.altKey || replacing); } });
        segs.appendChild(g);
      });
      svg.appendChild(segs);
      if (n > 1) {
        for (let i = 0; i < n; i++) {
          const a = -90 + i * step, [x0, y0] = pt(RI, a), [x1, y1] = pt(R, a);
          svg.appendChild(el('line', { class: 'sep', x1: x0, y1: y0, x2: x1, y2: y1 }));
        }
      }
      svg.appendChild(el('circle', { r: RH, fill: '#171717' }));
      // Hub: just the file name and what you're pointing at; no icon (as in the app).
      const hubN = el('text', { class: 'hub-n', y: -4 });
      hubN.textContent = t.file;
      svg.appendChild(hubN);
      hubS = el('text', { class: 'hub-s', y: 15 });
      svg.appendChild(hubS);
      hint(null);
    }
    function hint(f) {
      if (f !== undefined) hovered = f;
      if (!hubS) return;
      const h = hovered;
      hubS.textContent = h ? (replacing ? 'Replace → ' : '') + h[0] + (h[1] ? ' ' + h[1] : '') : (replacing ? 'Replace with…' : 'Convert to…');
      hubS.classList.toggle('on', !!h && !h[3]);
    }
    const setReplacing = (v) => { if (v !== replacing) { replacing = v; hint(); } };
    window.addEventListener('keydown', (e) => { if (e.key === 'Alt') setReplacing(true); });
    window.addEventListener('keyup', (e) => { if (e.key === 'Alt') setReplacing(false); });
    window.addEventListener('blur', () => setReplacing(false));
    function message(f, replace) {
      const t = TYPES[type];
      // Matches uniqueOutput (Process.swift): "name.ext", then "name 2.ext" when taken;
      // PDF pages go into "<name> pages/" as "page 1.png", "page 2.png"… (DocConv.swift).
      const srcExt = t.file.slice(t.file.lastIndexOf('.') + 1).toLowerCase();
      let name = `${t.base}.${f[2]}`;
      if (type === 'pdf' && f[1]) name = `${t.base} pages/  (page 1.${f[2]}, page 2.${f[2]}…)`;
      else if (f[2] === srcExt && !replace) name = `${t.base} 2.${f[2]}`;
      return replace
        ? [name, ' replaced the original (original moved to the Trash)']
        : [name, ' saved next to the original'];
    }
    function typeOut(parts) {
      clearTimeout(typeT);
      const [name, rest] = parts;
      const full = name + rest;
      let i = 0;
      const render = () => {
        const shown = full.slice(0, i);
        const nm = shown.slice(0, name.length), rs = shown.slice(name.length);
        out.innerHTML = '<span class="okc">✓</span> <span class="acc"></span><span class="rs"></span>';
        out.querySelector('.acc').textContent = nm;
        out.querySelector('.rs').textContent = rs;
      };
      if (reduce) { i = full.length; render(); return; }
      const tick = () => { i++; render(); if (i < full.length) typeT = setTimeout(tick, 16 + Math.random() * 22); };
      tick();
    }
    function pick(g, f, replace) {
      $$('.seg', svg).forEach((s) => s.classList.remove('done'));
      g.classList.add('pressed');
      setTimeout(() => { g.classList.remove('pressed'); g.classList.add('done'); }, 160);
      typeOut(message(f, replace));
    }

    const tabs = $$('.ftab');
    function selectType(tab) {
      tabs.forEach((t) => { const sel = t === tab; t.setAttribute('aria-selected', String(sel)); t.tabIndex = sel ? 0 : -1; });
      type = tab.dataset.type;
      clearTimeout(typeT);
      out.textContent = 'pick a format on the wheel';
      draw();
    }
    tabs.forEach((t, i) => {
      t.tabIndex = t.getAttribute('aria-selected') === 'true' ? 0 : -1;
      t.addEventListener('click', () => selectType(t));
      t.addEventListener('keydown', (e) => {
        const d = (e.key === 'ArrowRight' || e.key === 'ArrowDown') ? 1 : (e.key === 'ArrowLeft' || e.key === 'ArrowUp') ? -1 : 0;
        if (!d) return;
        e.preventDefault();
        const next = tabs[(i + d + tabs.length) % tabs.length];
        next.focus(); selectType(next);
      });
    });
    draw();
  }

  /* =====================================================
     NETWORK MONITOR
     ===================================================== */
  const log = $('#mon-log');
  if (log) {
    const EVENTS = [
      ['ImageIO', 'decode IMG_0464.HEIC → JPEG'],
      ['AVFoundation', 'export clip.MOV → MP4 (HEVC)'],
      ['Core Audio', 'encode voice.WAV → FLAC'],
      ['PDFKit', 'render report.PDF → PNG, 4 pages'],
      ['TextKit', 'write notes.DOCX → PDF'],
      ['Photos', 'read original IMG_0465.MOV'],
      ['ImageIO', 'encode cover.PNG → AVIF'],
      ['AVFoundation', 'pass full video IMG_0465.MOV'],
      ['Speech', 'transcribe clip.MOV, on device'],
      ['Core Audio', 'encode memo.M4A → ALAC']
    ];
    const MAX = 9;
    let k = 0;
    const pad = (n) => String(n).padStart(2, '0');
    function add(d = new Date()) {
      const [f, a] = EVENTS[k++ % EVENTS.length];
      const li = document.createElement('li');
      li.innerHTML = '<span class="t"></span><span class="f"></span><span class="a"></span><span class="l">local</span>';
      li.children[0].textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
      li.children[1].textContent = f;
      li.children[2].textContent = a;
      log.appendChild(li);
      while (log.children.length > MAX) log.firstElementChild.remove();
    }
    for (let i = 0; i < 6; i++) add(new Date(Date.now() - (6 - i) * 1700));
    let timer = null;
    const start = () => { if (!timer && !reduce) timer = setInterval(() => add(), 1700); };
    const stop = () => { clearInterval(timer); timer = null; };
    if ('IntersectionObserver' in window) {
      new IntersectionObserver((es) => es.forEach((e) => (e.isIntersecting ? start() : stop()))).observe(log);
    } else start();
  }

  /* ---------- demo video: custom play button, native controls once playing ---------- */
  {
    const film = document.getElementById('film');
    const play = document.getElementById('film-play');
    if (film && play) {
      film.controls = false;
      play.hidden = false;
      const show = (on) => { play.hidden = !on; film.controls = !on; };
      play.addEventListener('click', () => {
        show(false);
        const p = film.play();
        if (p && p.catch) p.catch((e) => { if (e && e.name === 'NotSupportedError') fail(); else show(true); });
        film.focus({ preventScroll: true });
      });
      const err = document.getElementById('film-err');
      function fail() { play.hidden = true; film.controls = true; if (err) err.hidden = false; }
      film.addEventListener('error', fail);
      film.addEventListener('play', () => show(false));
      film.addEventListener('ended', () => { film.load(); show(true); }); // load() brings the poster back
      // Pause when scrolled away so it never plays offscreen.
      if ('IntersectionObserver' in window) {
        new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting || film.paused) return;
          // Leave Picture-in-Picture running: that's the point of it.
          if (document.pictureInPictureElement === film || (film.webkitPresentationMode || 'inline') !== 'inline') return;
          film.pause(); }), { threshold: 0.15 }).observe(film);
      }
    }
  }
})();
