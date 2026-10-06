// "Hide anything": hover to highlight, click to hide, ↑/↓ to widen/narrow the selection.
// Evaluated on demand in the isolated world (see WebEngine.run).
(() => {
  'use strict';
  const S = window.__searchy || (window.__searchy = {});
  if (S.picker) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.searchy;
  const post = (m) => { try { handler.postMessage(m); } catch (e) {} };

  let active = false, host = null, root = null, box = null, tip = null, current = null, stack = [];

  const esc = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, '\\$&'));
  const stableClass = (c) => c && !/^(css|sc|jsx|emotion|styled|svelte)-/i.test(c) && (c.match(/\d/g) || []).length < 2 && c.length < 40
    && !/(^|-)(active|hover|focus|open|opened|show|shown|visible|selected|current|loading|loaded)($|-)/i.test(c);

  const uniqueEnough = (sel, el) => {
    try { const all = document.querySelectorAll(sel); return all.length === 1 && all[0] === el; } catch (e) { return false; }
  };

  const selectorFor = (el) => {
    // 1. A stable id.
    if (el.id && !/\d{3,}/.test(el.id) && uniqueEnough('#' + esc(el.id), el)) return '#' + esc(el.id);
    // 2. Climb through tag.class pairs until the selector is unique.
    let parts = [], node = el;
    while (node && node.nodeType === 1 && node !== document.body && node !== document.documentElement) {
      let part = node.tagName.toLowerCase();
      const cls = [...node.classList].filter(stableClass).slice(0, 2);
      if (cls.length) part += '.' + cls.map(esc).join('.');
      if (node !== el && node.id && !/\d{3,}/.test(node.id)) { parts.unshift('#' + esc(node.id)); }
      else parts.unshift(part);
      const sel = parts.join(' > ');
      if (uniqueEnough(sel, el)) return sel;
      if (node !== el && node.id) break;
      node = node.parentElement;
    }
    // 3. Fallback: a fully positional path.
    parts = []; node = el;
    while (node && node.nodeType === 1 && node !== document.documentElement) {
      if (node.id && !/\d{3,}/.test(node.id)) { parts.unshift('#' + esc(node.id)); break; }
      const tag = node.tagName.toLowerCase();
      const same = [...node.parentElement.children].filter((c) => c.tagName === node.tagName);
      parts.unshift(same.length > 1 ? tag + ':nth-of-type(' + (same.indexOf(node) + 1) + ')' : tag);
      node = node.parentElement;
    }
    return parts.join(' > ');
  };

  const build = () => {
    host = document.createElement('div');
    host.setAttribute('style', 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;');
    root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        .box{position:fixed;border:2px solid #0a84ff;background:rgba(10,132,255,.16);border-radius:6px;
             box-shadow:0 0 0 99999px rgba(0,0,0,.18);pointer-events:none;transition:all .06s ease-out;display:none}
        .tip{position:fixed;font:600 11px/1 -apple-system,system-ui,sans-serif;color:#fff;background:#0a84ff;
             padding:4px 7px;border-radius:6px;pointer-events:none;display:none;white-space:nowrap}
        .bar{position:fixed;left:50%;top:14px;transform:translateX(-50%);display:flex;gap:12px;align-items:center;
             font:500 13px/1 -apple-system,system-ui,sans-serif;color:#fff;background:rgba(30,30,32,.82);
             -webkit-backdrop-filter:blur(20px) saturate(1.6);backdrop-filter:blur(20px) saturate(1.6);
             padding:10px 16px;border-radius:999px;box-shadow:0 8px 30px rgba(0,0,0,.35);pointer-events:none}
        .bar b{color:#6cb4ff;font-weight:600}
        kbd{font:inherit;background:rgba(255,255,255,.16);padding:2px 6px;border-radius:5px}
      </style>
      <div class="box"></div><div class="tip"></div>
      <div class="bar"><span>Click anything to <b>hide it</b></span><span><kbd>↑</kbd> <kbd>↓</kbd> resize</span><span><kbd>esc</kbd> cancel</span></div>`;
    box = root.querySelector('.box');
    tip = root.querySelector('.tip');
    (document.body || document.documentElement).appendChild(host);
  };

  const label = (el) => {
    let s = el.tagName.toLowerCase();
    const c = [...el.classList].filter(stableClass)[0];
    if (el.id) s += '#' + el.id; else if (c) s += '.' + c;
    return s;
  };

  const highlight = (el) => {
    current = el;
    if (!el) { box.style.display = tip.style.display = 'none'; return; }
    const r = el.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
    tip.textContent = label(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
    Object.assign(tip.style, { display: 'block', left: Math.max(4, r.left) + 'px', top: Math.max(4, r.top - 24) + 'px' });
  };

  const ours = (el) => el === host || (host && host.contains(el));
  const target = (e) => {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    return !el || ours(el) || el === document.documentElement || el === document.body ? null : el;
  };

  const onMove = (e) => { stack = []; highlight(target(e)); };
  const block = (e) => { e.preventDefault(); e.stopImmediatePropagation(); };
  const onClick = (e) => {
    block(e);
    const el = current || target(e);
    if (!el) return;
    const selector = selectorFor(el);
    const style = document.createElement('style');
    style.textContent = selector + '{display:none !important}';
    document.documentElement.appendChild(style);
    post({ t: 'hide', selector, host: location.hostname });
    stop(true);
  };
  const onKey = (e) => {
    if (e.key === 'Escape') { block(e); stop(false); }
    else if (e.key === 'ArrowUp' && current && current.parentElement && current.parentElement !== document.body) {
      block(e); stack.push(current); highlight(current.parentElement);
    } else if (e.key === 'ArrowDown' && stack.length) { block(e); highlight(stack.pop()); }
  };
  const swallow = (e) => { if (!ours(e.target)) block(e); };

  const start = () => {
    if (active) return;
    active = true;
    build();
    window.addEventListener('mousemove', onMove, true);
    window.addEventListener('click', onClick, true);
    window.addEventListener('keydown', onKey, true);
    ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'auxclick', 'contextmenu', 'dblclick'].forEach((n) => window.addEventListener(n, swallow, true));
    post({ t: 'picker', active: true });
  };
  const stop = (hid) => {
    if (!active) return;
    active = false;
    window.removeEventListener('mousemove', onMove, true);
    window.removeEventListener('click', onClick, true);
    window.removeEventListener('keydown', onKey, true);
    ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'auxclick', 'contextmenu', 'dblclick'].forEach((n) => window.removeEventListener(n, swallow, true));
    if (host) host.remove();
    host = root = box = tip = current = null; stack = [];
    post({ t: 'picker', active: false, hid: !!hid });
  };

  S.picker = { start, stop: () => stop(false), toggle: () => { active ? stop(false) : start(); return active; }, isActive: () => active };
})();
