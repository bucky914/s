// =========================================================
// Shared admin shell helpers — sidebar, mobile toggle, toast
// =========================================================

const ADMIN_NAV_ITEMS = [
  { href: 'index.html', label: 'Dashboard', icon: '<svg viewBox="0 0 24 24" fill="none"><rect x="3" y="3" width="8" height="8" rx="1.5" stroke="currentColor" stroke-width="1.8"/><rect x="13" y="3" width="8" height="5" rx="1.5" stroke="currentColor" stroke-width="1.8"/><rect x="13" y="12" width="8" height="9" rx="1.5" stroke="currentColor" stroke-width="1.8"/><rect x="3" y="15" width="8" height="6" rx="1.5" stroke="currentColor" stroke-width="1.8"/></svg>' },
  { href: 'customers.html', label: 'Customers', icon: '<svg viewBox="0 0 24 24" fill="none"><circle cx="9" cy="8" r="3.2" stroke="currentColor" stroke-width="1.8"/><path d="M3 20c0-3.5 2.7-6 6-6s6 2.5 6 6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M16 4.5c1.5.3 2.6 1.7 2.6 3.3S17.5 10.8 16 11.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M17.5 14.3c2 .6 3.5 2.4 3.5 4.7" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>' },
  { href: 'bookings.html', label: 'Bookings', icon: '<svg viewBox="0 0 24 24" fill="none"><rect x="3" y="5" width="18" height="16" rx="2" stroke="currentColor" stroke-width="1.8"/><path d="M3 10h18M8 3v4M16 3v4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>' },
  { href: 'finances.html', label: 'Finances', icon: '<svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.8"/><path d="M12 7v10M9.5 9.3c0-1.1 1.1-2 2.5-2s2.5.7 2.5 1.8c0 2.4-5 1.1-5 3.5 0 1.1 1.1 1.8 2.5 1.8s2.5-.9 2.5-2" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>' },
  { href: 'settings.html', label: 'Settings', icon: '<svg viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3" stroke="currentColor" stroke-width="1.8"/><path d="M19.4 13.5a1.7 1.7 0 000-3l-1.1-.3a7.3 7.3 0 00-.7-1.7l.6-1a1.7 1.7 0 00-2.4-2.4l-1 .6a7.3 7.3 0 00-1.7-.7L13 3.6a1.7 1.7 0 00-3 0l-.3 1.1a7.3 7.3 0 00-1.7.7l-1-.6a1.7 1.7 0 00-2.4 2.4l.6 1a7.3 7.3 0 00-.7 1.7L3.6 11a1.7 1.7 0 000 3l1.1.3c.15.6.4 1.17.7 1.7l-.6 1a1.7 1.7 0 002.4 2.4l1-.6c.53.3 1.1.55 1.7.7l.3 1.1a1.7 1.7 0 003 0l.3-1.1a7.3 7.3 0 001.7-.7l1 .6a1.7 1.7 0 002.4-2.4l-.6-1c.3-.53.55-1.1.7-1.7l1.1-.3z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg>' },
];

function renderAdminSidebar(activePage, adminEmail) {
  const navHtml = ADMIN_NAV_ITEMS.map(item => `
    <a href="${item.href}" class="${item.href === activePage ? 'active' : ''}">
      ${item.icon}
      <span>${item.label}</span>
      ${item.href === 'bookings.html' ? '<span class="nav-badge" id="bookingsNavBadge" style="display:none;"></span>' : ''}
    </a>
  `).join('');

  return `
    <div class="admin-topbar">
      <img src="https://res.cloudinary.com/dmr5kchzw/image/upload/v1786601006/Add_red_elements_to_image_202608131118_1_rtqnyl.png" alt="Just Detail">
      <button class="admin-menu-toggle" id="adminMenuToggle" aria-label="Toggle menu">
        <svg viewBox="0 0 24 24" fill="none"><path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
      </button>
    </div>
    <aside class="admin-sidebar" id="adminSidebar">
      <div class="admin-sidebar-logo">
        <img src="https://res.cloudinary.com/dmr5kchzw/image/upload/v1786601006/Add_red_elements_to_image_202608131118_1_rtqnyl.png" alt="Just Detail">
        <span>Admin Panel</span>
      </div>
      <nav class="admin-nav">${navHtml}</nav>
      <div class="admin-sidebar-footer">
        <div class="admin-user-email">${adminEmail || ''}</div>
        <button class="admin-logout-btn" id="adminLogoutBtn">Log Out</button>
      </div>
    </aside>
  `;
}

