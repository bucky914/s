// =========================================================
// Admin Bookings — filterable list with status actions
// IMPORTANT: washes_used/washes_remaining are updated automatically
// by a database trigger when a booking's status becomes 'completed'.
// This file never writes to those columns directly.
//
// New bookings/reschedules are validated atomically by the database
// (book_maintenance_visit / admin_reschedule_maintenance_visit RPCs —
// see supabase/migrations/booking_automation_and_availability.sql),
// which enforce the 4-hour overlap rule and full-day one-time-service
// blocking. Client-side date/time filtering here is a UX convenience only.
// =========================================================

let currentFilter = 'today';
let allOneTimeBookings = [];
let onetimeSearchTerm = '';
let onetimePayFilter = 'all';

// Dedicated maintenance-booking date picker for the reschedule modal.
// Kept separate from initDateField()'s other callers (e.g. expense
// dates on finances.html) so that adding conflict-aware disabling here
// can't affect unrelated admin date fields.
let rescheduleDateFieldCtl = null;
let rescheduleOccupiedDates = new Set();
let rescheduleEditingBookingId = null;
let currentBookingsById = {}; // populated by renderBookingsTable, used by the reschedule button

async function init() {
  const adminUser = await requireAdmin();
  if (!adminUser) return;

  initAdminShell('bookings.html', adminUser);

  document.querySelectorAll('#statusFilters .filter-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('#statusFilters .filter-chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      currentFilter = chip.dataset.filter;
      loadBookings();
    });
  });

  document.querySelectorAll('#bookingTypeTabs .filter-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('#bookingTypeTabs .filter-chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      const tab = chip.dataset.tab;
      document.getElementById('maintenanceView').style.display = tab === 'maintenance' ? 'block' : 'none';
      document.getElementById('onetimeView').style.display = tab === 'onetime' ? 'block' : 'none';
      if (tab === 'onetime' && allOneTimeBookings.length === 0) loadOneTimeBookings();
    });
  });

  document.getElementById('onetimeSearch').addEventListener('input', (e) => {
    onetimeSearchTerm = e.target.value.trim().toLowerCase();
    renderOneTimeBookings();
  });

  document.querySelectorAll('#onetimePaymentFilters .filter-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('#onetimePaymentFilters .filter-chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      onetimePayFilter = chip.dataset.payfilter;
      renderOneTimeBookings();
    });
  });

  initRescheduleModal();

  await loadBookings();
  document.getElementById('pageLoading').style.display = 'none';
  document.getElementById('pageContent').style.display = 'block';
}

// ---------------- Reschedule modal ----------------

function initRescheduleModal() {
  const overlay = document.getElementById('rescheduleModalOverlay');
  const closeBtn = document.getElementById('rescheduleModalClose');
  const form = document.getElementById('rescheduleForm');

  rescheduleDateFieldCtl = initDateField('rescheduleDate');

  // initDateField() re-renders the grid on month navigation (its own
  // click handlers run first since they're bound first); re-fetch and
  // re-apply our occupied-date disabling afterward on each navigation
  // click so it survives the re-render instead of being wiped by it.
  document.getElementById('rescheduleDatePrev').addEventListener('click', () => loadRescheduleOccupiedDates(rescheduleEditingBookingId));
  document.getElementById('rescheduleDateNext').addEventListener('click', () => loadRescheduleOccupiedDates(rescheduleEditingBookingId));

  function close() {
    overlay.classList.remove('open');
    document.body.style.overflow = '';
  }

  closeBtn.addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    await submitReschedule();
  });

  window._closeRescheduleModal = close;
}

async function openRescheduleModal(booking) {
  rescheduleEditingBookingId = booking.id;
  document.getElementById('rescheduleBookingId').value = booking.id;
  document.getElementById('rescheduleTime').value = booking.confirmed_time || booking.requested_time || '';
  document.getElementById('rescheduleNote').value = '';
  rescheduleDateFieldCtl.reset();
  rescheduleAvailabilityCache = {};

  // Load currently fully-occupied dates (confirmed one-time service, or
  // every 4-hour maintenance slot taken) so the admin can't even try a
  // date that's certain to fail. Same-day non-overlapping maintenance
  // bookings are allowed — only whole-day blocks are pre-filtered here;
  // the actual overlap check happens server-side in
  // admin_reschedule_maintenance_visit(), which also excludes this
  // booking's own current slot from the conflict check.
  await loadRescheduleOccupiedDates(booking.id);

  const overlay = document.getElementById('rescheduleModalOverlay');
  overlay.classList.add('open');
  document.body.style.overflow = 'hidden';
}

let rescheduleAvailabilityCache = {};

