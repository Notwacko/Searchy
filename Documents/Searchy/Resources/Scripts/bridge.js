// Searchy page bridge. Runs in an isolated content world in every frame, so page scripts
// can neither see nor spoof it. Keep this file tiny: it executes on every page load.
(() => {
  'use strict';
  if (window.__searchy) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.searchy;
  if (!handler) return;
  const post = (m) => { try { handler.postMessage(m); } catch (e) {} };
  const isTop = window.top === window;
  const S = (window.__searchy = {});

  // ---------------------------------------------------------------- stop autoplay (saves RAM, GPU, battery, data)
  const AP = window.__searchyAutoplay || { stop: false, allow: [] };
  if (AP.stop && !AP.allow.some((h) => location.hostname === h || location.hostname.endsWith('.' + h))) {
    document.addEventListener('play', (e) => {
      const v = e.target;
      if (!(v instanceof HTMLVideoElement)) return;
      if (navigator.userActivation && navigator.userActivation.hasBeenActive) return;   // the person pressed something
      v.pause();
    }, true);
  }

  // ---------------------------------------------------------------- media + floating video
  const mediaEls = () => document.querySelectorAll('video, audio');
  const isPlaying = (el) => !el.paused && !el.ended && el.readyState > 2;
  const isAudible = (el) => isPlaying(el) && !el.muted && el.volume > 0;
  const area = (el) => { const r = el.getBoundingClientRect(); return r.width * r.height; };
  const pickVideo = (mustPlay) => {
    let best = null, bestScore = -1;
    for (const v of document.querySelectorAll('video')) {
      if (!v.videoWidth && !v.readyState) continue;
      const playing = isPlaying(v);
      if (mustPlay && !playing) continue;
      const score = (playing ? 1e9 : 0) + (isAudible(v) ? 1e8 : 0) + Math.max(area(v), v.videoWidth * v.videoHeight / 4);
      if (score > bestScore) { best = v; bestScore = score; }
    }
    return best;
  };

  let lastMedia = '';
  const reportMedia = () => {
    let audible = false;
    for (const el of mediaEls()) if (isAudible(el)) { audible = true; break; }
    const v = pickVideo(true);
    const video = !!(v && isAudible(v) && area(v) > 120 * 80);
    const key = (audible ? 'a' : '-') + (video ? 'v' : '-');
    if (key === lastMedia) return;
    lastMedia = key;
    post({ t: 'media', audible, video });
  };
  ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange'].forEach((n) =>
    document.addEventListener(n, () => setTimeout(reportMedia, 0), true));

  const reportPiP = (active) => post({ t: 'pip', active });
  document.addEventListener('enterpictureinpicture', () => reportPiP(true), true);
  document.addEventListener('leavepictureinpicture', () => reportPiP(false), true);
  document.addEventListener('webkitpresentationmodechanged', (e) =>
    reportPiP(e.target && e.target.webkitPresentationMode === 'picture-in-picture'), true);

  S.enterPiP = async () => {
    const v = pickVideo(false);
    if (!v) return false;
    try {
      if (v.webkitPresentationMode === 'picture-in-picture' || document.pictureInPictureElement === v) return true;
      if (typeof v.webkitSetPresentationMode === 'function') { v.webkitSetPresentationMode('picture-in-picture'); return true; }
      await v.requestPictureInPicture();
      return true;
    } catch (e) { return false; }
  };
  S.exitPiP = async () => {
    try {
      if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return true; }
      for (const v of document.querySelectorAll('video'))
        if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
      return true;
    } catch (e) { return false; }
  };
  S.hasVideo = () => !!pickVideo(false);

  // ---------------------------------------------------------------- favicons + readability probe
  if (isTop) {
    const sendPageInfo = () => {
      const links = [...document.querySelectorAll(
        'link[rel~="icon" i], link[rel="apple-touch-icon" i], link[rel="apple-touch-icon-precomposed" i], link[rel="shortcut icon" i]')];
      const icons = links
        .map((l) => ({
          href: l.href,
          size: parseInt(((l.sizes && l.sizes[0]) || '').split('x')[0], 10) || 0,
          svg: /svg/i.test(l.type || '') || /\.svg(\?|#|$)/i.test(l.href),
        }))
        .filter((x) => x.href && !x.svg)
        .sort((a, b) => Math.abs((a.size || 32) - 64) - Math.abs((b.size || 32) - 64))
        .map((x) => x.href)
        .slice(0, 4);
      post({ t: 'icons', urls: icons });

      let long = 0;
      const ps = document.getElementsByTagName('p');
      for (let i = 0; i < ps.length && i < 400 && long < 4; i++) if ((ps[i].textContent || '').length > 90) long++;
      post({ t: 'readable', value: long >= 3 || !!document.querySelector('article p') });
    };
    if (document.readyState === 'complete') setTimeout(sendPageInfo, 0);
    else window.addEventListener('load', () => setTimeout(sendPageInfo, 50), { once: true });
  }

  // ---------------------------------------------------------------- logins
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none';
  };
  const passwordFields = () => [...document.querySelectorAll('input[type="password"]')].filter(visible);
  const usernameFor = (pw) => {
    const scope = pw.form || document;
    const cands = [...scope.querySelectorAll('input:not([type]), input[type="text"], input[type="email"], input[type="tel"]')]
      .filter(visible);
    let found = null;
    for (const c of cands) if (c.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) found = c;
    return found;
  };

  if (isTop) {
    let lastLogin = '';
    const reportLogin = () => {
      const has = passwordFields().length > 0;
      const key = has ? '1' : '0';
      if (key === lastLogin) return;
      lastLogin = key;
      post({ t: 'login', has });
    };
    let timer = 0;
    const schedule = () => { clearTimeout(timer); timer = setTimeout(reportLogin, 400); };
    document.addEventListener('DOMContentLoaded', () => {
      reportLogin();
      new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
    });
  }

  const capture = (pw) => {
    if (!pw || !pw.value) return;
    const u = usernameFor(pw);
    post({ t: 'credentials', username: u ? u.value : '', password: pw.value, host: location.hostname });
  };
  document.addEventListener('submit', (e) => {
    const f = e.target;
    if (f && f.querySelector) capture(f.querySelector('input[type="password"]'));
  }, true);
  document.addEventListener('click', (e) => {
    const b = e.target && e.target.closest && e.target.closest('button, input[type="submit"], [role="button"]');
    if (!b) return;
    const scope = b.form || b.closest('form') || document;
    const pw = scope.querySelector('input[type="password"]');
    if (pw && pw.value) capture(pw);
  }, true);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target && e.target.type === 'password') capture(e.target);
  }, true);

  const setValue = (el, value) => {
    const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
    if (desc && desc.set) desc.set.call(el, value); else el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  S.fill = (username, password) => {
    const pws = passwordFields();
    if (!pws.length) return false;
    const pw = pws[0];
    const u = usernameFor(pw);
    if (u && username) setValue(u, username);
    setValue(pw, password);
    return true;
  };
})();