function initAdminShell(activePage, adminUser) {
  const shellTarget = document.getElementById('adminShell');
  shellTarget.insertAdjacentHTML('afterbegin', renderAdminSidebar(activePage, adminUser ? adminUser.email : ''));

  document.getElementById('adminLogoutBtn').addEventListener('click', adminSignOut);

  const menuToggle = document.getElementById('adminMenuToggle');
  const sidebar = document.getElementById('adminSidebar');
  if (menuToggle && sidebar) {
    menuToggle.addEventListener('click', () => sidebar.classList.toggle('open'));
  }

  refreshBookingsNavBadge();
}

// Shows a count on the sidebar's "Bookings" link for unpaid one-time
// bookings — the same "needs attention" definition used on the dashboard's
// "New One-Time Bookings" panel, so the badge and panel always agree.
async function refreshBookingsNavBadge() {
  const badge = document.getElementById('bookingsNavBadge');
  if (!badge || typeof supabaseClient === 'undefined') return;

  const { data, error } = await supabaseClient
    .from('one_time_bookings')
    .select('id, payments(id)');

  if (error || !data) return;

  const unpaidCount = data.filter(b => !b.payments || b.payments.length === 0).length;

  if (unpaidCount > 0) {
    badge.textContent = unpaidCount > 99 ? '99+' : String(unpaidCount);
    badge.style.display = 'inline-flex';
  } else {
    badge.style.display = 'none';
  }
}

function showToast(message, type) {
  const existing = document.querySelector('.toast');
  if (existing) existing.remove();

  const toast = document.createElement('div');
  toast.className = 'toast' + (type === 'error' ? ' toast-error' : '');
  toast.textContent = message;
  document.body.appendChild(toast);

  requestAnimationFrame(() => toast.classList.add('show'));
  setTimeout(() => {
    toast.classList.remove('show');
    setTimeout(() => toast.remove(), 300);
  }, 3000);
}

function formatDate(dateStr) {
  if (!dateStr) return '—';
  return new Date(dateStr).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
}

/**
 * Local YYYY-MM-DD string for a Date object — NOT toISOString(), which
 * converts to UTC and can shift the date backward for timezones ahead
 * of UTC (e.g. India, UTC+5:30), causing "today" filters to miss rows.
 */
