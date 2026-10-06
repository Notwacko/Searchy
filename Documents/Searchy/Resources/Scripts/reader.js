// Reading mode: pulls the article out of the page, rebuilds it from a strict tag whitelist
// (no scripts, no styles, no iframes — "the article, its pictures, nothing else") and shows it
// in a full-window overlay inside a closed shadow root. Closing the overlay restores the page untouched.
(() => {
  'use strict';
  const S = window.__searchy || (window.__searchy = {});
  if (S.reader) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.searchy;
  const post = (m) => { try { handler.postMessage(m); } catch (e) {} };

  const POSITIVE = /article|body|content|entry|main|page|post|text|story|blog|prose/i;
  const NEGATIVE = /comment|combx|footer|footnote|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|sponsor|shopping|tags|tool|widget|nav|menu|breadcrumb|newsletter|subscribe|cookie|modal|popup|advert|banner|social|byline-list/i;
  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME', 'OBJECT', 'EMBED', 'FORM', 'INPUT', 'BUTTON', 'SELECT', 'TEXTAREA',
    'NAV', 'FOOTER', 'ASIDE', 'CANVAS', 'AUDIO', 'VIDEO', 'SVG', 'DIALOG', 'TEMPLATE', 'LINK', 'META', 'LABEL']);
  const KEEP = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI', 'BLOCKQUOTE', 'PRE', 'CODE', 'FIGURE', 'FIGCAPTION',
    'IMG', 'A', 'EM', 'STRONG', 'B', 'I', 'U', 'SUB', 'SUP', 'BR', 'HR', 'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH', 'DL', 'DT', 'DD', 'MARK', 'SMALL', 'S', 'DEL', 'INS', 'Q', 'CITE', 'ABBR', 'TIME', 'KBD']);

  const text = (el) => (el.textContent || '').replace(/\s+/g, ' ').trim();
  const meta = (n) => {
    const m = document.querySelector('meta[property="' + n + '"], meta[name="' + n + '"]');
    return m ? (m.getAttribute('content') || '').trim() : '';
  };
  const linkDensity = (el) => {
    const total = text(el).length;
    if (!total) return 0;
    let links = 0;
    el.querySelectorAll('a').forEach((a) => { links += text(a).length; });
    return links / total;
  };
  const hidden = (el) => {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
    const cs = getComputedStyle(el);
    return cs.display === 'none' || cs.visibility === 'hidden';
  };
  const weight = (el) => {
    const s = (el.className && typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '');
    let w = 0;
    if (NEGATIVE.test(s)) w -= 25;
    if (POSITIVE.test(s)) w += 25;
    return w;
  };

  // ------------------------------------------------------------------ find the article body
  const findRoot = () => {
    const strong = [...document.querySelectorAll('[itemprop="articleBody"], article, .post-content, .article-body, .entry-content, #article-body, [role="article"]')]
      .filter((el) => !hidden(el)).map((el) => ({ el, len: text(el).length * (1 - linkDensity(el)) })).filter((x) => x.len > 600)
      .sort((a, b) => b.len - a.len);
    if (strong.length === 1 || (strong.length > 1 && strong[0].len > strong[1].len * 1.6)) return strong[0].el;

    const scores = new Map();
    const bump = (el, v) => { if (!el || el === document.body || el === document.documentElement) return;
      if (!scores.has(el)) {
        let init = { DIV: 5, PRE: 3, TD: 3, BLOCKQUOTE: 3, ADDRESS: -3, OL: -3, UL: -3, DL: -3, DD: -3, DT: -3, LI: -3, FORM: -3, ARTICLE: 8, SECTION: 2, MAIN: 6 }[el.tagName] || 0;
        scores.set(el, init + weight(el));
      }
      scores.set(el, scores.get(el) + v);
    };
    const nodes = document.querySelectorAll('p, pre, blockquote, td');
    for (let i = 0; i < nodes.length && i < 4000; i++) {
      const p = nodes[i];
      const t = text(p);
      if (t.length < 40) continue;
      let skip = false;
      for (let a = p, d = 0; a && d < 4; a = a.parentElement, d++) {
        const s = (typeof a.className === 'string' ? a.className : '') + ' ' + (a.id || '');
        if (NEGATIVE.test(s) && !POSITIVE.test(s)) { skip = true; break; }
        if (SKIP_TAGS.has(a.tagName)) { skip = true; break; }
      }
      if (skip) continue;
      const score = 1 + (t.split(',').length - 1) + Math.min(Math.floor(t.length / 100), 3);
      bump(p.parentElement, score);
      bump(p.parentElement && p.parentElement.parentElement, score / 2);
    }
    let top = null;
    scores.forEach((s, el) => {
      const adj = s * (1 - linkDensity(el));
      if (!top || adj > top.s) top = { el, s: adj };
    });
    if (top && top.s > 20) return top.el;
    return strong.length ? strong[0].el : null;
  };

  // ------------------------------------------------------------------ rebuild from a whitelist
  const absolute = (u) => { try { return new URL(u, document.baseURI).href; } catch (e) { return ''; } };
  const bestSrc = (img) => {
    let src = img.currentSrc || img.getAttribute('src') || '';
    for (const k of ['data-src', 'data-lazy-src', 'data-original', 'data-hi-res-src']) if (!src || src.startsWith('data:')) src = img.getAttribute(k) || src;
    const set = img.getAttribute('srcset') || img.getAttribute('data-srcset') || '';
    if (set && (!src || src.startsWith('data:') || !img.currentSrc)) {
      let best = null;
      set.split(',').forEach((part) => {
        const [u, d] = part.trim().split(/\s+/);
        const w = parseFloat(d) || 1;
        if (u && (!best || w > best.w)) best = { u, w };
      });
      if (best) src = best.u;
    }
    return absolute(src);
  };

  const build = (src, out, ctx) => {
    for (let n = src.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) {
        if (n.nodeValue && n.nodeValue.trim() || (out.lastChild && out.lastChild.nodeType === 1)) out.appendChild(document.createTextNode(n.nodeValue));
        continue;
      }
      if (n.nodeType !== 1) continue;
      const tag = n.tagName;
      if (SKIP_TAGS.has(tag.toUpperCase()) || tag === 'svg' || hidden(n)) continue;
      const cls = (typeof n.className === 'string' ? n.className : '') + ' ' + (n.id || '');
      if (NEGATIVE.test(cls) && !POSITIVE.test(cls) && n !== ctx.root && !/^(P|H[1-6]|FIGURE|IMG)$/.test(tag)) continue;
      if (/^(UL|OL|DIV|SECTION|TABLE|ASIDE)$/.test(tag) && text(n).length < 700 && linkDensity(n) > 0.5) continue;

      if (tag === 'IMG') {
        const s = bestSrc(n);
        const w = n.naturalWidth || parseInt(n.getAttribute('width'), 10) || 0;
        if (!s || s.startsWith('data:') && s.length < 400 || (w && w < 80) || /sprite|pixel|tracking|1x1|spacer|logo|avatar|icon/i.test(s)) continue;
        const img = document.createElement('img');
        img.src = s; img.alt = n.getAttribute('alt') || ''; img.loading = 'lazy';
        out.appendChild(img);
        ctx.images++;
        continue;
      }
      if (tag === 'PICTURE') {
        const img = n.querySelector('img');
        if (img) { const wrap = document.createElement('div'); build({ firstChild: img }, wrap, ctx); /* handled below */ }
        continue;
      }
      if (KEEP.has(tag)) {
        let el = document.createElement(tag === 'H1' ? 'h2' : tag.toLowerCase());
        if (tag === 'A') {
          const h = absolute(n.getAttribute('href') || '');
          if (/^https?:/i.test(h)) { el.href = h; el.rel = 'noopener noreferrer'; } else el = document.createElement('span');
        }
        if (tag === 'TD' || tag === 'TH') { const cs = n.getAttribute('colspan'); if (cs) el.setAttribute('colspan', cs); }
        if (tag === 'TIME' && n.getAttribute('datetime')) el.setAttribute('datetime', n.getAttribute('datetime'));
        build(n, el, ctx);
        const empty = !el.textContent.trim() && !el.querySelector('img') && !/^(BR|HR)$/.test(tag);
        if (!empty) out.appendChild(el);
        continue;
      }
      // Unknown wrapper (div, span, section…): keep its content, drop the box.
      const before = out.childNodes.length;
      build(n, out, ctx);
      if (/^(DIV|SECTION|ARTICLE|MAIN|HEADER)$/.test(tag) && out.childNodes.length > before && out.lastChild && out.lastChild.nodeType === 3) {
        // Loose text inside a block wrapper → give it paragraph spacing.
        const t = out.lastChild; const p = document.createElement('p'); out.replaceChild(p, t); p.appendChild(t);
      }
    }
  };

  const pickTitle = (root) => {
    const dt = document.title || '';
    const h1 = (root && root.querySelector('h1')) || document.querySelector('h1');
    const og = meta('og:title');
    if (h1 && text(h1).length > 8 && (dt.toLowerCase().includes(text(h1).toLowerCase().slice(0, 25)) || !dt)) return text(h1);
    if (og) return og;
    if (h1 && text(h1).length > 8) return text(h1);
    return dt.replace(/\s*[\|–—•-]\s*[^\|–—•-]{2,40}$/, '') || dt;
  };
  const pickByline = () => {
    const m = meta('author') || meta('article:author') || meta('og:article:author');
    if (m && m.length < 80 && !/^https?:/.test(m)) return m;
    const el = document.querySelector('[rel="author"], [itemprop="author"], .byline, .author, [class*="byline"]');
    const t = el ? text(el) : '';
    return t && t.length < 90 ? t.replace(/^by\s+/i, '') : '';
  };
  const pickDate = () => {
    const raw = meta('article:published_time') || meta('og:article:published_time') || (document.querySelector('time[datetime]') || {}).getAttribute?.('datetime') || '';
    const d = raw ? new Date(raw) : null;
    return d && !isNaN(d) ? d.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' }) : '';
  };

  const extract = () => {
    const root = findRoot();
    if (!root) return null;
    const frag = document.createElement('div');
    const ctx = { root, images: 0 };
    build(root, frag, ctx);
    const body = text(frag);
    if (body.length < 280) return null;
    // Lead image from page metadata when the article body has none near its start.
    let lead = '';
    const og = meta('og:image');
    if (og && !frag.querySelector('img')) lead = absolute(og);
    const words = body.split(/\s+/).length;
    return { title: pickTitle(root), byline: pickByline(), date: pickDate(), site: meta('og:site_name') || location.hostname.replace(/^www\./, ''),
             node: frag, lead, minutes: Math.max(1, Math.round(words / 230)) };
  };

  // ------------------------------------------------------------------ overlay UI
  let host = null, root = null, prefs = { theme: 'auto', font: 'serif', size: 19 }, savedOverflow = '';

  const CSS = `
    :host{all:initial}
    *{box-sizing:border-box}
    .shell{position:fixed;inset:0;overflow-y:auto;overscroll-behavior:contain;-webkit-font-smoothing:antialiased;
      background:var(--bg);color:var(--fg);transition:background .25s,color .25s}
    .shell[data-theme=light]{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--rule:rgba(0,0,0,.1);--accent:#0a66d6;--code:rgba(0,0,0,.055);--chip:rgba(0,0,0,.06)}
    .shell[data-theme=sepia]{--bg:#f4ecd8;--fg:#433422;--muted:#8a7660;--rule:rgba(67,52,34,.16);--accent:#9a5b13;--code:rgba(67,52,34,.08);--chip:rgba(67,52,34,.08)}
    .shell[data-theme=dark]{--bg:#161618;--fg:#e8e8ea;--muted:#9a9aa0;--rule:rgba(255,255,255,.12);--accent:#6cb4ff;--code:rgba(255,255,255,.08);--chip:rgba(255,255,255,.1)}
    @media (prefers-color-scheme: dark){.shell[data-theme=auto]{--bg:#161618;--fg:#e8e8ea;--muted:#9a9aa0;--rule:rgba(255,255,255,.12);--accent:#6cb4ff;--code:rgba(255,255,255,.08);--chip:rgba(255,255,255,.1)}}
    @media (prefers-color-scheme: light){.shell[data-theme=auto]{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--rule:rgba(0,0,0,.1);--accent:#0a66d6;--code:rgba(0,0,0,.055);--chip:rgba(0,0,0,.06)}}
    .bar{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:6px;padding:10px 18px;
      font:500 12.5px/1 -apple-system,system-ui,sans-serif;color:var(--muted);
      background:color-mix(in srgb,var(--bg) 82%,transparent);-webkit-backdrop-filter:blur(18px) saturate(1.5);backdrop-filter:blur(18px) saturate(1.5);
      border-bottom:1px solid var(--rule)}
    .bar .site{flex:1;letter-spacing:.02em;text-transform:uppercase;font-size:11px;font-weight:600}
    .bar button{all:unset;cursor:pointer;padding:6px 10px;border-radius:8px;color:var(--fg);background:var(--chip);font:600 12px/1 -apple-system,system-ui,sans-serif}
    .bar button:hover{filter:brightness(.94)}
    .bar button.on{background:var(--accent);color:#fff}
    .bar .sep{width:8px}
    .dot{all:unset;cursor:pointer;width:18px;height:18px;border-radius:50%;border:2px solid var(--rule)!important;padding:0!important}
    .dot[data-t=light]{background:#fff}.dot[data-t=sepia]{background:#f4ecd8}.dot[data-t=dark]{background:#161618}
    .dot[data-t=auto]{background:linear-gradient(90deg,#fff 50%,#161618 50%)}
    .dot.on{outline:2px solid var(--accent);outline-offset:2px}
    .page{max-width:calc(var(--size)*37);margin:0 auto;padding:56px 28px 120px}
    h1.title{font:700 calc(var(--size)*1.9)/1.15 var(--face);letter-spacing:-.02em;margin:0 0 14px;text-wrap:balance}
    .meta{font:500 13.5px/1.4 -apple-system,system-ui,sans-serif;color:var(--muted);margin-bottom:34px;display:flex;flex-wrap:wrap;gap:6px 14px}
    .lead{width:100%;border-radius:14px;margin:0 0 30px;display:block}
    article{font:400 var(--size)/1.68 var(--face);hyphens:auto}
    article p{margin:0 0 1.15em}
    article h2,article h3,article h4,article h5,article h6{font-family:-apple-system,system-ui,sans-serif;line-height:1.25;letter-spacing:-.01em;margin:1.9em 0 .6em}
    article h2{font-size:1.5em}article h3{font-size:1.22em}article h4,article h5,article h6{font-size:1.05em}
    article a{color:var(--accent);text-decoration:underline;text-decoration-color:color-mix(in srgb,var(--accent) 40%,transparent);text-underline-offset:3px}
    article img{max-width:100%;height:auto;border-radius:10px;display:block;margin:1.6em auto}
    article figure{margin:1.8em 0}article figure img{margin:0 auto}
    article figcaption{font:400 .78em/1.45 -apple-system,system-ui,sans-serif;color:var(--muted);text-align:center;margin-top:.7em}
    article blockquote{margin:1.5em 0;padding:.1em 0 .1em 1.1em;border-left:3px solid var(--rule);color:var(--muted);font-style:italic}
    article pre{background:var(--code);padding:14px 16px;border-radius:10px;overflow-x:auto;font:400 .82em/1.55 ui-monospace,Menlo,monospace}
    article code{background:var(--code);padding:.12em .35em;border-radius:5px;font:400 .86em ui-monospace,Menlo,monospace}
    article pre code{background:none;padding:0}
    article ul,article ol{padding-left:1.4em;margin:0 0 1.15em}article li{margin:.35em 0}
    article hr{border:0;border-top:1px solid var(--rule);margin:2.2em 0}
    article table{border-collapse:collapse;width:100%;font:400 .85em/1.45 -apple-system,system-ui,sans-serif;margin:1.4em 0;display:block;overflow-x:auto}
    article td,article th{border:1px solid var(--rule);padding:6px 10px;text-align:left}
    .toast{position:fixed;left:50%;top:70px;transform:translateX(-50%);padding:10px 16px;border-radius:999px;background:var(--chip);color:var(--fg);
      font:600 13px/1 -apple-system,system-ui,sans-serif;-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px)}
  `;

  const apply = () => {
    if (!root) return;
    const shell = root.querySelector('.shell');
    shell.dataset.theme = prefs.theme;
    shell.style.setProperty('--size', prefs.size + 'px');
    shell.style.setProperty('--face', prefs.font === 'serif'
      ? 'ui-serif,"New York",Georgia,"Times New Roman",serif' : '-apple-system,system-ui,"SF Pro Text",Helvetica,sans-serif');
    root.querySelectorAll('[data-t]').forEach((b) => b.classList.toggle('on', b.dataset.t === prefs.theme));
    root.querySelectorAll('[data-f]').forEach((b) => b.classList.toggle('on', b.dataset.f === prefs.font));
  };
  const save = () => { apply(); post({ t: 'readerPrefs', theme: prefs.theme, font: prefs.font, size: prefs.size }); };

  const el = (tag, props, ...kids) => {
    const e = document.createElement(tag);
    Object.entries(props || {}).forEach(([k, v]) => (k === 'class' ? (e.className = v) : k === 'text' ? (e.textContent = v) : e.setAttribute(k, v)));
    kids.forEach((k) => k && e.appendChild(k));
    return e;
  };

  const open = (p) => {
    if (host) return 'on';
    if (p) prefs = Object.assign(prefs, p);
    const art = extract();
    if (!art) return 'unavailable';
    document.querySelectorAll('video, audio').forEach((m) => { try { m.pause(); } catch (e) {} });

    host = document.createElement('div');
    host.setAttribute('style', 'all:initial;position:fixed;inset:0;z-index:2147483646;');
    root = host.attachShadow({ mode: 'closed' });
    const style = document.createElement('style'); style.textContent = CSS;

    const themeDots = ['auto', 'light', 'sepia', 'dark'].map((t) => {
      const b = el('button', { class: 'dot', 'data-t': t, title: t[0].toUpperCase() + t.slice(1) });
      b.onclick = () => { prefs.theme = t; save(); };
      return b;
    });
    const btn = (label, fn, attrs) => { const b = el('button', Object.assign({ text: label }, attrs || {})); b.onclick = fn; return b; };
    const bar = el('div', { class: 'bar' }, el('div', { class: 'site', text: art.site }),
      btn('A−', () => { prefs.size = Math.max(14, prefs.size - 1); save(); }),
      btn('A+', () => { prefs.size = Math.min(30, prefs.size + 1); save(); }),
      el('span', { class: 'sep' }),
      btn('Serif', () => { prefs.font = 'serif'; save(); }, { 'data-f': 'serif' }),
      btn('Sans', () => { prefs.font = 'sans'; save(); }, { 'data-f': 'sans' }),
      el('span', { class: 'sep' }), ...themeDots, el('span', { class: 'sep' }),
      btn('Done', () => close(), {}));

    const meta = el('div', { class: 'meta' });
    [art.byline, art.date, art.minutes + ' min read'].filter(Boolean).forEach((m) => meta.appendChild(el('span', { text: m })));
    const page = el('main', { class: 'page' });
    if (art.lead) page.appendChild(Object.assign(el('img', { class: 'lead', alt: '' }), { src: art.lead }));
    page.appendChild(el('h1', { class: 'title', text: art.title }));
    page.appendChild(meta);
    const article = el('article'); while (art.node.firstChild) article.appendChild(art.node.firstChild);
    page.appendChild(article);

    const shell = el('div', { class: 'shell', tabindex: '-1' }, bar, page);
    root.append(style, shell);
    savedOverflow = document.documentElement.style.overflow;
    document.documentElement.style.overflow = 'hidden';
    (document.body || document.documentElement).appendChild(host);
    apply();
    shell.focus({ preventScroll: true });
    window.addEventListener('keydown', onKey, true);
    post({ t: 'reader', active: true });
    return 'on';
  };

  const close = () => {
    if (!host) return 'off';
    host.remove(); host = root = null;
    document.documentElement.style.overflow = savedOverflow;
    window.removeEventListener('keydown', onKey, true);
    post({ t: 'reader', active: false });
    return 'off';
  };
  const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); close(); } };

  S.reader = {
    toggle: (p) => (host ? close() : open(p)),
    open, close,
    isActive: () => !!host,
    setPrefs: (p) => { prefs = Object.assign(prefs, p); apply(); },
  };
})();