// Pre-fetches availability for the currently visible month so obviously
// full days can be disabled up front. This is a UX convenience only —
// admin_reschedule_maintenance_visit() re-validates the exact date/time
// atomically at submit time regardless of what this found.
async function loadRescheduleOccupiedDates(excludeBookingId) {
  const grid = document.getElementById('rescheduleDateGrid');
  const monthLabel = document.getElementById('rescheduleDateMonthLabel');
  if (!grid || !monthLabel) return;

  const label = monthLabel.textContent.trim();
  const [monthName, yearStr] = label.split(' ');
  const monthIdx = RESCHEDULE_MONTH_NAMES.indexOf(monthName);
  const year = parseInt(yearStr, 10);
  if (monthIdx === -1 || isNaN(year)) return;

  const daysInMonth = new Date(year, monthIdx + 1, 0).getDate();
  const dateStrs = [];
  for (let d = 1; d <= daysInMonth; d++) dateStrs.push(toLocalDateStr(new Date(year, monthIdx, d)));

  const results = await Promise.all(dateStrs.map(async (dateStr) => {
    if (rescheduleAvailabilityCache[dateStr]) return rescheduleAvailabilityCache[dateStr];
    const { data, error } = await supabaseClient.rpc('get_booking_availability', { p_date: dateStr });
    if (error) return null;
    rescheduleAvailabilityCache[dateStr] = data;
    return data;
  }));

  rescheduleOccupiedDates = new Set();
  results.forEach((data, i) => {
    // A day can show fully_unavailable because this very booking's own
    // current slot fills it — that's not a real conflict for a
    // reschedule (the server-side RPC excludes this booking's own row).
    // Only pre-disable a day for a one-time service block, which is an
    // unconditional whole-day block regardless of this booking.
    if (data && data.service_booked) rescheduleOccupiedDates.add(dateStrs[i]);
  });

  applyRescheduleDateDisabling();
}

// initDateField()'s month label is rendered via toLocaleString('en-IN',
// { month: 'long', year: 'numeric' }) — e.g. "August 2026". Parsed back
// out here rather than re-parsed with new Date(string), which is
// locale-dependent and unreliable across browsers.
const RESCHEDULE_MONTH_NAMES = ['January','February','March','April','May','June','July','August','September','October','November','December'];

// Marks occupied dates as disabled inside the reschedule picker's grid.
// Runs after each render (initial load + month navigation), since
// initDateField() rebuilds the grid's buttons on every render() call.
function applyRescheduleDateDisabling() {
  const grid = document.getElementById('rescheduleDateGrid');
  if (!grid) return;

  const monthLabel = document.getElementById('rescheduleDateMonthLabel').textContent.trim();
  const [monthName, yearStr] = monthLabel.split(' ');
  const monthIdx = RESCHEDULE_MONTH_NAMES.indexOf(monthName);
  const year = parseInt(yearStr, 10);
  if (monthIdx === -1 || isNaN(year)) return;

  grid.querySelectorAll('.custom-date-cell').forEach(btn => {
    if (btn.disabled) return; // leave any pre-existing disabled state alone
    const day = parseInt(btn.textContent.trim(), 10);
    if (isNaN(day)) return;
    const dateStr = toLocalDateStr(new Date(year, monthIdx, day));
    if (rescheduleOccupiedDates.has(dateStr)) {
      btn.disabled = true;
      btn.classList.add('custom-date-cell-disabled');
      btn.classList.add('custom-date-cell-booked');
      btn.title = 'Fully booked (one-time service)';
    }
  });
}

async function submitReschedule() {
  const submitBtn = document.getElementById('rescheduleSubmit');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Saving…';

  const bookingId = document.getElementById('rescheduleBookingId').value;
  const newDate = document.getElementById('rescheduleDate').value;
  const newTime = document.getElementById('rescheduleTime').value.trim();
  const note = document.getElementById('rescheduleNote').value.trim();

  if (!newDate) {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Save New Date';
    showToast('Please pick a date.', 'error');
    return;
  }
  if (!newTime) {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Save New Date';
    showToast('Please enter a time (e.g. 10:00 AM).', 'error');
    return;
  }

  // admin_reschedule_maintenance_visit() is the same atomic, database-side
  // check used for customer bookings: it validates business hours, the
  // full-day one-time-service block, and the 4-hour overlap rule under
  // row locks, excluding this booking's own current slot from the
  // conflict check. requested_date/time are intentionally left untouched
  // by the RPC — only confirmed_date/confirmed_time/status change.
  const { error } = await supabaseClient.rpc('admin_reschedule_maintenance_visit', {
    p_booking_id: bookingId,
    p_new_date: newDate,
    p_new_time: newTime,
    p_note: note || null,
  });

  submitBtn.disabled = false;
  submitBtn.textContent = 'Save New Date';

  if (error) {
    const message = error.message || '';
    if (message.includes('SLOT_CONFLICT') || message.includes('DATE_FULLY_BOOKED')) {
      showToast('This slot is already occupied by another booking. Please select another date or time.', 'error');
      rescheduleAvailabilityCache = {};
      await loadRescheduleOccupiedDates(bookingId);
      return;
    }
    if (message.includes('OUTSIDE_BUSINESS_HOURS')) {
      showToast("That time doesn't fit within business hours.", 'error');
      return;
    }
    showToast('Failed to reschedule: ' + error.message, 'error');
    return;
  }

  showToast('Booking rescheduled.');
  window._closeRescheduleModal();
  await loadBookings();
}