function toLocalDateStr(d) {
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function badgeHtml(status) {
  const labels = {
    pending_confirmation: 'Pending',
    active: 'Active',
    completed: 'Completed',
    cancelled: 'Cancelled',
    pending: 'Pending',
    confirmed: 'Confirmed',
    rescheduled_by_admin: 'Rescheduled',
  };
  return `<span class="badge badge-${status}">${labels[status] || status}</span>`;
}

// ---------------- Reusable date field (trigger button + popover calendar) ----------------
// Usage: initDateField('expDate') wires up #expDateField, #expDateTrigger,
// #expDateValueText, #expDatePicker, #expDateGrid, #expDateMonthLabel,
// #expDatePrev/#expDateNext, and the hidden #expDate input — matching the
// id-prefix convention used across the admin forms.
// Returns { setDate(date), reset(), getDate() } for the caller to use.
function initDateField(idPrefix) {
  const field = document.getElementById(`${idPrefix}Field`);
  const trigger = document.getElementById(`${idPrefix}Trigger`);
  const valueEl = document.getElementById(`${idPrefix}ValueText`);
  const picker = document.getElementById(`${idPrefix}Picker`);
  const grid = document.getElementById(`${idPrefix}Grid`);
  const monthLabel = document.getElementById(`${idPrefix}MonthLabel`);
  const prevBtn = document.getElementById(`${idPrefix}Prev`);
  const nextBtn = document.getElementById(`${idPrefix}Next`);
  const hiddenInput = document.getElementById(idPrefix);

  if (!field || !trigger || !picker || !hiddenInput) return null;

  let selectedDate = null;
  let viewDate = new Date();

  function render() {
    const year = viewDate.getFullYear();
    const month = viewDate.getMonth();
    monthLabel.textContent = viewDate.toLocaleString('en-IN', { month: 'long', year: 'numeric' });

    const firstDay = new Date(year, month, 1).getDay();
    const daysInMonth = new Date(year, month + 1, 0).getDate();

    grid.innerHTML = '';
    for (let i = 0; i < firstDay; i++) grid.appendChild(document.createElement('span'));

    for (let d = 1; d <= daysInMonth; d++) {
      const cellDate = new Date(year, month, d);
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.textContent = d;
      btn.className = 'custom-date-cell';
      btn.addEventListener('click', () => selectDate(cellDate, btn));
      if (selectedDate && cellDate.toDateString() === selectedDate.toDateString()) {
        btn.classList.add('custom-date-cell-selected');
      }
      grid.appendChild(btn);
    }
  }

  function selectDate(date, btnEl) {
    selectedDate = date;
    hiddenInput.value = toLocalDateStr(date);
    hiddenInput.dispatchEvent(new Event('change', { bubbles: true }));
    grid.querySelectorAll('.custom-date-cell').forEach(c => c.classList.remove('custom-date-cell-selected'));
    if (btnEl) btnEl.classList.add('custom-date-cell-selected');
    valueEl.textContent = date.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
    valueEl.classList.remove('is-placeholder');
    close();
  }

  function open() {
    // position: fixed popover — compute exact viewport coordinates so it
    // renders above the modal's own scroll container instead of being
    // clipped/scrolled by it (the bug this replaces: position:absolute
    // inside a scrolling .fin-modal-body triggered an extra scrollbar).
    //
    // Also: move the picker to a direct child of <body>. A `position: fixed`
    // element is positioned relative to the nearest ancestor that has a
    // CSS `transform` set (per spec) rather than the viewport — and modals
    // like .fin-modal use `transform` for their open/close animation, which
    // was silently hijacking the picker's coordinates.
    if (picker.parentElement !== document.body) {
      picker._originalParent = picker.parentElement;
      picker._originalNextSibling = picker.nextSibling;
      document.body.appendChild(picker);
    }

    const rect = trigger.getBoundingClientRect();
    const pickerWidth = 280;
    const pickerHeight = 340; // generous estimate; picker itself scrolls if ever taller
    const spaceBelow = window.innerHeight - rect.bottom;
    const openUpward = spaceBelow < pickerHeight && rect.top > spaceBelow;

    picker.style.left = Math.min(Math.max(rect.left, 12), window.innerWidth - pickerWidth - 12) + 'px';
    picker.classList.toggle('drop-up', openUpward);

    if (openUpward) {
      picker.style.top = '';
      picker.style.bottom = (window.innerHeight - rect.top + 8) + 'px';
    } else {
      picker.style.bottom = '';
      picker.style.top = (rect.bottom + 8) + 'px';
    }

    field.classList.add('open');
    picker.classList.add('picker-open');
    trigger.setAttribute('aria-expanded', 'true');

    // A fixed-position popover won't track the trigger if the modal itself
    // scrolls underneath it — simplest robust fix is to just close it.
    const modalScrollParent = trigger.closest('.fin-modal, .fin-modal-body');
    if (modalScrollParent) {
      modalScrollParent.addEventListener('scroll', close, { once: true });
    }
  }
  function close() {
    field.classList.remove('open');
    picker.classList.remove('picker-open');
    trigger.setAttribute('aria-expanded', 'false');
    // Move the picker back to its original spot in the form once closed,
    // so the DOM stays clean and the field still "owns" it structurally.
    if (picker._originalParent && picker.parentElement === document.body) {
      picker._originalParent.insertBefore(picker, picker._originalNextSibling);
    }
  }

  trigger.addEventListener('click', (e) => {
    e.stopPropagation();
    field.classList.contains('open') ? close() : open();
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest(`#${idPrefix}Field`) && !e.target.closest(`#${idPrefix}Picker`)) close();
  });
  prevBtn.addEventListener('click', (e) => { e.stopPropagation(); viewDate.setMonth(viewDate.getMonth() - 1); render(); });
  nextBtn.addEventListener('click', (e) => { e.stopPropagation(); viewDate.setMonth(viewDate.getMonth() + 1); render(); });

  render();

  return {
    setDate(date) { selectDate(date); viewDate = new Date(date); render(); },
    reset() {
      selectedDate = null;
      viewDate = new Date();
      hiddenInput.value = '';
      valueEl.textContent = 'Select a date';
      valueEl.classList.add('is-placeholder');
      close();
      render();
    },
    getDate() { return selectedDate; },
  };
}

// ---------------- Reusable custom dropdown ----------------
// Call initAllCustomSelects() once per page after the DOM (including any
// dynamically-inserted <select> markup) exists. Works with both static
// <li> option lists and lists populated later via populateCustomSelectList().

function positionCustomDropdown(trigger, list) {
  list.classList.remove('drop-up');
  const triggerRect = trigger.getBoundingClientRect();
  const listHeight = Math.min(list.scrollHeight, 240) + 10;
  const spaceBelow = window.innerHeight - triggerRect.bottom;
  const spaceAbove = triggerRect.top;
  if (spaceBelow < listHeight && spaceAbove > spaceBelow) {
    list.classList.add('drop-up');
  }
}

