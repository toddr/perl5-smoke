/* CoreSmokeDB UI behaviour. Single small module — no framework.
 *
 * Responsibilities:
 *   1. Theme (light/dark) toggle persisted to localStorage.
 *      The initial theme is set inline in <head> to avoid a flash;
 *      this script handles the toggle button and live updates.
 *   2. Topbar mobile sheet (hamburger).
 *   3. Cmd+K command palette (jump-to-page + free-text search).
 *   4. Toast notifications (window.showToast).
 *   5. HTMX hooks: filter-result toast, UTC time localisation.
 *   6. Tab switching (aria-selected + hidden).
 *
 * No external dependencies. Theme bootstrap (the inline <head> block
 * in templates/layouts/default.html.ep) sets data-theme before this
 * file loads, so we never see a flash of the wrong theme.
 */
(function () {
  'use strict';

  /* ---------- Theme ---------- */
  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem('theme', theme); } catch (_) { /* ignore */ }
  }
  function currentTheme() {
    return document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';
  }
  window.toggleTheme = function () {
    applyTheme(currentTheme() === 'dark' ? 'light' : 'dark');
  };

  /* ---------- Density ---------- */
  function applyDensity(density) {
    document.body.classList.toggle('density-compact', density === 'compact');
    try { localStorage.setItem('density', density); } catch (_) { /* ignore */ }
    const btn = document.querySelector('[data-action="toggle-density"]');
    if (btn) btn.setAttribute('aria-pressed', density === 'compact' ? 'true' : 'false');
  }
  function bootDensity() {
    let stored = 'comfortable';
    try { stored = localStorage.getItem('density') || 'comfortable'; } catch (_) {}
    applyDensity(stored);
  }
  window.toggleDensity = function () {
    applyDensity(document.body.classList.contains('density-compact') ? 'comfortable' : 'compact');
  };

  /* ---------- Client-side column sort ----------
   * Add data-sort-key="<col>" on a <th> + matching data-sort-value or
   * data-sort-key on each <td>. Click toggles asc/desc; rows are
   * sorted in place. Works on the visible page; controllers stay
   * untouched. */
  function setupColumnSort(root) {
    (root || document).querySelectorAll('table.data-table').forEach(function (table) {
      if (table._sortWired) return;
      table._sortWired = true;
      const ths = table.querySelectorAll('thead th[data-sort-key]');
      ths.forEach(function (th) {
        th.classList.add('sortable');
        if (!th.querySelector('.sort-indicator')) {
          const ind = document.createElement('span');
          ind.className = 'sort-indicator';
          ind.textContent = '⇵';
          th.appendChild(ind);
        }
        th.style.cursor = 'pointer';
        th.addEventListener('click', function () {
          const key = th.getAttribute('data-sort-key');
          const dir = th.getAttribute('data-sort-dir') === 'asc' ? 'desc' : 'asc';
          ths.forEach(function (other) {
            other.removeAttribute('data-sort-dir');
            const i = other.querySelector('.sort-indicator');
            if (i) { i.textContent = '⇵'; i.classList.remove('is-active'); }
          });
          th.setAttribute('data-sort-dir', dir);
          const ind2 = th.querySelector('.sort-indicator');
          if (ind2) { ind2.textContent = dir === 'asc' ? '▲' : '▼'; ind2.classList.add('is-active'); }
          sortRows(table, key, dir);
        });
      });
    });
  }
  function sortRows(table, key, dir) {
    const tbody = table.tBodies[0];
    if (!tbody) return;
    const rows = Array.prototype.filter.call(tbody.rows, function (r) {
      return !r.classList.contains('skeleton-row') && !r.classList.contains('hx-load-more');
    });
    const trail = Array.prototype.filter.call(tbody.rows, function (r) {
      return r.classList.contains('skeleton-row') || r.classList.contains('hx-load-more');
    });
    rows.sort(function (a, b) {
      const av = cellValue(a, key);
      const bv = cellValue(b, key);
      if (av < bv) return dir === 'asc' ? -1 : 1;
      if (av > bv) return dir === 'asc' ? 1 : -1;
      return 0;
    });
    rows.forEach(function (r) { tbody.appendChild(r); });
    trail.forEach(function (r) { tbody.appendChild(r); });
  }
  function cellValue(row, key) {
    const cell = row.querySelector('[data-sort-key="' + key + '"]');
    if (!cell) return '';
    if (cell.dataset.sortValue != null) return cell.dataset.sortValue;
    return (cell.innerText || '').trim().toLowerCase();
  }

  /* ---------- Clickable rows ---------- */
  function setupClickableRows(root) {
    (root || document).querySelectorAll('tr[data-href]').forEach(function (tr) {
      if (tr._wired) return;
      tr._wired = true;
      tr.addEventListener('click', function (e) {
        // ignore clicks on inner anchors/buttons; let them navigate normally
        if (e.target.closest('a, button, input, select, label')) return;
        window.location.href = tr.getAttribute('data-href');
      });
    });
  }

  /* ---------- Topbar (mobile hamburger) ---------- */
  function setupTopbar() {
    var bar = document.querySelector('.topbar');
    if (!bar) return;
    bar.addEventListener('click', function (e) {
      var btn = e.target.closest('[data-action]');
      if (!btn) return;
      var action = btn.getAttribute('data-action');
      if (action === 'toggle-theme') {
        window.toggleTheme();
      } else if (action === 'toggle-mobile') {
        var open = bar.getAttribute('data-open') !== 'true';
        bar.setAttribute('data-open', open ? 'true' : 'false');
        btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      } else if (action === 'open-palette') {
        openPalette();
      } else if (action === 'toggle-density') {
        window.toggleDensity();
      }
    });
  }

  /* ---------- Command palette (Cmd+K) ---------- */
  var palette;
  var paletteInput;
  var paletteList;

  function setupPalette() {
    palette = document.getElementById('palette-overlay');
    if (!palette) return;
    paletteInput = palette.querySelector('.palette-input');
    paletteList  = palette.querySelector('.palette-list');

    palette.addEventListener('click', function (e) {
      if (e.target === palette) closePalette();
    });
    paletteInput.addEventListener('input', filterPalette);
    paletteInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        var active = paletteList.querySelector('.palette-item[data-active="true"]');
        if (active) {
          window.location.href = active.href;
        } else {
          var q = paletteInput.value.trim();
          if (q) window.location.href = '/search?selected_summary=' + encodeURIComponent(q);
        }
      } else if (e.key === 'ArrowDown') {
        e.preventDefault(); moveActive(1);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault(); moveActive(-1);
      }
    });

    document.addEventListener('keydown', function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        openPalette();
      } else if (e.key === 'Escape' && palette.getAttribute('data-open') === 'true') {
        closePalette();
      }
    });
  }
  function openPalette() {
    if (!palette) return;
    palette.setAttribute('data-open', 'true');
    paletteInput.value = '';
    filterPalette();
    setTimeout(function () { paletteInput.focus(); }, 10);
  }
  function closePalette() {
    if (!palette) return;
    palette.setAttribute('data-open', 'false');
  }
  function filterPalette() {
    var q = paletteInput.value.trim().toLowerCase();
    var items = paletteList.querySelectorAll('.palette-item');
    var firstVisible = null;
    items.forEach(function (it) {
      var text = (it.dataset.label || it.textContent).toLowerCase();
      var match = !q || text.indexOf(q) !== -1;
      it.hidden = !match;
      it.removeAttribute('data-active');
      if (match && !firstVisible) firstVisible = it;
    });
    if (firstVisible) firstVisible.setAttribute('data-active', 'true');
  }
  function moveActive(delta) {
    var visible = Array.prototype.filter.call(
      paletteList.querySelectorAll('.palette-item'),
      function (it) { return !it.hidden; }
    );
    if (!visible.length) return;
    var idx = visible.findIndex(function (it) { return it.getAttribute('data-active') === 'true'; });
    visible.forEach(function (it) { it.removeAttribute('data-active'); });
    var next = (idx + delta + visible.length) % visible.length;
    if (idx === -1) next = delta > 0 ? 0 : visible.length - 1;
    visible[next].setAttribute('data-active', 'true');
    visible[next].scrollIntoView({ block: 'nearest' });
  }

  /* ---------- Toast ---------- */
  window.showToast = function (msg, variant) {
    var mount = document.getElementById('toast-mount');
    if (!mount) return;
    var el = document.createElement('div');
    el.className = 'toast' + (variant ? ' toast-' + variant : '');
    el.textContent = msg;
    mount.appendChild(el);
    setTimeout(function () {
      el.style.transition = 'opacity 200ms ease';
      el.style.opacity = '0';
      setTimeout(function () { el.remove(); }, 220);
    }, 2800);
  };

  /* ---------- Tabs ---------- */
  function setupTabs(root) {
    (root || document).querySelectorAll('.tabs[data-tabs]').forEach(function (tabs) {
      tabs.addEventListener('click', function (e) {
        var tab = e.target.closest('.tab');
        if (!tab) return;
        var name = tab.getAttribute('data-tab');
        var group = tabs.getAttribute('data-tabs');
        tabs.querySelectorAll('.tab').forEach(function (t) {
          t.setAttribute('aria-selected', t === tab ? 'true' : 'false');
        });
        document.querySelectorAll('[data-tab-panel="' + group + '"]').forEach(function (panel) {
          panel.hidden = panel.getAttribute('data-panel') !== name;
        });
      });
    });
  }

  /* ---------- Confirm before destructive form submit ---------- */
  document.addEventListener('submit', function (e) {
    var msg = e.target.getAttribute('data-confirm');
    if (!msg) return;
    if (!confirm(msg)) e.preventDefault();
  });

  /* ---------- Matrix checkbox auto-submit ---------- */
  document.addEventListener('change', function (e) {
    if (e.target.matches('.matrix-filter input[type="checkbox"]')) {
      e.target.form.submit();
    }
  });

  /* ---------- Strip default-valued params from HTMX URLs ---------- */
  document.addEventListener('htmx:configRequest', function (e) {
    var elt = e.detail.elt;
    if (!elt || !elt.closest('#search-form, #latest-form')) return;
    var params = e.detail.parameters;
    for (var k of Object.keys(params)) {
      var v = params[k];
      if (v === 'all' || v === '') delete params[k];
    }
  });

  /* ---------- HTMX hooks ---------- */
  function localiseDates(root) {
    if (!window.Intl) return;
    var fmt = new Intl.DateTimeFormat(undefined, {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
      timeZoneName: 'short'
    });
    (root || document).querySelectorAll('time.utc-date').forEach(function (el) {
      var dt = el.getAttribute('datetime');
      if (!dt) return;
      var d = new Date(dt);
      if (isNaN(d)) return;
      el.textContent = fmt.format(d);
    });
  }

  function setupHtmxHooks() {
    document.body.addEventListener('htmx:afterSettle', function (e) {
      localiseDates(e.detail.elt);
      setupTabs(e.detail.elt);
      setupClickableRows(e.detail.elt);
      setupColumnSort(e.detail.elt);
    });
    document.body.addEventListener('htmx:afterSwap', function (e) {
      var target = e.detail.target;
      if (!target || target.id !== 'search-region') return;
      var trig = e.detail.requestConfig && e.detail.requestConfig.headers
        ? e.detail.requestConfig.headers['HX-Trigger']
        : null;
      if (trig !== 'search-form') return;
      var summary = target.querySelector('.pagination-summary');
      if (!summary) return;
      var count = summary.getAttribute('data-count');
      if (count == null) return;
      var n = parseInt(count, 10);
      var msg = (n === 1 ? '1 report' : n + ' reports') + ' match';
      window.showToast(msg, 'success');
    });
  }

  /* ---------- Init ---------- */
  function init() {
    bootDensity();
    setupTopbar();
    setupPalette();
    setupTabs();
    setupClickableRows();
    setupColumnSort();
    setupHtmxHooks();
    localiseDates();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
