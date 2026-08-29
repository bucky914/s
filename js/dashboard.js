// =========================================================
// Dashboard: guards access, loads subscriptions, handles
// enrollment and visit-request flows.
// =========================================================

let currentUser = null;
let currentClientRow = null;
let currentSubscriptions = [];
let visitSelectedDate = null;
let visitCalendarViewDate = new Date();

// Dates (YYYY-MM-DD, local) that are fully unavailable — either a
// confirmed one-time service occupies the whole day, or every 4-hour
// maintenance slot on that day is taken. Loaded per-date on demand via
// the get_booking_availability RPC (see loadDateAvailability()) rather
// than as one big list, since availability is now slot-level, not just
// date-level. The database's book_maintenance_visit() RPC is the real
// concurrency protection; this cache only drives the calendar UI so
// customers don't pick a date/time that's certain to fail.
let fullyUnavailableDates = new Set();
// Per-date availability responses from get_booking_availability, keyed
// by YYYY-MM-DD, cached for the current modal session so re-rendering
// the time-slot grid for an already-checked date doesn't re-fetch.
let dateAvailabilityCache = {};

// Same pattern as above, but for the enrollment panel's Deep Clean
// date/time picker — kept as separate state since the enroll panel and
// the visit modal are never open at the same time but use identically-
// shaped calendar widgets with different element ids (enDeepCleanDate*
// vs visitDate*).
let deepCleanSelectedDate = null;
let deepCleanCalendarViewDate = new Date();
let deepCleanFullyUnavailableDates = new Set();
let deepCleanAvailabilityCache = {};

// ---------------- Custom dropdown helpers (mirrors booking.js) ----------------

/**
 * Flip the dropdown list to open upward instead of downward if there isn't
 * enough room below it — prevents the list from being cut off or forcing
 * the whole modal to grow awkwardly near the bottom of the viewport.
 */
function positionDropdown(wrap, trigger, list) {
  list.classList.remove('drop-up');
  const triggerRect = trigger.getBoundingClientRect();
  // Measure the actual rendered height where possible (more accurate for
  // taller popovers like the calendar), falling back to the dropdown-list
  // max-height assumption for simple option lists.
  const listHeight = (list.offsetHeight || Math.min(list.scrollHeight, 240)) + 10;
  const spaceBelow = window.innerHeight - triggerRect.bottom;
  const spaceAbove = triggerRect.top;

  if (spaceBelow < listHeight && spaceAbove > spaceBelow) {
    list.classList.add('drop-up');
  }
}

function initCustomSelect(wrap) {
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
      positionDropdown(wrap, trigger, list);
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
  wrap._rewireOptions = wireOptions; // exposed so dynamically-populated lists can re-wire

  document.addEventListener('click', (e) => {
    if (!e.target.closest('.custom-select')) closeThis();
  });
}

function populateCustomSelectList(wrap, items) {
  // items: [{ value, label }]
  const list = wrap.querySelector('.custom-select-list');
  list.innerHTML = items.map(i => `<li role="option" data-value="${i.value}">${i.label}</li>`).join('');

  // The hidden native <select> must also get matching <option> elements —
  // otherwise setting its .value to a selected item silently fails (no
  // matching option = value stays empty), which broke this exact form's
  // native "required" validation even though the visible UI looked selected.
  const targetSelect = document.getElementById(wrap.dataset.target);
  if (targetSelect) {
    targetSelect.innerHTML = items.map(i => `<option value="${i.value}">${i.label}</option>`).join('');
    targetSelect.value = '';
  }

  const valueEl = wrap.querySelector('.custom-select-value');
  valueEl.textContent = valueEl.dataset.placeholder;
  valueEl.classList.add('is-placeholder');
  if (wrap._rewireOptions) wrap._rewireOptions();
}

async function init() {
  currentUser = await requireAuth();
  if (!currentUser) return; // requireAuth already redirects to login

  document.querySelectorAll('.custom-select').forEach(initCustomSelect);

  const logoutBtn = document.getElementById('logoutBtn');
  if (!logoutBtn._boundLogout) {
    logoutBtn.addEventListener('click', signOutClient);
    logoutBtn._boundLogout = true;
  }

  // Load (or create-on-first-login) the client's profile row
  const { data: clientRow, error: clientErr } = await supabaseClient
    .from('clients')
    .select('*')
    .eq('id', currentUser.id)
    .maybeSingle();

  if (clientErr) {
    console.error('Failed to load client profile:', clientErr);
  }
  currentClientRow = clientRow;

  if (currentClientRow) {
    document.getElementById('dashUserName').textContent = currentClientRow.full_name;
    document.getElementById('dashWelcomeName').textContent = ', ' + currentClientRow.full_name.split(' ')[0];
  }

  document.getElementById('dashLoading').style.display = 'none';

  const params = new URLSearchParams(window.location.search);
  const enrollPlanId = params.get('enroll');

  if (enrollPlanId) {
    await showEnrollPanel(enrollPlanId);
  } else {
    await loadSubscriptions();
    document.getElementById('dashContent').style.display = 'block';
  }
}