function initCustomSelect(wrap) {
  if (wrap._customSelectInit) return; // avoid double-binding
  wrap._customSelectInit = true;

  const trigger = wrap.querySelector('.custom-select-trigger');
  const list = wrap.querySelector('.custom-select-list');
  const valueEl = wrap.querySelector('.custom-select-value');
  const targetSelect = document.getElementById(wrap.dataset.target);

  function closeThis() {
    wrap.classList.remove('open');
    trigger.setAttribute('aria-expanded', 'false');
  }

  trigger.addEventListener('click', () => {
    document.querySelectorAll('.custom-select.open').forEach(w => { if (w !== wrap) w.classList.remove('open'); });
    const isOpen = wrap.classList.toggle('open');
    trigger.setAttribute('aria-expanded', String(isOpen));
    if (isOpen) {
      positionCustomDropdown(trigger, list);
      const selected = list.querySelector('li[aria-selected="true"]') || list.querySelector('li');
      if (selected) selected.focus();
    }
  });

  function selectOption(li) {
    list.querySelectorAll('li').forEach(o => o.setAttribute('aria-selected', 'false'));
    li.setAttribute('aria-selected', 'true');
    valueEl.textContent = li.textContent;
    valueEl.classList.remove('is-placeholder');
    targetSelect.value = li.dataset.value;
    targetSelect.dispatchEvent(new Event('change', { bubbles: true }));
    closeThis();
    trigger.focus();
  }

  function wireOptions() {
    const options = Array.from(list.querySelectorAll('li'));
    options.forEach((li, idx) => {
      li.setAttribute('tabindex', '-1');
      li.onclick = () => selectOption(li);
      li.onkeydown = (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectOption(li); }
        else if (e.key === 'ArrowDown') { e.preventDefault(); (options[idx + 1] || options[0]).focus(); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); (options[idx - 1] || options[options.length - 1]).focus(); }
        else if (e.key === 'Escape') { closeThis(); trigger.focus(); }
      };
    });
  }
  wireOptions();
  wrap._rewireOptions = wireOptions;

  document.addEventListener('click', (e) => {
    if (!e.target.closest('.custom-select')) closeThis();
  });
}

function initAllCustomSelects(root) {
  (root || document).querySelectorAll('.custom-select').forEach(initCustomSelect);
}

// Populate (or re-populate) a custom-select's option list from JS data,
// e.g. dropdowns whose options depend on live database rows.
// items: [{ value, label }]
function populateCustomSelectList(wrap, items) {
  const list = wrap.querySelector('.custom-select-list');
  list.innerHTML = items.map(i => `<li role="option" data-value="${i.value}">${i.label}</li>`).join('');

  // The hidden native <select> must also get matching <option> elements —
  // otherwise setting its .value to a selected item silently fails (no
  // matching option = value stays empty), which can break native "required"
  // validation even though the visible UI looks correctly selected.
  const targetSelect = document.getElementById(wrap.dataset.target);
  if (targetSelect) {
    targetSelect.innerHTML = items.map(i => `<option value="${i.value}">${i.label}</option>`).join('');
    targetSelect.value = '';
  }

  const valueEl = wrap.querySelector('.custom-select-value');
  valueEl.textContent = valueEl.dataset.placeholder;
  valueEl.classList.add('is-placeholder');
  initCustomSelect(wrap); // ensure it's bound
  if (wrap._rewireOptions) wrap._rewireOptions();
}

// Set a custom-select's value programmatically (e.g. pre-filling from a
// "Record Payment →" link's URL param), keeping trigger label, hidden
// select, and aria-selected all in sync.
function setCustomSelectValue(hiddenSelectId, value) {
  const wrap = document.querySelector(`.custom-select[data-target="${hiddenSelectId}"]`);
  const targetSelect = document.getElementById(hiddenSelectId);
  if (!wrap || !targetSelect) return;

  const list = wrap.querySelector('.custom-select-list');
  const valueEl = wrap.querySelector('.custom-select-value');
  const li = Array.from(list.querySelectorAll('li')).find(o => o.dataset.value === String(value));
  if (!li) return;

  list.querySelectorAll('li').forEach(o => o.setAttribute('aria-selected', 'false'));
  li.setAttribute('aria-selected', 'true');
  valueEl.textContent = li.textContent;
  valueEl.classList.remove('is-placeholder');
  targetSelect.value = value;
  targetSelect.dispatchEvent(new Event('change', { bubbles: true }));
}
