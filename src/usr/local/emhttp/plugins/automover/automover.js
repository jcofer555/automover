'use strict';
console.log('[amb] JS loaded');

// ── Helpers ──────────────────────────────────────────────────────────────────
function ah(p) { return A_H + '/' + p; }

function showPop(id, msg) {
  const e = document.getElementById(id);
  if (!e) return;
  e.textContent = msg;
  e.style.display = 'block';
  clearTimeout(e._t);
  e._t = setTimeout(() => { e.style.display = 'none'; }, 3000);
}

function showToast(id, msg) {
  const e = document.getElementById(id);
  if (!e) return;
  e.textContent = msg;
  e.classList.add('on');
  clearTimeout(e._t);
  e._t = setTimeout(() => e.classList.remove('on'), 2200);
}

function timeAgo(d) {
  const s = Math.floor((Date.now() - d) / 1000);
  if (s < 60) return '<1 min ago';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  if (h < 24) return h + 'h ago';
  return Math.floor(h / 24) + 'd ago';
}

function fallbackCopy(t) {
  const ta = document.createElement('textarea');
  ta.value = t;
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
}

let snStatus = null, snLock = null, snLog = null, snMoved = null;
let logDebug  = false, logAuto = false, movedAuto = false, lastRunTs = null;

// ── Custom dialogs ────────────────────────────────────────────────────────────
function ambConfirm(msg, onOk) {
  const modal  = document.getElementById('amb-confirm');
  const msgEl  = document.getElementById('amb-confirm-msg');
  const okBtn  = document.getElementById('amb-confirm-ok');
  const canBtn = document.getElementById('amb-confirm-cancel');
  if (!modal) { if (onOk) onOk(); return; }
  msgEl.textContent = msg;
  modal.classList.add('open');
  function cleanup() {
    modal.classList.remove('open');
    okBtn.removeEventListener('click', handleOk);
    canBtn.removeEventListener('click', handleCancel);
  }
  function handleOk()     { cleanup(); if (onOk) onOk(); }
  function handleCancel() { cleanup(); }
  okBtn.addEventListener('click', handleOk);
  canBtn.addEventListener('click', handleCancel);
}

function ambAlert(msg, title) {
  const modal = document.getElementById('amb-alert');
  const msgEl = document.getElementById('amb-alert-msg');
  const titEl = document.getElementById('amb-alert-title');
  const okBtn = document.getElementById('amb-alert-ok');
  if (!modal) return;
  msgEl.textContent = msg;
  if (titEl) titEl.textContent = title || 'Error';
  modal.classList.add('open');
  function handleOk() {
    modal.classList.remove('open');
    okBtn.removeEventListener('click', handleOk);
  }
  okBtn.addEventListener('click', handleOk);
}

// ── Banner state ──────────────────────────────────────────────────────────────
let ambMoveRunning = false;
let ambStopPending = false;

function ambShowBanner(msg) {
  ambMoveRunning = true;
  const bt     = document.getElementById('amb-banner-text');
  const toast  = document.getElementById('amb-stop-toast');
  const banner = document.getElementById('amb-banner');
  const btn    = document.getElementById('amnb');
  if (bt)     bt.textContent = msg;
  if (toast)  toast.classList.remove('on');
  if (banner) banner.style.display = 'block';
  if (btn)    btn.disabled = true;
  document.querySelectorAll('.amb-schedule-run-btn').forEach(b => b.disabled = true);
}

function ambHideBanner() {
  ambMoveRunning = false;
  const banner = document.getElementById('amb-banner');
  const btn    = document.getElementById('amnb');
  if (banner) banner.style.display = 'none';
  if (btn)    btn.disabled = false;
  document.querySelectorAll('.amb-schedule-run-btn').forEach(b => b.disabled = false);
}

function ambSL(on) {
  logDebug = on;
  logAuto  = false;
  snLog    = null;
  const el = document.getElementById('algl');
  if (el) { el.scrollTop = 0; el.dataset.raw = ''; el.textContent = ''; }
}

function applyLogSearch(logId, searchId, countId, clearId) {
  const logEl    = document.getElementById(logId);    if (!logEl)    return;
  const searchEl = document.getElementById(searchId); if (!searchEl) return;
  const countEl  = document.getElementById(countId);
  const clearEl  = document.getElementById(clearId);
  const term     = searchEl.value.trim();
  const raw      = logEl.dataset.raw || '';
  if (clearEl) clearEl.style.display = term ? 'flex' : 'none';
  if (!term) {
    logEl.textContent = raw || '';
    if (countEl) countEl.classList.remove('on');
    return;
  }
  const esc   = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re    = new RegExp('(' + esc + ')', 'gi');
  const parts = raw.split(re);
  let hits    = 0;
  logEl.innerHTML = '';
  parts.forEach(p => {
    if (re.test(p)) {
      hits++;
      const m = document.createElement('mark');
      m.className  = 'alh';
      m.textContent = p;
      logEl.appendChild(m);
      re.lastIndex = 0;
    } else {
      logEl.appendChild(document.createTextNode(p));
    }
  });
  if (countEl) {
    countEl.textContent = hits + ' match' + (hits !== 1 ? 'es' : '');
    countEl.classList.toggle('on', hits > 0);
  }
}

// ── Tooltipster helper ────────────────────────────────────────────────────────
function ambInitTooltips(root) {
  const ctx = root || document;
  if (typeof $ === 'undefined' || !$.fn || !$.fn.tooltipster) return;
  $(ctx).find('[data-tipster]').each(function () {
    const $el = $(this);
    if ($el.hasClass('tooltipstered')) return;
    $el.tooltipster({
      maxWidth: 280,
      theme:    'tooltipster-shadow',
      delay:    120,
      content:  $el.data('tipster'),
    });
    $el.removeAttr('title');
  });
}

// ── Pollers ───────────────────────────────────────────────────────────────────
(function pollStatus() {
  fetch(ah('status_check.php'), { credentials: 'same-origin' })
    .then(r => r.json())
    .then(d => {
      snStatus    = JSON.stringify(d);
      const dot   = document.getElementById('adot');
      const st    = document.getElementById('astxt');
      const ds    = d.data || d;
      if (st) {
        const s = (ds.status || '').trim();
        st.textContent = (s && s !== 'None' && s !== 'null' && s !== 'undefined') ? s : 'Idle';
      }
      if (dot) dot.classList.toggle('on', ds.status && ds.status !== 'Stopped' && ds.status !== 'Idle');
      const lrt = document.getElementById('alrtxt');
      if (lrt) lrt.textContent = ds.last_run || 'No last run';
    })
    .catch(() => {})
    .finally(() => setTimeout(pollStatus, A_F));
})();

(function pollLock() {
  fetch(ah('check_lock.php'))
    .then(r => r.json())
    .then(d => {
      const sn = JSON.stringify(d);
      if (sn === snLock) return;
      snLock = sn;
      const locked = !!((d.data || d).locked);
      if (ambStopPending) return;
      if (locked  && !ambMoveRunning) ambShowBanner('⚠ Move in progress');
      if (!locked &&  ambMoveRunning) ambHideBanner();
    })
    .catch(() => {})
    .finally(() => setTimeout(pollLock, A_F));
})();