// ---------------- Enrollment flow ----------------
async function showEnrollPanel(planId) {
  const { data: plan, error } = await supabaseClient
    .from('plans')
    .select('*')
    .eq('id', planId)
    .maybeSingle();

  if (error || !plan) {
    console.error('Plan not found:', error);
    await loadSubscriptions();
    document.getElementById('dashContent').style.display = 'block';
    return;
  }

  document.getElementById('enrollPanel').style.display = 'block';
  document.getElementById('enrollPlanTitle').textContent = `Enroll — ${plan.tier_name}`;
  document.getElementById('enrollPlanSub').textContent =
    `${plan.vehicle_segment === 'suv' ? 'SUV / MPV / Large SUV' : 'Sedan / Hatch / Compact SUV'} · ₹${Number(plan.price).toLocaleString('en-IN')} · ${plan.total_regular_washes} washes`;

  const freqSelect = document.getElementById('enFrequency');
  const freqWrap = document.getElementById('enFrequencyCustom');
  populateCustomSelectList(freqWrap, plan.frequency_options.map(f => ({
    value: f, label: f === 'biweekly' ? 'Bi-weekly' : 'Monthly'
  })));

  if (plan.frequency_options.length > 1) {
    // Client picks — show the row, leave it unselected until they choose.
    document.getElementById('enFrequencyRow').style.display = 'flex';
  } else {
    // Only one option (e.g. VIP is bi-weekly only) — hide the picker since
    // there's nothing to choose, but the hidden <select> is still a
    // required form field, so it must be auto-selected or the browser
    // blocks submission on a field the user can never see or fill in.
    document.getElementById('enFrequencyRow').style.display = 'none';
    const only = plan.frequency_options[0];
    const onlyLi = freqWrap.querySelector(`li[data-value="${only}"]`);
    if (onlyLi) onlyLi.click();
  }

  document.getElementById('enrollCancel').addEventListener('click', () => {
    window.location.href = 'dashboard.html';
  });

  // Reset and initialize the Deep Clean date/time picker for this
  // enrollment session — same availability rules as booking a regular
  // maintenance visit (get_booking_availability / 7 AM-7 PM / 4-hour
  // interval / one-time-service full-day block).
  deepCleanSelectedDate = null;
  deepCleanCalendarViewDate = new Date();
  deepCleanFullyUnavailableDates = new Set();
  deepCleanAvailabilityCache = {};
  document.getElementById('enDeepCleanDate').value = '';
  const dcDateValueEl = document.getElementById('enDeepCleanDateValueText');
  dcDateValueEl.textContent = 'Select a date';
  dcDateValueEl.classList.add('is-placeholder');
  renderDeepCleanCalendar();
  loadDeepCleanMonthAvailability(deepCleanCalendarViewDate);

  const dcTimeWrap = document.getElementById('enDeepCleanTimeCustom');
  populateCustomSelectList(dcTimeWrap, []);
  const dcTimeValueEl = dcTimeWrap.querySelector('.custom-select-value');
  dcTimeValueEl.dataset.placeholder = 'Select a date first';
  dcTimeValueEl.textContent = 'Select a date first';

  const enrollForm = document.getElementById('enrollForm');

  enrollForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const submitBtn = document.getElementById('enrollSubmit');

    const deepCleanDate = document.getElementById('enDeepCleanDate').value;
    const deepCleanTime = document.getElementById('enDeepCleanTime').value;
    if (!deepCleanDate || !deepCleanTime) {
      alert('Please select a Deep Clean date and time.');
      return;
    }

    submitBtn.disabled = true;
    submitBtn.textContent = 'Activating…';

    const vehicleModel = document.getElementById('enVehicleModel').value.trim();
    const frequency = freqSelect.value || plan.frequency_options[0];
    const address = document.getElementById('enAddress').value.trim();

    // book_membership() is atomic: it creates the subscription
    // (status = 'active', immediately — no admin approval for the
    // membership itself), creates ONE payments row with
    // payment_status = 'pending' (admin confirms it separately — see
    // the Finances page), books the Deep Clean as a real conflict-
    // checked maintenance booking, and generates the rest of the
    // expected maintenance schedule from the chosen frequency. No
    // payment method is collected from the customer at all.
    const { error: rpcError } = await supabaseClient.rpc('book_membership', {
      p_plan_id: plan.id,
      p_vehicle_model: vehicleModel,
      p_frequency: frequency,
      p_service_address: address,
      p_deep_clean_date: deepCleanDate,
      p_deep_clean_time: deepCleanTime,
    });

    submitBtn.disabled = false;
    submitBtn.textContent = 'Activate Membership';

    if (rpcError) {
      const message = rpcError.message || '';
      if (message.includes('SLOT_CONFLICT')) {
        delete deepCleanAvailabilityCache[deepCleanDate];
        await loadDeepCleanAvailability(deepCleanDate);
        renderDeepCleanCalendar();
        alert('This maintenance time is no longer available. Please choose another time.');
        return;
      }
      if (message.includes('DATE_FULLY_BOOKED')) {
        deepCleanFullyUnavailableDates.add(deepCleanDate);
        delete deepCleanAvailabilityCache[deepCleanDate];
        renderDeepCleanCalendar();
        alert('This date is already fully booked. Please choose another date.');
        return;
      }
      if (message.includes('OUTSIDE_BUSINESS_HOURS')) {
        alert("That time doesn't fit within business hours. Please choose another time.");
        return;
      }
      if (message.includes('DATE_IN_PAST')) {
        alert('Please select a valid upcoming date.');
        return;
      }
      console.error('Membership activation failed:', rpcError);
      alert('Something went wrong activating your membership: ' + rpcError.message);
      return;
    }

    // Clean the ?enroll= param and show the dashboard with the new active subscription
    window.history.replaceState({}, '', 'dashboard.html');
    document.getElementById('enrollPanel').style.display = 'none';
    await loadSubscriptions();
    document.getElementById('dashContent').style.display = 'block';
    showEnrollSuccessBanner();
  });
}