async function loadOneTimeBookings() {
  const { data, error } = await supabaseClient
    .from('one_time_bookings')
    .select('*, payments(id, amount)')
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Failed to load one-time bookings:', error);
    allOneTimeBookings = [];
  } else {
    allOneTimeBookings = data || [];
  }

  renderOneTimeBookings();
}

function renderOneTimeBookings() {
  const tbody = document.getElementById('onetimeBody');
  const emptyEl = document.getElementById('onetimeEmpty');
  const tableEl = document.getElementById('onetimeTable');
  const filtered = allOneTimeBookings.filter(b => {
    // Search
    if (onetimeSearchTerm) {
      const matches = (b.customer_name || '').toLowerCase().includes(onetimeSearchTerm) ||
                       (b.customer_phone || '').toLowerCase().includes(onetimeSearchTerm);
      if (!matches) return false;
    }

    // Payment filter
    const isPaid = b.payments && b.payments.length > 0;
    if (onetimePayFilter === 'paid' && !isPaid) return false;
    if (onetimePayFilter === 'unpaid' && isPaid) return false;

    return true;
  });

  if (filtered.length === 0) {
    tableEl.style.display = 'none';
    emptyEl.style.display = 'block';
    return;
  }

  tableEl.style.display = 'table';
  emptyEl.style.display = 'none';

  tbody.innerHTML = filtered.map(b => {
    const isPaid = b.payments && b.payments.length > 0;
    const amount = b.calculated_price ? Number(b.calculated_price) : null;

    let actionHtml;
    if (isPaid) {
      actionHtml = '<span class="badge badge-active">Paid</span>';
    } else if (amount) {
      actionHtml = `
        <div class="btn-row">
          <button class="btn btn-success btn-sm" data-confirm-payment="${b.id}" data-amount="${amount}">Confirm Payment</button>
          <a href="finances.html?pay_onetime=${b.id}" class="btn btn-outline btn-sm">Other Amount</a>
        </div>`;
    } else {
      actionHtml = `<a href="finances.html?pay_onetime=${b.id}" class="btn btn-outline btn-sm">Record Payment →</a>`;
    }

    return `
      <tr>
        <td>${b.customer_name}</td>
        <td>${b.customer_phone}</td>
        <td>${b.service}</td>
        <td>${b.vehicle_model || '—'}${b.vehicle_type ? ' · ' + b.vehicle_type : ''}</td>
        <td>${amount ? '₹' + amount.toLocaleString('en-IN') : '—'}</td>
        <td>${b.requested_date ? formatDate(b.requested_date) : '—'} ${b.requested_time || ''}</td>
        <td>${actionHtml}</td>
      </tr>
    `;
  }).join('');

  tbody.querySelectorAll('[data-confirm-payment]').forEach(btn => {
    btn.addEventListener('click', () => confirmOneTimePayment(btn.dataset.confirmPayment, btn.dataset.amount, btn));
  });
}

async function confirmOneTimePayment(bookingId, amount, btnEl) {
  btnEl.disabled = true;
  btnEl.textContent = 'Confirming…';

  const { error } = await supabaseClient.from('payments').insert({
    one_time_booking_id: bookingId,
    amount: Number(amount),
    payment_method: 'cash',
    payment_status: 'paid',
    payment_date: toLocalDateStr(new Date()),
  });

  if (error) {
    showToast('Failed to confirm payment: ' + error.message, 'error');
    btnEl.disabled = false;
    btnEl.textContent = 'Confirm Payment';
    return;
  }

  showToast('Payment confirmed — added to revenue.');
  await loadOneTimeBookings();
}

async function loadBookings() {
  const todayStr = toLocalDateStr(new Date());

  let query = supabaseClient
    .from('bookings')
    .select('*, subscriptions(vehicle_model, clients(full_name))');

  if (currentFilter === 'today') {
    query = query.eq('requested_date', todayStr).in('status', ['pending', 'confirmed', 'rescheduled_by_admin']);
  } else if (currentFilter === 'upcoming') {
    query = query.gt('requested_date', todayStr).in('status', ['pending', 'confirmed', 'rescheduled_by_admin']);
  } else if (currentFilter === 'completed') {
    query = query.eq('status', 'completed');
  } else if (currentFilter === 'cancelled') {
    query = query.eq('status', 'cancelled');
  }

  const { data, error } = await query.order('requested_date', { ascending: currentFilter !== 'completed' });

  renderBookingsTable(data || [], error);
}