(function pollLog() {
  fetch(ah('fetch_last_run_log.php') + '?debug=' + (logDebug ? '1' : '0'))
    .then(r => r.text())
    .then(raw => {
      const empty   = logDebug ? 'Automover debug log not found' : 'Automover log not found';
      const rev     = raw ? raw.split('\n').filter(l => l.trim()).reverse().join('\n') : '';
      const display = rev || empty;
      if (display === snLog) return;
      snLog = display;
      const el = document.getElementById('algl');
      if (!el) return;
      el.dataset.raw = display;
      applyLogSearch('algl', 'algs', 'algc', 'algx');
      if (logAuto) el.scrollTop = el.scrollHeight;
      if (raw) {
        for (const ln of raw.split('\n')) {
          if (/session finished/i.test(ln)) {
            const m = ln.match(/\[?(\d{4}-\d{2}-\d{2}[\sT]\d{2}:\d{2}:\d{2})/);
            if (m) { lastRunTs = new Date(m[1].replace(' ', 'T')); break; }
          }
        }
      }
    })
    .catch(() => {})
    .finally(() => setTimeout(pollLog, A_F));
})();

setInterval(() => {
  const el = document.getElementById('alrtxt2');
  if (el) el.textContent = lastRunTs && !isNaN(lastRunTs)
    ? 'Last Run: ' + timeAgo(lastRunTs)
    : 'No last run';
}, 1000);

(function pollMoved() {
  const kw  = (document.getElementById('amvs') || {}).value || '';
  const url = ah('fetch_files_moved_log.php') + (kw ? '?filter=' + encodeURIComponent(kw) : '');
  fetch(url)
    .then(r => r.json())
    .then(d => {
      const sn = JSON.stringify(d);
      if (sn === snMoved) return;
      snMoved = sn;
      const el = document.getElementById('amvl');
      if (!el) return;
      const dm = d.data || d;
      el.innerHTML   = '';
      el.dataset.raw = dm.log || '';
      (dm.log || '').split('\n').forEach(line => {
        const div = document.createElement('div');
        div.textContent = line;
        if (line.toLowerCase().includes('skipped')) div.classList.add('skipped-line');
        el.appendChild(div);
      });
      const lc = document.getElementById('amb-lc');
      if (lc) lc.textContent = 'Total Files Moved: ' + (dm.moved ?? 0);
      if (movedAuto) el.scrollTop = el.scrollHeight;
    })
    .catch(() => {})
    .finally(() => setTimeout(pollMoved, A_F));
})();

(function pollPool() {
  const sel = document.getElementById('apool');
  if (!sel) return setTimeout(pollPool, A_S);
  const cur = sel.value || sel.dataset.sel || '';
  fetch(ah('pool_usage.php'))
    .then(r => r.json())
    .then(d => {
      const pd    = d.data || d;
      const pools = Object.keys(pd).filter(n => pd[n] !== 'N/A');
      if (!pools.length) {
        sel.innerHTML = '<option disabled>No pools — is array started?</option>';
        return;
      }
      const prev = sel.value;
      sel.innerHTML = '';
      pools.forEach(p => {
        const o = document.createElement('option');
        o.value       = p;
        o.textContent = p + ' (' + pd[p] + '%)';
        if (p === (prev || cur)) o.selected = true;
        sel.appendChild(o);
      });
      checkPoolWarn(sel.value);
    })
    .catch(() => {})
    .finally(() => setTimeout(pollPool, A_S));
})();

function checkPoolWarn(pool) {
  if (!pool) return;
  fetch(ah('check_pool_usage.php') + '?pool=' + encodeURIComponent(pool))
    .then(r => r.json())
    .then(d => {
      const w = document.getElementById('apw');
      if (w) w.classList.toggle('on', !(d.data || d).in_use);
    })
    .catch(() => {});
}

// ── DOMContentLoaded ──────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', function () {

  ambInitTooltips(document);

  function initSearch(si, xi, onInput) {
    const s = document.getElementById(si);
    const x = document.getElementById(xi);
    if (!s || !x) return;
    s.addEventListener('input', function () {
      x.style.display = this.value ? 'flex' : 'none';
      if (onInput) onInput();
    });
    x.addEventListener('mousedown', function (e) {
      e.preventDefault();
      s.value = '';
      x.style.display = 'none';
      if (onInput) onInput();
      s.focus();
    });
    x.style.display = s.value ? 'flex' : 'none';
  }
  initSearch('algs', 'algx', () => applyLogSearch('algl', 'algs', 'algc', 'algx'));
  initSearch('amvs', 'amvx', () => { snMoved = null; });

  // ── Scroll buttons ────────────────────────────────────────────────────────────
  (function () {
    const el = document.getElementById('algl');
    document.getElementById('algtp')?.addEventListener('click', () => { logAuto = false; if (el) el.scrollTop = 0; });
    document.getElementById('algbt')?.addEventListener('click', () => {
      logAuto = !logAuto;
      if (logAuto && el) el.scrollTop = el.scrollHeight;
    });
    el?.addEventListener('scroll', () => {
      if (el.scrollHeight - el.scrollTop - el.clientHeight > 8) logAuto = false;
    });
  })();
  (function () {
    const el = document.getElementById('amvl');
    document.getElementById('amvtp')?.addEventListener('click', () => { movedAuto = false; if (el) el.scrollTop = 0; });
    document.getElementById('amvbt')?.addEventListener('click', () => {
      movedAuto = !movedAuto;
      if (movedAuto && el) el.scrollTop = el.scrollHeight;
    });
    el?.addEventListener('scroll', () => {
      if (el.scrollHeight - el.scrollTop - el.clientHeight > 8) movedAuto = false;
    });
  })();

  // ── Clear / copy ──────────────────────────────────────────────────────────────
  document.getElementById('algcl')?.addEventListener('click', function () {
    const lbl = logDebug ? 'debug log' : 'automover log';
    if (!confirm('Clear the ' + lbl + '?')) return;
    fetch(ah('clear_log.php'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
      body: 'log=last&debug=' + (logDebug ? '1' : '0') + '&csrf_token=' + encodeURIComponent(csrf)
    }).then(r => r.json()).then(d => {
      if ((d.data || d).ok) {
        const el = document.getElementById('algl');
        if (el) { el.dataset.raw = ''; el.textContent = ''; }
        snLog = null;
        showToast('algt', logDebug ? 'Debug log cleared' : 'Log cleared');
      }
    }).catch(() => ambAlert('Failed'));
    fetch(ah('clear_log.php'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
      body: 'log=mover&csrf_token=' + encodeURIComponent(csrf)
    }).then(r => r.json()).then(d => {
      if ((d.data || d).ok) {
        const el = document.getElementById('amvl');
        if (el) { el.innerHTML = ''; el.dataset.raw = ''; }
        snMoved = null;
        const lc = document.getElementById('amb-lc');
        if (lc) lc.textContent = '';
        showToast('amvt', 'Log cleared');
      }
    }).catch(() => ambAlert('Failed'));
  });

  document.getElementById('algcp')?.addEventListener('click', function () {
    const t = (document.getElementById('algl')?.dataset.raw) || '';
    if (!t.trim()) return;
    navigator.clipboard?.writeText(t)
      .then(() => showToast('algt', logDebug ? 'Debug log copied' : 'Log copied'))
      .catch(() => fallbackCopy(t)) || fallbackCopy(t);
  });

  document.getElementById('amvcp')?.addEventListener('click', function () {
    const t = (document.getElementById('amvl')?.dataset.raw) || '';
    if (!t.trim()) return;
    navigator.clipboard?.writeText(t)
      .then(() => showToast('amvt', 'Copied'))
      .catch(() => fallbackCopy(t)) || fallbackCopy(t);
  });

  // ── Pool change ───────────────────────────────────────────────────────────────
  document.getElementById('apool')?.addEventListener('change', function () { checkPoolWarn(this.value); });

  // ── Cron mode ─────────────────────────────────────────────────────────────────
  const cronSel = document.getElementById('acm');
  function applyCron() {
    const v   = cronSel?.value;
    const map = { hourly: 'aho', daily: 'ado', weekly: 'awo', monthly: 'amo' };
    Object.values(map).forEach(id => {
      const el = document.getElementById(id);
      if (el) el.style.display = 'none';
    });
    const show = map[v];
    if (show) { const el = document.getElementById(show); if (el) el.style.display = ''; }
  }
  cronSel?.addEventListener('change', applyCron);
  applyCron();

  // ── Option sliders ────────────────────────────────────────────────────────────
  const OPTS_MAP = [
    ['antf', ['an-sec']],
    ['apri', ['apr-sec']],
    ['aagf', ['aag-sec']],
    ['aszf', ['asz-sec']],
    ['aqbt', ['aqb-sec']],
    ['ajdp', ['ahsh-sec']],
    ['aext', ['aex-sec']],
    ['ascp', ['asc-sec']],
  ];
  OPTS_MAP.forEach(([cbId, secIds]) => {
    const cb = document.getElementById(cbId);
    if (!cb) return;
    function apply() {
      secIds.forEach(sid => {
        const el = document.getElementById(sid);
        if (el) el.style.display = cb.checked ? '' : 'none';
      });
    }
    cb.addEventListener('change', apply);
    apply();
  });

  // ── Python warning ────────────────────────────────────────────────────────────
  (function () {
    const w     = document.getElementById('apyw'); if (!w) return;
    const cb    = document.getElementById('aqbt');
    const hasPy = w.dataset.py === '1';
    function upd() { if (w) w.style.display = (cb?.checked && !hasPy) ? 'block' : 'none'; }
    cb?.addEventListener('change', upd);
    upd();
  })();

  // ── Webhook fields ────────────────────────────────────────────────────────────
  const WH_CFG = {
    Discord:  { label: 'Discord Webhook URL',    prefix: 'https://discord.com/api/webhooks/' },
    Gotify:   { label: 'Gotify URL',             prefix: 'https://' },
    Ntfy:     { label: 'Ntfy URL',               prefix: 'https://' },
    Pushover: { label: 'Pushover App Token URL', prefix: 'https://api.pushover.net/', needsKey: true },
    Slack:    { label: 'Slack Webhook URL',      prefix: 'https://hooks.slack.com/' },
    Unraid:   { label: null },
  };

  const ams  = document.getElementById('anms');
  const amsl = document.getElementById('anml-list');
  const anml = document.getElementById('anml');

  function updateNotifLabel() {
    const svcs = Array.from(document.querySelectorAll('#anml-list input:checked')).map(c => c.value);
    if (anml) anml.textContent = svcs.length ? svcs.join(', ') : 'Select service(s)';
    rebuildWebhooks();
  }
  ams?.addEventListener('click', e => {
    e.stopPropagation();
    if (amsl) amsl.style.display = (amsl.style.display === 'none' || amsl.style.display === '') ? 'block' : 'none';
  });
  amsl?.addEventListener('click', e => e.stopPropagation());
  amsl?.querySelectorAll('input').forEach(cb => cb.addEventListener('change', updateNotifLabel));
  document.addEventListener('click', () => { if (amsl) amsl.style.display = 'none'; });
  updateNotifLabel();

  function rebuildWebhooks() {
    const box = document.getElementById('awh-box'); if (!box) return;
    const svcs = Array.from(document.querySelectorAll('#anml-list input:checked')).map(c => c.value);
    box.innerHTML = '';
    svcs.forEach(svc => {
      const cfg = WH_CFG[svc];
      if (!cfg || !cfg.label) return;
      const row   = document.createElement('div');
      row.className = 'af';
      row.id        = 'wh-row-' + svc.toLowerCase();
      const saved = WH_SAVED[svc.toUpperCase()] || '';
      row.innerHTML =
        '<span class="afl" data-tip="' + cfg.label + '">' + cfg.label + ':</span>' +
        '<div class="afi">' +
          '<input type="text" id="wh-' + svc.toLowerCase() + '" data-svc="' + svc + '" class="whi" placeholder="' + (cfg.prefix || '') + '" value="' + saved + '">' +
          '<span class="aw" id="whe-' + svc.toLowerCase() + '">Invalid URL</span>' +
        '</div>';
      box.appendChild(row);
      if (cfg.needsKey) {
        const pkRow = document.createElement('div');
        pkRow.className = 'af';
        pkRow.id        = 'wh-row-pushover-key';
        pkRow.innerHTML =
          '<span class="afl" data-tip="Your Pushover user key">Pushover User Key:</span>' +
          '<div class="afi">' +
            '<input type="text" id="wh-pushover-key" placeholder="user key" value="' + PO_SAVED + '">' +
            '<span class="aw" id="whe-pushover-key">Required</span>' +
          '</div>';
        box.appendChild(pkRow);
      }
    });
    box.querySelectorAll('.whi').forEach(inp => {
      inp.addEventListener('blur', function () {
        const svc = this.dataset.svc;
        const cfg = WH_CFG[svc];
        if (!cfg || !cfg.prefix) return;
        const v = this.value.trim();
        if (v && !v.startsWith('https://') && !v.startsWith('http://')) this.value = cfg.prefix + v;
        validateWh(this);
      });
      inp.addEventListener('input', function () { validateWh(this); });
    });
    box.querySelectorAll('.afl[data-tip]').forEach(span => {
      const tip = span.dataset.tip;
      if (!tip || span._helpAttached) return;
      span._helpAttached = true;
      const row = span.closest('.af');
      if (row) attachHelp(span, tip, row);
    });
  }

  function validateWh(inp) {
    const svc = inp.dataset.svc;
    const cfg = WH_CFG[svc];
    const w   = document.getElementById('whe-' + svc.toLowerCase());
    if (!w) return;
    const v  = inp.value.trim();
    const ok = !v || !cfg.prefix || v.startsWith(cfg.prefix) || v.startsWith('http://');
    inp.classList.toggle('ainv', !ok);
    w.classList.toggle('on', !ok);
  }

  // ── qBit days order validation ────────────────────────────────────────────────
  ['aqbdf', 'aqbdt'].forEach(id => {
    document.getElementById(id)?.addEventListener('change', () => {
      const f    = parseInt(document.getElementById('aqbdf')?.value, 10);
      const t    = parseInt(document.getElementById('aqbdt')?.value, 10);
      document.getElementById('aqbow')?.classList.toggle('on', !isNaN(f) && !isNaN(t) && f >= t);
    });
  });

  // ── Shared helpers ────────────────────────────────────────────────────────────
  function safeJson(r, label) {
    if (!r.ok) throw new Error(label + ' returned HTTP ' + r.status);
    return r.text().then(txt => {
      const t = txt.trim();
      if (!t) throw new Error(label + ' returned an empty response — check the PHP file for errors');
      try { return JSON.parse(t); }
      catch (e) { throw new Error(label + ' returned non-JSON: ' + t.slice(0, 120)); }
    });
  }

  function g(id)  { return (document.getElementById(id)?.value || '').trim(); }
  function cb(id) { return document.getElementById(id)?.checked ? 'yes' : 'no'; }

  function buildCronFromUI() {
    const mode = document.getElementById('acm')?.value;
    const DAY  = { Sunday:0, Monday:1, Tuesday:2, Wednesday:3, Thursday:4, Friday:5, Saturday:6 };
    switch (mode) {
      case 'hourly':  return { valid: true, cron: `0 */${parseInt(g('ahf'),10)} * * *`, mode };
      case 'daily':   return { valid: true, cron: `${parseInt(g('adm'),10)} ${parseInt(g('adt'),10)} * * *`, mode };
      case 'weekly':  return { valid: true, cron: `${parseInt(g('awm'),10)} ${parseInt(g('awt'),10)} * * ${DAY[g('awd')]}`, mode };
      case 'monthly': return { valid: true, cron: `${parseInt(g('amm'),10)} ${parseInt(g('amt'),10)} ${parseInt(g('amdy'),10)} * *`, mode };
      default: return { valid: false };
    }
  }

  function detectCronMode(cron) {
    if (!cron) return 'daily';
    if (/^0 \*\/(4|6|8) \* \* \*$/.test(cron)) return 'hourly';
    if (/^\d+ \d+ \* \* \*$/.test(cron))        return 'daily';
    if (/^\d+ \d+ \* \* [0-6]$/.test(cron))     return 'weekly';
    if (/^\d+ \d+ \d+ \* \*$/.test(cron))       return 'monthly';
    return 'daily';
  }

  function populateCronUI(cron) {
    const parts = cron.trim().split(/\s+/);
    if (parts.length !== 5) return;
    const [min, hour, dom, , dow] = parts;
    const mode = detectCronMode(cron);
    const sel  = document.getElementById('acm');
    if (sel) { sel.value = mode; applyCron(); }
    if (mode === 'hourly') {
      const m = hour.match(/^\*\/(\d+)$/);
      if (m) { const el = document.getElementById('ahf'); if (el) el.value = m[1]; }
    } else if (mode === 'daily') {
      const dh = document.getElementById('adt'); if (dh) dh.value = hour.padStart(2, '0');
      const dm = document.getElementById('adm'); if (dm) dm.value = min.padStart(2, '0');
    } else if (mode === 'weekly') {
      const days = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
      const wday = document.getElementById('awd'); if (wday) wday.value = days[parseInt(dow, 10)] || 'Sunday';
      const wh   = document.getElementById('awt'); if (wh)   wh.value   = hour.padStart(2, '0');
      const wm   = document.getElementById('awm'); if (wm)   wm.value   = min.padStart(2, '0');
    } else if (mode === 'monthly') {
      const mday = document.getElementById('amdy'); if (mday) mday.value = dom.padStart(2, '0');
      const mh   = document.getElementById('amt');  if (mh)   mh.value   = hour.padStart(2, '0');
      const mm   = document.getElementById('amm');  if (mm)   mm.value   = min.padStart(2, '0');
    }
  }

  function buildSettingsParams() {
    const svcs = Array.from(document.querySelectorAll('#anml-list input:checked')).map(c => c.value).join(',');
    const wh   = {};
    document.querySelectorAll('#awh-box .whi').forEach(inp => {
      wh['WEBHOOK_' + inp.dataset.svc.toUpperCase()] = inp.value.trim();
    });
    ['DISCORD','GOTIFY','NTFY','PUSHOVER','SLACK'].forEach(s => { if (!wh['WEBHOOK_' + s]) wh['WEBHOOK_' + s] = ''; });
    const { cron, mode } = buildCronFromUI();
    return {
      AGE_BASED_FILTER:       cb('aagf'), AGE_DAYS:              g('aaged'),
      ALLOW_DURING_PARITY:    cb('aap2'), CLEANUP:               cb('acln'), CPU_AND_IO_PRIORITIES: cb('apri'),
      CPU_PRIORITY:           g('acpu'),  CRON_EXPRESSION:       cron || '',
      CRON_MODE:              mode || g('acm') || 'daily',
      DAILY_MINUTE:           g('adm'),   DAILY_TIME:            g('adt'),
      DRY_RUN:                cb('adr'),  EXCLUSIONS:            cb('aext'),
      FORCE_TURBO_WRITE:      cb('atw'),  HASH_LOCATION:         g('ahp'),
      HIDDEN_FILTER:          cb('ahid'), HOURLY_FREQUENCY:      g('ahf'),
      IO_PRIORITY:            g('aiop'),  JDUPES:                cb('ajdp'),
      MONTHLY_DAY:            g('amdy'),  MONTHLY_MINUTE:        g('amm'),
      MONTHLY_TIME:           g('amt'),   NOTIFICATION_SERVICE:  svcs,
      NOTIFICATIONS:          cb('antf'), POOL_NAME:             g('apool'),
      POST_SCRIPT:            g('aposts'),PRE_AND_POST_SCRIPTS:  cb('ascp'),
      PRE_SCRIPT:             g('apres'), PUSHOVER_USER_KEY:     g('wh-pushover-key'),
      QBITTORRENT_DAYS_FROM:  g('aqbdf'), QBITTORRENT_DAYS_TO:  g('aqbdt'),
      QBITTORRENT_HOST:       g('aqbh'),  QBITTORRENT_MOVE_SCRIPT: cb('aqbt'),
      QBITTORRENT_PASSWORD:   g('aqbp'),  QBITTORRENT_STATUS:   g('aqbs'),
      QBITTORRENT_USERNAME:   g('aqbu'),  SIZE:                  g('aszm'),
      SIZE_BASED_FILTER:      cb('aszf'), SIZE_UNIT:             g('aszu'),
      STOP_ALL_CONTAINERS:    cb('asac'), STOP_CONTAINERS:       g('acont'),
      STOP_THRESHOLD:         g('asthr'), SSD_TRIM:              cb('atrm'),
      THRESHOLD:              g('athr'),  WEEKLY_DAY:            g('awd'),
      WEEKLY_MINUTE:          g('awm'),   WEEKLY_TIME:           g('awt'),
      ...wh
    };
  }

  function validateQbit() {
    if (!document.getElementById('aqbt')?.checked) return true;
    const hv       = (document.getElementById('aqbh')?.value || '').trim();
    const hasProto = /^https?:\/\//i.test(hv);
    document.getElementById('aqbh')?.classList.toggle('ainv', !hv || hasProto);
    document.getElementById('aqbhw')?.classList.toggle('on',  !hv || hasProto);
    const uOk = !!(document.getElementById('aqbu')?.value.trim());
    document.getElementById('aqbu')?.classList.toggle('ainv', !uOk);
    document.getElementById('aqbuw')?.classList.toggle('on',  !uOk);
    const pOk = !!(document.getElementById('aqbp')?.value.trim());
    document.getElementById('aqbp')?.classList.toggle('ainv', !pOk);
    document.getElementById('aqbpw')?.classList.toggle('on',  !pOk);
    const fv   = parseInt(document.getElementById('aqbdf')?.value, 10);
    const tv   = parseInt(document.getElementById('aqbdt')?.value, 10);
    const ordOk = !isNaN(fv) && !isNaN(tv) && fv < tv;
    document.getElementById('aqbow')?.classList.toggle('on', !ordOk);
    return !(!hv || hasProto || !uOk || !pOk || !ordOk);
  }

  function doSaveSettings() {
    const p = new URLSearchParams({ csrf_token: csrf, ...buildSettingsParams() });
    return fetch(ah('save_settings.php') + '?csrf_token=' + encodeURIComponent(csrf), {
      method:  'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
      body:    p.toString()
    })
    .then(r => safeJson(r, 'save_settings.php'))
    .then(sd => { if (sd.status === 'error') throw new Error('Save failed: ' + (sd.message || 'Unknown')); });
  }

  // ── Schedule CRUD ─────────────────────────────────────────────────────────────
  let ambEditingId = null;

  function ambLoadSchedules() {
    fetch(ah('schedule_list.php'))
      .then(r => r.text())
      .then(html => {
        document.getElementById('amb-schedule-list').innerHTML = html;
        document.getElementById('amb-sched-title').style.display =
          document.querySelector('#amb-schedule-list .TableContainer') ? 'block' : 'none';
        setTimeout(() => {
          ambInitTableTips();
          ambInitTooltips(document.getElementById('amb-schedule-list'));
        }, 50);
      })
      .catch(e => { console.error('[amb] ambLoadSchedules failed:', e); })
      .finally(() => {});
  }

  async function ambFetchExistingCrons() {
    const r = await fetch(ah('schedule_cron_check.php'));
    return r.json();
  }

  function ambCheckCronConflict(newCron, existing, excludeId) {
    function toMins(c) {
      const p = c.trim().split(/\s+/);
      if (p.length !== 5) return [];
      const [min, hour, dom, , dow] = p;
      const mins = [];
      const hi   = hour.match(/^\*\/(\d+)$/);
      if (min === '0' && hi && dom === '*' && dow === '*') {
        const n = parseInt(hi[1], 10);
        for (let h = 0; h < 7 * 24; h += n) mins.push(h * 60);
        return mins;
      }
      const mn = parseInt(min, 10);
      if (/^\d+$/.test(hour) && dom === '*' && dow === '*') {
        const h = parseInt(hour, 10);
        for (let d = 0; d < 7; d++) mins.push(d * 24 * 60 + h * 60 + mn);
        return mins;
      }
      if (/^\d+$/.test(hour) && dom === '*' && /^\d+$/.test(dow)) {
        mins.push(parseInt(dow, 10) * 24 * 60 + parseInt(hour, 10) * 60 + mn);
        return mins;
      }
      if (/^\d+$/.test(hour) && /^\d+$/.test(dom) && dow === '*') {
        mins.push(((parseInt(dom, 10) - 1) % 7) * 24 * 60 + parseInt(hour, 10) * 60 + mn);
        return mins;
      }
      return mins;
    }
    const W      = 7 * 24 * 60;
    const newMins = toMins(newCron);
    if (!newMins.length) return null;
    for (const e of existing) {
      if (excludeId && e.id.trim() === String(excludeId).trim()) continue;
      const em = toMins(e.cron);
      for (const nt of newMins) {
        for (const et of em) {
          if (Math.min(Math.abs(nt - et), W - Math.abs(nt - et)) < 15) return e.cron;
        }
      }
    }
    return null;
  }

  async function ambScheduleJob() {
    if (!validateQbit()) {
      document.getElementById('aap')?.classList.add('ashk');
      setTimeout(() => document.getElementById('aap')?.classList.remove('ashk'), 400);
      return;
    }
    const { valid, cron } = buildCronFromUI();
    if (!valid) { ambAlert('Invalid cron expression'); return; }

    const existing = await ambFetchExistingCrons();
    const conflict = ambCheckCronConflict(cron, existing, ambEditingId);
    if (conflict) {
      ambAlert('This schedule is within 15 minutes of an existing schedule (' + conflict + '). Please choose a different time.');
      return;
    }

    const settings = buildSettingsParams();
    const url  = ambEditingId ? 'schedule_update.php' : 'schedule_create.php';
    const body = new URLSearchParams({ csrf_token: csrf, cron });
    Object.entries(settings).forEach(([k, v]) => body.append('settings[' + k + ']', v));
    if (ambEditingId) body.append('id', ambEditingId);

    fetch(ah(url) + '?csrf_token=' + encodeURIComponent(csrf), {
      method:  'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
      body:    body.toString()
    })
    .then(r => safeJson(r, url))
    .then(d => {
      if (!d.success) throw new Error(d.error || 'Failed to save schedule');
      ambResetScheduleUI();
      ambLoadSchedules();
      showPop('asp', ambEditingId ? '✅ Schedule Updated' : '✅ Schedule Created');
      ambEditingId = null;
    })
    .catch(e => { ambAlert(e.message || 'Failed to save schedule'); });
  }

  // ── Schedule edit mode helpers ────────────────────────────────────────────────
  function ambEnterEditMode(id) {
    const moveNow = document.getElementById('amnb');
    const update  = document.getElementById('amnb-update');
    if (moveNow) moveNow.style.display = 'none';
    if (update)  update.style.display  = '';
    const schedBtn  = document.getElementById('amb-schedule-btn');
    const cancelBtn = document.getElementById('amb-cancel-edit-btn');
    if (schedBtn)  schedBtn.style.display  = 'none';
    if (cancelBtn) cancelBtn.style.display = '';
    const saveBtn = document.getElementById('amb-save-btn');
    if (saveBtn) { saveBtn.disabled = true; saveBtn.style.opacity = '0.45'; saveBtn.style.cursor = 'not-allowed'; }
    ambMarkTableEditBtn(id, true);
  }

  function ambMarkTableEditBtn(id, isEditing) {
    document.querySelectorAll('#amb-schedule-list button[data-action="edit"]').forEach(btn => {
      const btnId = btn.dataset.id;
      btn.textContent = 'Edit';
      delete btn.dataset.updating;
      btn.onclick = function() { window.ambEditSchedule(btnId, btn); };
      if (typeof $ !== 'undefined' && $(btn).hasClass('tooltipstered')) {
        $(btn).tooltipster('content', 'Edit this schedule');
      } else {
        btn.setAttribute('data-tipster', 'Edit this schedule');
      }
    });
    if (isEditing && id) {
      const target = document.querySelector(
        '#amb-schedule-list button[data-action="edit"][data-id="' + id + '"]'
      );
      if (target) {
        target.textContent = 'Update';
        target.dataset.updating = 'true';
        target.onclick = function() { ambScheduleJob(); };
        if (typeof $ !== 'undefined' && $(target).hasClass('tooltipstered')) {
          $(target).tooltipster('content', 'Save changes to this schedule');
        } else {
          target.setAttribute('data-tipster', 'Save changes to this schedule');
        }
      }
    }
  }

  function ambResetScheduleUI() {
    ambEditingId = null;
    const moveNow = document.getElementById('amnb');
    const update  = document.getElementById('amnb-update');
    if (moveNow) moveNow.style.display = '';
    if (update)  update.style.display  = 'none';
    const schedBtn  = document.getElementById('amb-schedule-btn');
    const cancelBtn = document.getElementById('amb-cancel-edit-btn');
    if (schedBtn)  schedBtn.style.display  = '';
    if (cancelBtn) cancelBtn.style.display = 'none';
    const saveBtn = document.getElementById('amb-save-btn');
    if (saveBtn) { saveBtn.disabled = false; saveBtn.style.opacity = ''; saveBtn.style.cursor = ''; }
    ambMarkTableEditBtn(null, false);
  }

  window.ambEditSchedule = function (id, editBtn) {
    if (ambEditingId === id) { ambResetScheduleUI(); return; }
    if (ambEditingId) ambResetScheduleUI();
    fetch(ah('schedule_load.php') + '?id=' + encodeURIComponent(id))
      .then(r => safeJson(r, 'schedule_load.php'))
      .then(s => {
        const settings = s.SETTINGS || {};
        const fieldMap = {
          POOL_NAME: 'apool', THRESHOLD: 'athr', STOP_THRESHOLD: 'asthr',
          HOURLY_FREQUENCY: 'ahf', DAILY_TIME: 'adt', DAILY_MINUTE: 'adm',
          WEEKLY_DAY: 'awd', WEEKLY_TIME: 'awt', WEEKLY_MINUTE: 'awm',
          MONTHLY_DAY: 'amdy', MONTHLY_TIME: 'amt', MONTHLY_MINUTE: 'amm',
          STOP_CONTAINERS: 'acont', CPU_PRIORITY: 'acpu', IO_PRIORITY: 'aiop',
          HASH_LOCATION: 'ahp', AGE_DAYS: 'aaged', SIZE: 'aszm', SIZE_UNIT: 'aszu',
          QBITTORRENT_HOST: 'aqbh', QBITTORRENT_USERNAME: 'aqbu',
          QBITTORRENT_DAYS_FROM: 'aqbdf', QBITTORRENT_DAYS_TO: 'aqbdt',
          QBITTORRENT_STATUS: 'aqbs', PRE_SCRIPT: 'apres', POST_SCRIPT: 'aposts',
        };
        const cbMap = {
          DRY_RUN: 'adr', AGE_BASED_FILTER: 'aagf', SIZE_BASED_FILTER: 'aszf',
          NOTIFICATIONS: 'antf', HIDDEN_FILTER: 'ahid',
          FORCE_TURBO_WRITE: 'atw', SSD_TRIM: 'atrm',
          ALLOW_DURING_PARITY: 'aap2', CPU_AND_IO_PRIORITIES: 'apri', PRE_AND_POST_SCRIPTS: 'ascp',
          JDUPES: 'ajdp', QBITTORRENT_MOVE_SCRIPT: 'aqbt', CLEANUP: 'acln',
          STOP_ALL_CONTAINERS: 'asac', EXCLUSIONS: 'aext',
        };
        Object.entries(settings).forEach(([k, v]) => {
          const el = document.getElementById(fieldMap[k]);
          if (el) el.value = v;
          if (cbMap[k]) {
            const c = document.getElementById(cbMap[k]);
            if (c) c.checked = (v === 'yes');
          }
        });
        if (s.CRON) populateCronUI(s.CRON);
        if (settings.NOTIFICATION_SERVICE) {
          const svcs = settings.NOTIFICATION_SERVICE.split(',').map(s => s.trim());
          document.querySelectorAll('#anml-list input').forEach(c => c.checked = svcs.includes(c.value));
          updateNotifLabel();
        }
        ['DISCORD','GOTIFY','NTFY','PUSHOVER','SLACK'].forEach(svc => {
          const el = document.getElementById('wh-' + svc.toLowerCase());
          if (el && settings['WEBHOOK_' + svc]) el.value = settings['WEBHOOK_' + svc];
        });
        OPTS_MAP.forEach(([cbId, secIds]) => {
          const c = document.getElementById(cbId); if (!c) return;
          secIds.forEach(sid => {
            const el = document.getElementById(sid);
            if (el) el.style.display = c.checked ? '' : 'none';
          });
        });
        checkPoolWarn(g('apool'));
        ambEditingId = id;
        ambEnterEditMode(id);
        document.getElementById('aap')?.scrollTo({ top: 0, behavior: 'smooth' });
      })
      .catch(e => { ambAlert('Failed to load schedule: ' + e.message); });
  };

  window.ambDeleteSchedule = function (id) {
    ambConfirm('Delete this schedule?', () => {
      fetch(ah('schedule_delete.php') + '?csrf_token=' + encodeURIComponent(csrf), {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
        body:    'id=' + encodeURIComponent(id) + '&csrf_token=' + encodeURIComponent(csrf)
      })
      .then(r => safeJson(r, 'schedule_delete.php'))
      .then(() => { if (ambEditingId === id) ambResetScheduleUI(); ambLoadSchedules(); })
      .catch(e => { ambAlert('Failed to delete: ' + e.message); });
    });
  };

  window.ambToggleSchedule = function (id, isEnabled) {
    ambConfirm(isEnabled ? 'Disable this schedule?' : 'Enable this schedule?', () => {
      fetch(ah('schedule_toggle.php') + '?csrf_token=' + encodeURIComponent(csrf), {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
        body:    'id=' + encodeURIComponent(id) + '&csrf_token=' + encodeURIComponent(csrf)
      })
      .then(r => safeJson(r, 'schedule_toggle.php'))
      .then(() => ambLoadSchedules())
      .catch(e => { ambAlert('Failed to toggle: ' + e.message); });
    });
  };

  window.ambRunSchedule = function (id, btn) {
    if (ambMoveRunning) return;
    ambConfirm('Run this schedule now?', () => {
      fetch(ah('run_schedule.php') + '?csrf_token=' + encodeURIComponent(csrf), {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
        body:    'id=' + encodeURIComponent(id) + '&csrf_token=' + encodeURIComponent(csrf)
      })
      .then(r => r.json().catch(() => ({ started: true })))
      .then(d => {
        if (d.started === false) { ambAlert(d.message || 'Failed to start'); }
      })
      .catch(e => { ambAlert('Failed to run: ' + e.message); });
    });
  };

  document.addEventListener('click', function (e) {
    const btn = e.target.closest('#amb-schedule-list button[data-action]');
    if (!btn) return;
    const action  = btn.dataset.action;
    const id      = btn.dataset.id;
    const enabled = btn.dataset.enabled === 'true';
    if (action === 'edit' && !btn.dataset.updating) window.ambEditSchedule(id, btn);
    if (action === 'toggle') window.ambToggleSchedule(id, enabled);
    if (action === 'delete') window.ambDeleteSchedule(id);
    if (action === 'run')    window.ambRunSchedule(id, btn);
  });

  document.getElementById('amb-schedule-btn')?.addEventListener('click', ambScheduleJob);
  document.getElementById('amnb-update')?.addEventListener('click', ambScheduleJob);
  document.getElementById('amb-cancel-edit-btn')?.addEventListener('click', () => { ambResetScheduleUI(); });

  // ── Save button ───────────────────────────────────────────────────────────────
  document.getElementById('amb-save-btn')?.addEventListener('click', function() {
    doSaveSettings()
      .then(() => showPop('asp', '✅ Settings Saved'))
      .catch(e => { ambAlert(e.message || 'Failed to save settings'); });
  });

  ambLoadSchedules();

  fetch(ah('check_lock.php'))
    .then(r => r.json())
    .then(d => { if ((d.data || d).locked) ambShowBanner('⚠ Move in progress'); })
    .catch(() => {});

  // ── Clearable input X buttons ─────────────────────────────────────────────────
  document.querySelectorAll('.amb-clr-wrap .amb-clr').forEach(btn => {
    const inp = document.getElementById(btn.dataset.target);
    if (!inp) return;
    const update = () => { btn.style.display = inp.value ? 'flex' : 'none'; };
    inp.addEventListener('input', update);
    btn.addEventListener('mousedown', e => {
      e.preventDefault();
      inp.value = '';
      inp.dispatchEvent(new Event('input'));
      inp.focus();
    });
    update();
  });

  // ── Stop ──────────────────────────────────────────────────────────────────────
  document.getElementById('astopb')?.addEventListener('click', function () {
    fetch(ah('stop_automover.php'), {
      method:      'POST',
      credentials: 'same-origin',
      headers:     { 'Content-Type': 'application/x-www-form-urlencoded' },
      body:        'csrf_token=' + encodeURIComponent(csrf)
    }).then(() => {
      ambStopPending = true;
      const bt = document.getElementById('amb-banner-text');
      if (bt) bt.textContent = 'Stop requested — finishing current file';
      setTimeout(() => {
        ambStopPending = false;
        ambHideBanner();
      }, 2500);
    }).catch(() => {});
  });

  // ── Move Now button ────────────────────────────────────────────────────────────
  document.getElementById('amnb')?.addEventListener('click', function () {
    if (ambMoveRunning) return;
    if (!validateQbit()) {
      document.getElementById('aap')?.classList.add('ashk');
      setTimeout(() => document.getElementById('aap')?.classList.remove('ashk'), 400);
      return;
    }
    doSaveSettings()
      .then(() => fetch(ah('run_manual_move.php'), {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
        body:    'csrf_token=' + encodeURIComponent(csrf)
      }))
      .then(r => r.json().catch(() => ({ data: { ok: true } })))
      .then(d => {
        const ok = (d.data || d).ok || d.status === 'ok' || d.status === 'success';
        if (ok === false && (d.data || d).error) {
          ambAlert('Move failed: ' + ((d.data || d).error || '?'));
          return;
        }
        ambShowBanner('⚠ Move in progress');
      })
      .catch(e => { console.error('Move error:', e); ambAlert(e.message || 'Move failed'); });
  });

  // ── Exclusion picker ──────────────────────────────────────────────────────────
  let pickerPath = '/mnt', pickerExts = new Set();

  function buildCrumbs(path, crmId) {
    const c = document.getElementById(crmId);
    if (!c) return;
    c.innerHTML = '';
    if (!path.startsWith('/mnt')) path = '/mnt';
    const parts = path.split('/').filter(Boolean);
    let acc = '';
    parts.forEach((p, i) => {
      if (i > 0) {
        const sep = document.createElement('span');
        sep.className   = 'acs';
        sep.textContent = ' / ';
        c.appendChild(sep);
      }
      acc += '/' + p;
      const sp = document.createElement('span');
      sp.className   = 'acr';
      sp.textContent = i === 0 ? '/mnt' : p;
      sp.dataset.path = acc;
      sp.addEventListener('click', () => loadPicker(sp.dataset.path));
      c.appendChild(sp);
    });
  }

  function loadPicker(path) {
    pickerPath = path;
    fetch(ah('update_exclusions.php') + '?action=list_dir&path=' + encodeURIComponent(path) + '&csrf_token=' + encodeURIComponent(csrf))
      .then(r => r.json())
      .then(d => {
        const dd = d.data || d;
        if (!dd.ok) return;
        pickerPath = dd.path || path;
        buildCrumbs(pickerPath, 'apcrm');
        const grid = document.getElementById('apgr');
        if (!grid) return;
        grid.innerHTML = '';
        pickerExts.clear();
        dd.items.forEach(item => {
          const row    = document.createElement('div');
          row.className = 'apr ' + (item.isDir ? '' : 'file');
          const cb     = document.createElement('input');
          cb.type       = 'checkbox';
          cb.dataset.path = item.path;
          const isRoot = /^\/mnt\/[^/]+$/.test(item.path);
          if (isRoot) cb.disabled = true;
          const name   = document.createElement('div');
          name.className   = 'apn';
          name.textContent = (item.isDir ? '📁 ' : '📄 ') + item.name;
          if (item.isDir) name.addEventListener('click', () => { if (!isRoot) loadPicker(item.path); });
          row.appendChild(cb);
          row.appendChild(name);
          grid.appendChild(row);
        });
        updateExtBtns();
      })
      .catch(() => pickerToast('Error loading directory', 'err'));
  }

  function updateExtBtns() {
    pickerExts.clear();
    document.querySelectorAll('#apgr input:checked:not(:disabled)').forEach(cb => {
      if (cb.closest('.file')) {
        const n   = cb.dataset.path.split('/').pop();
        const pts = n.split('.');
        if (pts.length > 1) pickerExts.add(pts.pop());
      }
    });
    const show = pickerExts.size > 0;
    document.getElementById('apadx').style.display  = show ? 'inline-block' : 'none';
    document.getElementById('apremx').style.display = show ? 'inline-block' : 'none';
  }
  document.getElementById('apgr')?.addEventListener('change', updateExtBtns);

  let ptDelay = 0;
  function pickerToast(msg, type) {
    const c = document.getElementById('aptst'); if (!c) return;
    const t = document.createElement('div');
    t.textContent = msg;
    t.style.cssText = 'color:' + (type === 'err' ? 'var(--er)' : 'var(--ok)') + ';font-size:12px;font-weight:600;opacity:0;transition:opacity .3s;';
    c.appendChild(t);
    const d = ptDelay;
    ptDelay += 800;
    setTimeout(() => { t.style.opacity = '1'; }, d + 50);
    setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 300); }, d + 2200);
    setTimeout(() => { ptDelay = 0; }, d + 3000);
  }

  function pickerAction(action, paths) {
    const body = new URLSearchParams({ csrf_token: csrf });
    paths.forEach(p => body.append('paths[]', p));
    return fetch(ah('update_exclusions.php') + '?action=' + action, { method: 'POST', body })
      .then(r => r.json());
  }

  document.getElementById('apad')?.addEventListener('click', () => {
    const p = Array.from(document.querySelectorAll('#apgr input:checked')).map(c => c.dataset.path);
    if (!p.length) { pickerToast('No selection', 'err'); return; }
    pickerAction('add_exclusions', p).then(d => (d.data || d).ok ? pickerToast('✅ Added') : pickerToast('Failed', 'err'));
  });
  document.getElementById('aprem')?.addEventListener('click', () => {
    const p = Array.from(document.querySelectorAll('#apgr input:checked')).map(c => c.dataset.path);
    if (!p.length) { pickerToast('No selection', 'err'); return; }
    pickerAction('remove_exclusions', p).then(d => (d.data || d).ok ? pickerToast('✅ Removed') : pickerToast('Failed', 'err'));
  });
  document.getElementById('apadx')?.addEventListener('click', () => {
    const paths = Array.from(pickerExts).map(e => '*.' + e);
    pickerAction('add_exclusions', paths).then(d => {
      if ((d.data || d).ok) paths.forEach(p => pickerToast('✅ Added ' + p));
      else pickerToast('Failed', 'err');
    });
  });
  document.getElementById('apremx')?.addEventListener('click', () => {
    const paths = Array.from(pickerExts).map(e => '*.' + e);
    pickerAction('remove_exclusions', paths).then(d => {
      if ((d.data || d).ok) paths.forEach(p => pickerToast('✅ Removed ' + p));
      else pickerToast('Failed', 'err');
    });
  });
  document.getElementById('apup')?.addEventListener('click', () => {
    if (pickerPath && pickerPath !== '/mnt') {
      const up = pickerPath.replace(/\/+$/, '').split('/').slice(0, -1).join('/') || '/mnt';
      loadPicker(up.startsWith('/mnt') ? up : '/mnt');
    }
  });
  document.getElementById('apcl')?.addEventListener('click',  () => document.getElementById('apm')?.classList.remove('open'));
  document.getElementById('aexf')?.addEventListener('click',  () => { document.getElementById('apm')?.classList.add('open'); loadPicker('/mnt'); });
  document.getElementById('aexlb')?.addEventListener('click', () => {
    document.getElementById('aem')?.classList.add('open');
    fetch(ah('manage_exclusions.php') + '?action=get&csrf_token=' + encodeURIComponent(csrf), { cache: 'no-store' })
      .then(r => r.json())
      .then(d => {
        const dd = d.data || d;
        const et = document.getElementById('amb-et');
        if (et) et.value = dd.ok ? (dd.content || '').trim() : (dd.error || '');
      })
      .catch(() => {});
  });
  document.getElementById('aecl')?.addEventListener('click',  () => document.getElementById('aem')?.classList.remove('open'));
  document.getElementById('aecl2')?.addEventListener('click', () => document.getElementById('aem')?.classList.remove('open'));
  document.getElementById('aecp')?.addEventListener('click',  () => {
    const t = document.getElementById('amb-et')?.value || '';
    navigator.clipboard?.writeText(t).catch(() => fallbackCopy(t)) || fallbackCopy(t);
  });
  document.getElementById('aesv')?.addEventListener('click',  () => {
    const content = document.getElementById('amb-et')?.value || '';
    fetch(ah('manage_exclusions.php') + '?action=save', {
      method:  'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
      body:    'csrf_token=' + encodeURIComponent(csrf) + '&content=' + encodeURIComponent(content)
    })
    .then(r => r.json())
    .then(d => {
      const dd = d.data || d;
      showToast('algt', dd.ok ? '✅ Saved' : (dd.error || 'Save failed'));
    })
    .catch(() => showToast('algt', 'Save failed'));
  });

  // ── Mover tuning warning ──────────────────────────────────────────────────────
  const mwBox = document.getElementById('amb-mw');
  if (mwBox) {
    fetch(ah('mover_warning_state.php'))
      .then(r => r.json())
      .then(d => { if (!(d.data || d).dismissed) mwBox.style.display = 'block'; })
      .catch(() => { mwBox.style.display = 'block'; });
    document.getElementById('amb-mwx')?.addEventListener('click', () => {
      mwBox.style.transition = 'opacity .3s';
      mwBox.style.opacity    = '0';
      setTimeout(() => mwBox.remove(), 300);
    });
    document.getElementById('amb-mwd')?.addEventListener('click', function () {
      fetch(ah('mover_warning_state.php'), {
        method:  'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrf },
        body:    'csrf_token=' + encodeURIComponent(csrf)
      })
      .then(r => r.json())
      .then(d => {
        if ((d.data || d).ok) {
          document.getElementById('amb-mwdn').style.display = 'block';
          this.style.display = 'none';
          setTimeout(() => mwBox.style.display = 'none', 1500);
        }
      });
    });
  }

  // ── Inline help ───────────────────────────────────────────────────────────────
  let hlastClick = 0;
  function attachHelp(trigger, text, insertAfter) {
    if (trigger._helpAttached) return;
    trigger._helpAttached = true;
    const id  = 'aht-' + Math.random().toString(36).substr(2, 8);
    const div = document.createElement('div');
    div.className   = 'aht';
    div.id          = id;
    div.textContent = text;
    if (insertAfter.insertAdjacentElement) insertAfter.insertAdjacentElement('afterend', div);
    else if (insertAfter.parentNode) insertAfter.parentNode.insertBefore(div, insertAfter.nextSibling);
    trigger.addEventListener('click', e => {
      e.stopPropagation();
      hlastClick = Date.now();
      const el = document.getElementById(id);
      if (el) el.style.display = el.style.display === 'block' ? 'none' : 'block';
    });
  }
  document.querySelectorAll('.aol[data-tip]').forEach(span => {
    const tip = span.dataset.tip; if (!tip) return;
    const row = span.closest('.aor'); if (!row) return;
    attachHelp(span, tip, row);
  });
  document.querySelectorAll('.afl[data-tip]').forEach(span => {
    const tip = span.dataset.tip; if (!tip) return;
    const row = span.closest('.af'); if (!row) return;
    attachHelp(span, tip, row);
  });
  const tips = { apl: 'Easily switch between your installed jcofer555 plugins' };
  document.querySelectorAll('#amb-tb .atbl[id]').forEach(span => {
    const tip = tips[span.id]; if (!tip) return;
    const tb  = document.getElementById('amb-tb'); if (tb) attachHelp(span, tip, tb);
  });
  const dbLabel = document.getElementById('adbl');
  if (dbLabel) {
    const tb = dbLabel.closest('.altb');
    if (tb) attachHelp(dbLabel, 'Toggle between standard log and full debug log', tb);
  }
  document.addEventListener('keydown', e => {
    if (e.key !== 'F1') return;
    e.preventDefault();
    const all     = document.querySelectorAll('.aht');
    const anyOpen = Array.from(all).some(el => el.style.display === 'block');
    all.forEach(el => el.style.display = anyOpen ? 'none' : 'block');
  });
  document.addEventListener('click', () => {
    if (Date.now() - hlastClick < 150) return;
    document.querySelectorAll('.aht').forEach(el => el.style.display = 'none');
  });

  // ── Schedule table tooltipster ────────────────────────────────────────────────
  function ambInitTableTips() {
    $('#amb-schedule-list [data-tipster]').off('mouseenter.tipster').on('mouseenter.tipster', function () {
      const $el = $(this);
      if (!$el.hasClass('tooltipstered')) {
        $el.tooltipster({ maxWidth: 300, content: $el.data('tipster') });
        $el.removeAttr('title');
        setTimeout(() => { if ($el.is(':hover')) $el.tooltipster('open'); }, 300);
      }
    });
  }

  if (typeof caPluginUpdateCheck === 'function') caPluginUpdateCheck('automover.plg', { name: 'automover' });

}); // end DOMContentLoaded