// ---------------- Deep Clean date/time picker (enrollment) ----------------
// Structurally mirrors the visit-modal calendar (openVisitModal /
// renderVisitCalendar / selectVisitDate / renderVisitTimeSlots below),
// but targets the enDeepCleanDate* elements and its own state, since
// the enroll panel and the visit modal are never open at the same time.

async function loadDeepCleanAvailability(dateStr) {
  if (deepCleanAvailabilityCache[dateStr]) return deepCleanAvailabilityCache[dateStr];

  const { data, error } = await supabaseClient.rpc('get_booking_availability', { p_date: dateStr });

  if (error) {
    console.error('Failed to load availability for', dateStr, error);
    return null;
  }

  deepCleanAvailabilityCache[dateStr] = data;
  if (data.fully_unavailable) deepCleanFullyUnavailableDates.add(dateStr);
  return data;
}

// Same month-wide pre-fetch as loadMonthAvailability() in the visit
// modal — shows fully-booked dates as disabled before any click.
async function loadDeepCleanMonthAvailability(viewDate) {
  const year = viewDate.getFullYear();
  const month = viewDate.getMonth();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const earliestSelectable = new Date(); earliestSelectable.setHours(0, 0, 0, 0);
  earliestSelectable.setDate(earliestSelectable.getDate() + 1);

  const dateStrs = [];
  for (let d = 1; d <= daysInMonth; d++) {
    const cellDate = new Date(year, month, d);
    if (cellDate >= earliestSelectable) dateStrs.push(toLocalDateStr(cellDate));
  }

  await Promise.all(dateStrs.map(loadDeepCleanAvailability));
  renderDeepCleanCalendar();
}

function toggleDeepCleanDatePicker() {
  const field = document.getElementById('enDeepCleanDateField');
  const trigger = document.getElementById('enDeepCleanDateTrigger');
  const picker = document.getElementById('enDeepCleanDatePicker');
  const isOpen = field.classList.contains('open');

  if (!isOpen) {
    positionDropdown(field, trigger, picker);
    field.classList.add('open');
    trigger.setAttribute('aria-expanded', 'true');
  } else {
    field.classList.remove('open');
    trigger.setAttribute('aria-expanded', 'false');
  }
}

function closeDeepCleanDatePicker() {
  document.getElementById('enDeepCleanDateField').classList.remove('open');
  document.getElementById('enDeepCleanDateTrigger').setAttribute('aria-expanded', 'false');
}