function renderBookingsTable(data, error) {
  const tbody = document.getElementById('bookingsBody');
  const emptyEl = document.getElementById('bookingsEmpty');
  const tableEl = document.getElementById('bookingsTable');

  if (error || !data || data.length === 0) {
    tableEl.style.display = 'none';
    emptyEl.style.display = 'block';
    if (error) console.error('Failed to load bookings:', error);
    return;
  }

  tableEl.style.display = 'table';
  emptyEl.style.display = 'none';

  currentBookingsById = {};
  data.forEach(b => { currentBookingsById[b.id] = b; });

  tbody.innerHTML = data.map(b => {
    const customerName = b.subscriptions?.clients?.full_name || '—';
    const vehicle = b.subscriptions?.vehicle_model || '—';
    return `
      <tr>
        <td>${customerName}</td>
        <td>${vehicle}</td>
        <td>${formatDate(b.confirmed_date || b.requested_date)}</td>
        <td>${b.confirmed_time || b.requested_time || '—'}</td>
        <td>${visitTypeLabel(b.visit_type)}</td>
        <td>${badgeHtml(b.status)}</td>
        <td>${renderActions(b)}</td>
      </tr>
    `;
  }).join('');

  wireUpActions();
}

function renderActions(b) {
  if (b.status === 'pending') {
    return `
      <div class="btn-row">
        <button class="btn btn-success btn-sm" data-confirm="${b.id}">Confirm</button>
        <button class="btn btn-danger btn-sm" data-cancel="${b.id}">Cancel</button>
      </div>`;
  }
  if (b.status === 'confirmed' || b.status === 'rescheduled_by_admin') {
    return `
      <div class="btn-row">
        <button class="btn btn-primary btn-sm" data-complete="${b.id}">Mark Completed</button>
        <button class="btn btn-outline btn-sm" data-reschedule="${b.id}">Reschedule</button>
        <button class="btn btn-danger btn-sm" data-cancel="${b.id}">Cancel</button>
      </div>`;
  }
  // No per-booking payment action here — maintenance plan clients pay the
  // full plan price upfront at enrollment (see Customers page), not per visit.
  return '—';
}

function wireUpActions() {
  document.querySelectorAll('[data-confirm]').forEach(btn => {
    btn.addEventListener('click', () => updateBookingStatus(btn.dataset.confirm, 'confirmed', btn));
  });
  document.querySelectorAll('[data-cancel]').forEach(btn => {
    btn.addEventListener('click', () => {
      const note = prompt('Optional: add a reason the customer will see.', '');
      if (note === null) return;
      updateBookingStatus(btn.dataset.cancel, 'cancelled', btn, note);
    });
  });
  document.querySelectorAll('[data-complete]').forEach(btn => {
    btn.addEventListener('click', () => {
      if (confirm('Mark this booking as completed? This will count as one used wash for the customer.')) {
        updateBookingStatus(btn.dataset.complete, 'completed', btn);
      }
    });
  });
  document.querySelectorAll('[data-reschedule]').forEach(btn => {
    btn.addEventListener('click', () => {
      const booking = currentBookingsById[btn.dataset.reschedule];
      if (booking) openRescheduleModal(booking);
    });
  });
}

async function updateBookingStatus(bookingId, newStatus, btnEl, note) {
  btnEl.disabled = true;

  const updatePayload = { status: newStatus };
  if (note) updatePayload.admin_note = note;

  // The DB trigger (handle_booking_completion) automatically adjusts the
  // linked subscription's washes_used/washes_remaining when status becomes
  // 'completed' — no manual wash-count logic needed here.
  const { error } = await supabaseClient
    .from('bookings')
    .update(updatePayload)
    .eq('id', bookingId);

  if (error) {
    showToast('Failed to update booking: ' + error.message, 'error');
    btnEl.disabled = false;
    return;
  }

  const messages = {
    confirmed: 'Booking confirmed.',
    cancelled: 'Booking cancelled.',
    completed: 'Marked as completed — wash count updated.',
  };
  showToast(messages[newStatus] || 'Booking updated.');

  await loadBookings();
}

function visitTypeLabel(type) {
  const map = {
    deep_clean: 'Deep Clean',
    maintenance_wash: 'Maintenance Wash',
    mid_year_reset: 'Mid-Year Reset',
    bonus_perk: 'Bonus Perk',
  };
  return map[type] || type;
}

document.addEventListener('DOMContentLoaded', init);