function renderDeepCleanCalendar() {
  const grid = document.getElementById('enDeepCleanDateGrid');
  const label = document.getElementById('enDeepCleanDateMonthLabel');
  const year = deepCleanCalendarViewDate.getFullYear();
  const month = deepCleanCalendarViewDate.getMonth();

  label.textContent = deepCleanCalendarViewDate.toLocaleString('en-IN', { month: 'long', year: 'numeric' });

  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const earliestSelectable = new Date(); earliestSelectable.setHours(0, 0, 0, 0);
  earliestSelectable.setDate(earliestSelectable.getDate() + 1);

  grid.innerHTML = '';
  for (let i = 0; i < firstDay; i++) grid.appendChild(document.createElement('span'));

  for (let d = 1; d <= daysInMonth; d++) {
    const cellDate = new Date(year, month, d);
    const dateStr = toLocalDateStr(cellDate);
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = d;
    btn.className = 'custom-date-cell';
    const knownUnavailable = deepCleanFullyUnavailableDates.has(dateStr);
    if (cellDate < earliestSelectable) {
      btn.disabled = true;
      btn.classList.add('custom-date-cell-disabled');
    } else if (knownUnavailable) {
      btn.disabled = true;
      btn.classList.add('custom-date-cell-disabled');
      btn.classList.add('custom-date-cell-booked');
      btn.title = 'Fully booked';
    } else {
      btn.addEventListener('click', () => selectDeepCleanDate(cellDate, btn));
    }
    if (deepCleanSelectedDate && cellDate.toDateString() === deepCleanSelectedDate.toDateString()) {
      btn.classList.add('custom-date-cell-selected');
    }
    grid.appendChild(btn);
  }
}

async function selectDeepCleanDate(date, btnEl) {
  const dateStr = toLocalDateStr(date);

  const availability = await loadDeepCleanAvailability(dateStr);
  if (availability === null) return;
  if (availability.fully_unavailable) {
    renderDeepCleanCalendar();
    alert('This date is no longer available. Please select another date.');
    return;
  }

  deepCleanSelectedDate = date;
  document.getElementById('enDeepCleanDate').value = dateStr;
  document.querySelectorAll('#enDeepCleanDateGrid .custom-date-cell').forEach(c => c.classList.remove('custom-date-cell-selected'));
  if (btnEl) btnEl.classList.add('custom-date-cell-selected');

  const dateValueEl = document.getElementById('enDeepCleanDateValueText');
  dateValueEl.textContent = date.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
  dateValueEl.classList.remove('is-placeholder');

  closeDeepCleanDatePicker();
  // The membership's first wash is always a Deep Clean, which uses the
  // 7 AM-3 PM guest-service window (available_service_times) — the
  // same window book_membership() enforces server-side — not the
  // 7 AM-7 PM/4-hour available_maintenance_times window used for
  // regular maintenance visits (see renderVisitTimeSlots below).
  renderDeepCleanTimeSlots(availability.available_service_times || []);
}

function renderDeepCleanTimeSlots(availableTimes) {
  const wrap = document.getElementById('enDeepCleanTimeCustom');
  document.getElementById('enDeepCleanTime').value = '';

  if (availableTimes.length === 0) {
    populateCustomSelectList(wrap, []);
    const valueEl = wrap.querySelector('.custom-select-value');
    valueEl.dataset.placeholder = 'No times available';
    valueEl.textContent = 'No times available';
    return;
  }

  const valueEl = wrap.querySelector('.custom-select-value');
  valueEl.dataset.placeholder = 'Select a time';
  populateCustomSelectList(wrap, availableTimes.map(t => ({ value: t, label: t })));
}

function showEnrollSuccessBanner() {
  const banner = document.createElement('div');
  banner.className = 'booking-sent-banner';
  banner.textContent = '✓ Your membership is active. Your maintenance schedule has been created.';
  const target = document.querySelector('#dashContent .dash-welcome');
  target.parentNode.insertBefore(banner, target.nextSibling);
  setTimeout(() => banner.remove(), 6000);
}

// ---------------- Load subscriptions ----------------
async function loadSubscriptions() {
  const { data, error } = await supabaseClient
    .from('subscriptions')
    .select('*, plans(*), bookings(*), membership_maintenance_schedule(*), payments(*)')
    .eq('client_id', currentUser.id)
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Failed to load subscriptions:', error);
    currentSubscriptions = [];
  } else {
    currentSubscriptions = data || [];
  }

  renderSubscriptions();
}

function statusLabel(status) {
  const map = {
    // 'pending_confirmation' is kept here only to correctly label any
    // historical subscriptions created before enrollment became automatic.
    pending_confirmation: { text: 'Awaiting confirmation', cls: 'status-pending' },
    active: { text: 'Active', cls: 'status-active' },
    completed: { text: 'Completed', cls: 'status-completed' },
    cancelled: { text: 'Cancelled', cls: 'status-cancelled' },
  };
  return map[status] || { text: status, cls: '' };
}

function renderSubscriptions() {
  const container = document.getElementById('subscriptionsList');

  if (currentSubscriptions.length === 0) {
    container.innerHTML = `
      <div class="sub-empty">
        <p>You haven't enrolled in a care plan yet.</p>
        <a href="index.html#plans" class="btn btn-primary">View care plans</a>
      </div>`;
    return;
  }

  container.innerHTML = currentSubscriptions.map(sub => {
    const status = statusLabel(sub.status);
    const segmentLabel = sub.vehicle_segment === 'suv' ? 'SUV / MPV / Large SUV' : 'Sedan / Hatch / Compact SUV';
    const bookings = (sub.bookings || []).slice().sort((a, b) => new Date(b.requested_date) - new Date(a.requested_date));
    // 'pending' is kept in this check only so a historical pending booking
    // (from before booking became automatic) still counts as "open" and
    // blocks a duplicate request until an admin resolves it.
    const hasOpenBooking = bookings.some(b => b.status === 'pending' || b.status === 'confirmed' || b.status === 'rescheduled_by_admin');
    const canBookVisit = sub.status === 'active' && sub.washes_remaining > 0 && !hasOpenBooking;

    const pendingPayment = (sub.payments || []).find(p => p.payment_status === 'pending');

    const schedule = (sub.membership_maintenance_schedule || []).slice().sort((a, b) => a.sequence_number - b.sequence_number);

    return `
      <div class="sub-card">
        <div class="sub-card-top">
          <div>
            <span class="sub-status ${status.cls}">${status.text}</span>
            <h3>${sub.plans ? sub.plans.tier_name : 'Care Plan'}</h3>
            <p class="sub-meta">${sub.vehicle_model || segmentLabel} · ${segmentLabel}</p>
          </div>
        </div>

        ${pendingPayment ? `
          <p class="sub-pending-note">Payment of ₹${Number(pendingPayment.amount).toLocaleString('en-IN')} is awaiting confirmation. We'll update this once it's confirmed.</p>
        ` : ''}

        ${sub.status === 'pending_confirmation' ? `
          <p class="sub-pending-note">This is a historical enrollment from before instant activation — please contact us if this looks wrong.</p>
        ` : `
          <div class="sub-stats">
            <div class="sub-stat">
              <span class="sub-stat-num">${sub.washes_remaining}</span>
              <span class="sub-stat-label">Washes left</span>
            </div>
            <div class="sub-stat">
              <span class="sub-stat-num">${sub.washes_used}</span>
              <span class="sub-stat-label">Completed</span>
            </div>
            <div class="sub-stat">
              <span class="sub-stat-num">${sub.frequency === 'biweekly' ? 'Bi-wk' : 'Monthly'}</span>
              <span class="sub-stat-label">Frequency</span>
            </div>
          </div>
        `}

        ${canBookVisit ? `<button class="btn btn-primary btn-block" onclick="openVisitModal('${sub.id}')">Book maintenance visit</button>` : ''}
        ${sub.status === 'active' && hasOpenBooking ? `<p class="sub-open-booking-note">You already have a visit request in progress — you can request the next one once it's completed.</p>` : ''}

        ${schedule.length > 0 ? `
          <div class="sub-schedule">
            <p class="sub-bookings-label">Your Maintenance Schedule</p>
            ${schedule.map(s => `
              <div class="sub-schedule-row">
                <span class="sub-schedule-label">${s.sequence_number === 0 ? 'Deep Clean' : (s.sequence_number === 1 ? 'Next Maintenance' : 'Following')}</span>
                <span class="sub-schedule-date">${formatVisitDate(s.scheduled_date)}</span>
                <span class="booking-status booking-status-${s.status === 'booked' || s.status === 'completed' ? 'confirmed' : s.status}">${scheduleStatusLabel(s.status)}</span>
              </div>
            `).join('')}
          </div>
        ` : ''}

        ${bookings.length > 0 ? `
          <div class="sub-bookings">
            <p class="sub-bookings-label">Your visit requests</p>
            ${bookings.map(b => `
              <div class="sub-booking-row">
                <div class="sub-booking-info">
                  <span class="sub-booking-date">${formatVisitDate(b.confirmed_date || b.requested_date)}</span>
                  <span class="sub-booking-time">${b.confirmed_time || b.requested_time || ''}</span>
                </div>
                <span class="booking-status booking-status-${b.status}">${bookingStatusLabel(b.status)}</span>
              </div>
              ${(b.status === 'rescheduled_by_admin' || b.status === 'cancelled') && b.admin_note ? `<p class="sub-booking-note">${b.admin_note}</p>` : ''}
            `).join('')}
          </div>
        ` : ''}
      </div>
    `;
  }).join('');
}

function scheduleStatusLabel(status) {
  const map = {
    scheduled: 'Upcoming',
    booked: 'Booked',
    completed: 'Completed',
    skipped: 'Skipped',
    cancelled: 'Cancelled',
  };
  return map[status] || status;
}

function bookingStatusLabel(status) {
  const map = {
    // 'pending' only labels historical bookings created before booking
    // became automatic — new bookings go straight to 'confirmed'.
    pending: 'Pending confirmation',
    confirmed: 'Confirmed',
    rescheduled_by_admin: 'Reschedule proposed',
    completed: 'Completed',
    cancelled: 'Cancelled',
  };
  return map[status] || status;
}

function formatVisitDate(dateStr) {
  if (!dateStr) return '—';
  return new Date(dateStr).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
}

// ---------------- Visit request modal ----------------
function toLocalDateStr(d) {
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

async function openVisitModal(subscriptionId) {
  document.getElementById('visitSubscriptionId').value = subscriptionId;
  document.getElementById('visitForm').reset();
  document.getElementById('visitSubscriptionId').value = subscriptionId; // reset() clears hidden inputs too
  document.getElementById('visitModalOverlay').classList.add('open');
  document.body.style.overflow = 'hidden';

  // Reset the date field back to its closed, unselected state
  visitSelectedDate = null;
  visitCalendarViewDate = new Date();
  document.getElementById('visitDate').value = '';
  document.getElementById('visitDateField').classList.remove('open');
  const dateValueEl = document.getElementById('visitDateValueText');
  dateValueEl.textContent = 'Select a date';
  dateValueEl.classList.add('is-placeholder');

  // Reset the time dropdown's visible state
  const timeWrap = document.getElementById('visitTimeCustom');
  const timeValueEl = timeWrap.querySelector('.custom-select-value');
  timeValueEl.textContent = timeValueEl.dataset.placeholder;
  timeValueEl.classList.add('is-placeholder');
  timeWrap.querySelectorAll('li').forEach(li => li.setAttribute('aria-selected', 'false'));

  // Clear any stale per-date cache and render the calendar immediately,
  // then pre-fetch the whole visible month's availability in parallel
  // so fully-booked dates appear disabled before any click, not only
  // after one.
  fullyUnavailableDates = new Set();
  dateAvailabilityCache = {};
  renderVisitCalendar();
  loadMonthAvailability(visitCalendarViewDate);
}

// Loads slot-level availability for one date via the get_booking_availability
// RPC (see supabase/migrations/booking_automation_and_availability.sql).
// This is a UI convenience only — book_maintenance_visit() re-checks
// everything atomically at submit time, which is the real protection.
async function loadDateAvailability(dateStr) {
  if (dateAvailabilityCache[dateStr]) return dateAvailabilityCache[dateStr];

  const { data, error } = await supabaseClient.rpc('get_booking_availability', { p_date: dateStr });

  if (error) {
    console.error('Failed to load availability for', dateStr, error);
    showVisitAvailabilityError(true);
    return null;
  }

  showVisitAvailabilityError(false);
  dateAvailabilityCache[dateStr] = data;
  if (data.fully_unavailable) fullyUnavailableDates.add(dateStr);
  return data;
}

// Pre-fetches availability for every future day in the currently
// visible month, in parallel, so fully-booked dates show as disabled
// on the calendar BEFORE the customer clicks anything — not only
// after. Re-uses loadDateAvailability()'s per-date cache, so a date
// checked here isn't re-fetched when the customer later clicks it.
async function loadMonthAvailability(viewDate) {
  const year = viewDate.getFullYear();
  const month = viewDate.getMonth();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const earliestSelectable = new Date(); earliestSelectable.setHours(0, 0, 0, 0);
  earliestSelectable.setDate(earliestSelectable.getDate() + 1);

  const dateStrs = [];
  for (let d = 1; d <= daysInMonth; d++) {
    const cellDate = new Date(year, month, d);
    if (cellDate >= earliestSelectable) dateStrs.push(toLocalDateStr(cellDate));
  }

  await Promise.all(dateStrs.map(loadDateAvailability));
  renderVisitCalendar();
}

// Shows/hides a small inline notice in the visit modal when availability
// couldn't be loaded, so the calendar's disabled/enabled state is never
// misread as confirmed availability when we don't actually have it.
function showVisitAvailabilityError(show) {
  let notice = document.getElementById('visitAvailabilityError');
  if (!notice) {
    notice = document.createElement('p');
    notice.id = 'visitAvailabilityError';
    notice.className = 'sub-open-booking-note';
    notice.textContent = "Couldn't check date availability — please try reopening this before choosing a date.";
    const grid = document.getElementById('visitDateGrid');
    grid.parentElement.insertBefore(notice, grid);
  }
  notice.style.display = show ? 'block' : 'none';
}

function toggleVisitDatePicker() {
  const field = document.getElementById('visitDateField');
  const trigger = document.getElementById('visitDateTrigger');
  const picker = document.getElementById('visitDatePicker');
  const isOpen = field.classList.contains('open');

  if (!isOpen) {
    positionDropdown(field, trigger, picker);
    field.classList.add('open');
    trigger.setAttribute('aria-expanded', 'true');
  } else {
    field.classList.remove('open');
    trigger.setAttribute('aria-expanded', 'false');
  }
}

function closeVisitDatePicker() {
  document.getElementById('visitDateField').classList.remove('open');
  document.getElementById('visitDateTrigger').setAttribute('aria-expanded', 'false');
}

function renderVisitCalendar() {
  const grid = document.getElementById('visitDateGrid');
  const label = document.getElementById('visitDateMonthLabel');
  const year = visitCalendarViewDate.getFullYear();
  const month = visitCalendarViewDate.getMonth();

  label.textContent = visitCalendarViewDate.toLocaleString('en-IN', { month: 'long', year: 'numeric' });

  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  // Earliest bookable day is TOMORROW — same-day requests risk landing on
  // a slot that's already passed, so today is disabled along with the past.
  const earliestSelectable = new Date(); earliestSelectable.setHours(0, 0, 0, 0);
  earliestSelectable.setDate(earliestSelectable.getDate() + 1);

  grid.innerHTML = '';
  for (let i = 0; i < firstDay; i++) grid.appendChild(document.createElement('span'));

  for (let d = 1; d <= daysInMonth; d++) {
    const cellDate = new Date(year, month, d);
    const dateStr = toLocalDateStr(cellDate);
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = d;
    btn.className = 'custom-date-cell';
    const knownUnavailable = fullyUnavailableDates.has(dateStr);
    if (cellDate < earliestSelectable) {
      btn.disabled = true;
      btn.classList.add('custom-date-cell-disabled');
    } else if (knownUnavailable) {
      btn.disabled = true;
      btn.classList.add('custom-date-cell-disabled');
      btn.classList.add('custom-date-cell-booked');
      btn.title = 'Fully booked';
    } else {
      btn.addEventListener('click', () => selectVisitDate(cellDate, btn));
    }
    if (visitSelectedDate && cellDate.toDateString() === visitSelectedDate.toDateString()) {
      btn.classList.add('custom-date-cell-selected');
    }
    grid.appendChild(btn);
  }
}

async function selectVisitDate(date, btnEl) {
  const dateStr = toLocalDateStr(date);

  // Check live availability before committing to this date — a date can
  // look open on the calendar (we haven't checked it yet) but turn out
  // fully booked once queried.
  const availability = await loadDateAvailability(dateStr);
  if (availability === null) {
    return; // availability error already shown via showVisitAvailabilityError
  }
  if (availability.fully_unavailable) {
    renderVisitCalendar();
    alert('This date is no longer available. Please select another date.');
    return;
  }

  visitSelectedDate = date;
  document.getElementById('visitDate').value = dateStr;
  document.querySelectorAll('#visitDateGrid .custom-date-cell').forEach(c => c.classList.remove('custom-date-cell-selected'));
  if (btnEl) btnEl.classList.add('custom-date-cell-selected');

  const dateValueEl = document.getElementById('visitDateValueText');
  dateValueEl.textContent = date.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
  dateValueEl.classList.remove('is-placeholder');

  closeVisitDatePicker();
  renderVisitTimeSlots(availability.available_maintenance_times || []);
}

// Rebuilds the visit-time custom-select's option list to only the times
// the just-selected date actually has open, per get_booking_availability.
// Mirrors populateCustomSelectList's DOM sync (hidden <select> + visible
// dropdown) so native required-field validation keeps working.
function renderVisitTimeSlots(availableTimes) {
  const wrap = document.getElementById('visitTimeCustom');
  const targetSelect = document.getElementById('visitTime');

  // Reset the currently-selected time — it may no longer be valid for
  // the newly selected date.
  document.getElementById('visitTime').value = '';

  if (availableTimes.length === 0) {
    populateCustomSelectList(wrap, []);
    const valueEl = wrap.querySelector('.custom-select-value');
    valueEl.dataset.placeholder = 'No times available';
    valueEl.textContent = 'No times available';
    return;
  }

  const valueEl = wrap.querySelector('.custom-select-value');
  valueEl.dataset.placeholder = 'Select a time';
  populateCustomSelectList(wrap, availableTimes.map(t => ({ value: t, label: t })));
}

function closeVisitModal() {
  document.getElementById('visitModalOverlay').classList.remove('open');
  document.body.style.overflow = '';
  closeVisitDatePicker();
}

document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('visitDateTrigger').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleVisitDatePicker();
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#visitDateField')) closeVisitDatePicker();
  });

  document.getElementById('visitDatePrev').addEventListener('click', (e) => {
    e.stopPropagation();
    visitCalendarViewDate.setMonth(visitCalendarViewDate.getMonth() - 1);
    renderVisitCalendar();
    loadMonthAvailability(visitCalendarViewDate);
  });
  document.getElementById('visitDateNext').addEventListener('click', (e) => {
    e.stopPropagation();
    visitCalendarViewDate.setMonth(visitCalendarViewDate.getMonth() + 1);
    renderVisitCalendar();
    loadMonthAvailability(visitCalendarViewDate);
  });

  // Deep Clean date field (enrollment panel) — same wiring pattern as
  // the visit-modal date field above, targeting the enDeepCleanDate*
  // elements instead.
  const dcTrigger = document.getElementById('enDeepCleanDateTrigger');
  if (dcTrigger) {
    dcTrigger.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleDeepCleanDatePicker();
    });
  }
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#enDeepCleanDateField')) closeDeepCleanDatePicker();
  });

  const dcPrev = document.getElementById('enDeepCleanDatePrev');
  if (dcPrev) {
    dcPrev.addEventListener('click', (e) => {
      e.stopPropagation();
      deepCleanCalendarViewDate.setMonth(deepCleanCalendarViewDate.getMonth() - 1);
      renderDeepCleanCalendar();
      loadDeepCleanMonthAvailability(deepCleanCalendarViewDate);
    });
  }
  const dcNext = document.getElementById('enDeepCleanDateNext');
  if (dcNext) {
    dcNext.addEventListener('click', (e) => {
      e.stopPropagation();
      deepCleanCalendarViewDate.setMonth(deepCleanCalendarViewDate.getMonth() + 1);
      renderDeepCleanCalendar();
      loadDeepCleanMonthAvailability(deepCleanCalendarViewDate);
    });
  }

  init();

  // If the browser restores this page from its back/forward cache (bfcache)
  // — e.g. the user navigates away and hits Back — the page reappears
  // exactly as it was in memory without re-running our scripts, showing
  // stale data (like "no plan enrolled" after they actually enrolled).
  // event.persisted === true tells us this happened, so we re-fetch.
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) {
      init();
    }
  });

  document.getElementById('visitModalClose').addEventListener('click', closeVisitModal);
  document.getElementById('visitModalOverlay').addEventListener('click', (e) => {
    if (e.target === document.getElementById('visitModalOverlay')) closeVisitModal();
  });

  document.getElementById('visitForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const submitBtn = document.getElementById('visitSubmit');
    submitBtn.disabled = true; // guards against duplicate bookings from a double-click
    submitBtn.textContent = 'Booking…';

    const subscriptionId = document.getElementById('visitSubscriptionId').value;
    const date = document.getElementById('visitDate').value;
    const time = document.getElementById('visitTime').value;

    function resetDateSelection() {
      visitSelectedDate = null;
      document.getElementById('visitDate').value = '';
      const dateValueEl = document.getElementById('visitDateValueText');
      dateValueEl.textContent = 'Select a date';
      dateValueEl.classList.add('is-placeholder');
    }

    // The atomic booking RPC is the real source of truth for availability
    // and concurrency — it re-validates the subscription, business hours,
    // full-day service blocking, and 4-hour overlap inside one database
    // transaction with row locking, so a race between two customers can
    // never both succeed. Everything client-side (the calendar, the time
    // dropdown) is only a UX convenience on top of that.
    const { error } = await supabaseClient.rpc('book_maintenance_visit', {
      p_subscription_id: subscriptionId,
      p_requested_date: date,
      p_requested_time: time,
    });

    submitBtn.disabled = false;
    submitBtn.textContent = 'Book maintenance visit';

    if (error) {
      const message = error.message || '';
      delete dateAvailabilityCache[date];

      if (message.includes('SLOT_CONFLICT')) {
        await loadDateAvailability(date);
        renderVisitCalendar();
        resetDateSelection();
        alert('This maintenance time is no longer available. Please choose another time.');
        return;
      }
      if (message.includes('DATE_FULLY_BOOKED')) {
        fullyUnavailableDates.add(date);
        await loadDateAvailability(date);
        renderVisitCalendar();
        resetDateSelection();
        alert('This date is already fully booked. Please choose another date.');
        return;
      }
      if (message.includes('OUTSIDE_BUSINESS_HOURS')) {
        alert("That time doesn't fit within business hours. Please choose another time.");
        return;
      }
      if (message.includes('SUBSCRIPTION_NOT_ACTIVE') || message.includes('NO_WASHES_REMAINING')) {
        alert('Your membership is not available for booking right now.');
        return;
      }
      if (message.includes('DATE_IN_PAST')) {
        alert('Please select a valid upcoming date.');
        resetDateSelection();
        renderVisitCalendar();
        return;
      }
      console.error('Booking failed:', error);
      alert("We couldn't complete the booking. Please try again.");
      return;
    }

    closeVisitModal();
    await loadSubscriptions();
    alert('Maintenance visit booked successfully.');
  });
});
