// =========================================================
// Booking form: 4-step flow, inline in #book section -> WhatsApp
// =========================================================

/**
 * Local YYYY-MM-DD string for a Date object — NOT toISOString(), which
 * converts to UTC and can shift the date backward for timezones ahead
 * of UTC (e.g. India, UTC+5:30), causing off-by-one date bugs near midnight.
 */
function toLocalDateStr(d) {
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

let currentStep = 1;
const TOTAL_STEPS = 4;
let selectedDate = null;
let selectedTime = null;
let calendarViewDate = new Date();

// Two different STATIC fallback lists, shown before any date is picked
// (or if a live availability check fails). Once a date is selected,
// renderGuestTimeSlots() replaces whichever one applies with the live
// list from get_booking_availability so an already-taken time isn't
// offered — see selectDate()/isDeepCleanService().
//
// Deep Clean: 7:00 AM - 3:00 PM (it's a whole-day service; the start
// time just needs to fit before close-of-day service hours).
const DEEP_CLEAN_TIME_SLOTS = ['7:00 AM','8:00 AM','9:00 AM','10:00 AM','11:00 AM','12:00 PM','1:00 PM','2:00 PM','3:00 PM'];
// Maintenance Wash (either variant): 7:00 AM - 7:00 PM, same 4-hour-
// interval window as a membership maintenance visit — a wash only
// takes 4 hours, so it can share the day with other bookings.
const MAINTENANCE_WASH_TIME_SLOTS = ['7:00 AM','8:00 AM','9:00 AM','10:00 AM','11:00 AM','12:00 PM','1:00 PM','2:00 PM','3:00 PM','4:00 PM','5:00 PM','6:00 PM','7:00 PM'];
// Kept only for backward compatibility with any other code path that
// still references the old single-list name. No longer used to render
// the initial time-slot grid — see renderInitialGuestTimeSlots(), which
// picks between DEEP_CLEAN_TIME_SLOTS and MAINTENANCE_WASH_TIME_SLOTS
// based on the currently selected service.
const TIME_SLOTS = DEEP_CLEAN_TIME_SLOTS;

// Dates (YYYY-MM-DD, local) known to be fully unavailable, from the
// get_booking_availability RPC — either a confirmed one-time service or
// a fully-booked maintenance day. Checked lazily per date as the
// customer browses the calendar (see checkGuestDateAvailability()); the
// atomic book_one_time_service() RPC is the real source of truth at
// submit time.
let guestFullyUnavailableDates = new Set();
let guestDeepCleanUnavailableDates = new Set();
let guestAvailabilityCache = {};

async function checkGuestDateAvailability(dateStr) {
  if (guestAvailabilityCache[dateStr]) return guestAvailabilityCache[dateStr];

  try {
    const { data, error } = await supabaseClient.rpc('get_booking_availability', { p_date: dateStr });
    if (error) throw error;
    guestAvailabilityCache[dateStr] = data;
    if (data.fully_unavailable) guestFullyUnavailableDates.add(dateStr);
    if (data.deep_clean_unavailable) guestDeepCleanUnavailableDates.add(dateStr);
    return data;
  } catch (err) {
    console.warn('Could not check date availability:', err);
    return null;
  }
}

// Pre-fetches availability for every future day in the currently
// visible month, in parallel, so fully-booked dates show as disabled
// on the calendar BEFORE the customer clicks anything — not only
// after a click. Re-uses checkGuestDateAvailability()'s per-date
// cache, so a date checked here isn't re-fetched when clicked later.
async function loadGuestMonthAvailability(viewDate) {
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

  await Promise.all(dateStrs.map(checkGuestDateAvailability));
  renderCalendar();
}

function goToStep(step) {
  currentStep = step;

  document.querySelectorAll('.modal-step').forEach(el => {
    el.classList.toggle('active', Number(el.dataset.step) === step);
  });
  document.querySelectorAll('.book-progress .progress-step').forEach(el => {
    const s = Number(el.dataset.step);
    el.classList.toggle('active', s === step);
    el.classList.toggle('completed', s < step);
  });

  document.getElementById('modalBack').style.display = step === 1 ? 'none' : 'inline-flex';
  document.getElementById('modalNext').style.display = step === TOTAL_STEPS ? 'none' : 'inline-flex';
  document.getElementById('modalConfirm').style.display = step === TOTAL_STEPS ? 'inline-flex' : 'none';

  if (step === 3) {
    renderCalendar();
    loadGuestMonthAvailability(calendarViewDate);
    // If a date was already picked (e.g. the customer went back and
    // changed the service between Deep Clean and Maintenance Wash),
    // re-check that date's availability under the NEW service's
    // window/rules rather than leaving the previous service's time
    // list showing. Otherwise (no date picked yet), render the correct
    // STATIC fallback list for the currently selected service — the
    // service is already known from Step 2 by the time Step 3 opens.
    if (selectedDate) {
      const dateStr = toLocalDateStr(selectedDate);
      delete guestAvailabilityCache[dateStr];
      selectDate(selectedDate, null);
    } else {
      renderInitialGuestTimeSlots();
    }
  }
  if (step === 4) renderReview();

  document.getElementById('bookTitle').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function validateStep(step) {
  const stepEl = document.querySelector(`.modal-step[data-step="${step}"]`);
  const requiredFields = stepEl.querySelectorAll('[required]');
  let valid = true;
  let firstInvalid = null;
  requiredFields.forEach(field => {
    const isCustomSelect = field.classList.contains('visually-hidden-select');
    const errorTarget = isCustomSelect ? document.getElementById(field.id + 'Custom') : field;
    if (!field.value || !field.value.trim()) {
      errorTarget.classList.add('field-error');
      valid = false;
      if (!firstInvalid) firstInvalid = isCustomSelect ? errorTarget.querySelector('.custom-select-trigger') : field;
    } else {
      errorTarget.classList.remove('field-error');
    }
  });

  if (step === 3) {
    if (!selectedDate) { document.getElementById('datePicker').classList.add('field-error'); valid = false; }
    else document.getElementById('datePicker').classList.remove('field-error');
    if (!selectedTime) { document.getElementById('timeSlotGrid').classList.add('field-error'); valid = false; }
    else document.getElementById('timeSlotGrid').classList.remove('field-error');
  }

  if (firstInvalid) firstInvalid.focus({ preventScroll: true });

  return valid;
}

// ---------------- Calendar ----------------
function renderCalendar() {
  const grid = document.getElementById('dateGrid');
  const label = document.getElementById('dateMonthLabel');
  const year = calendarViewDate.getFullYear();
  const month = calendarViewDate.getMonth();

  label.textContent = calendarViewDate.toLocaleString('en-IN', { month: 'long', year: 'numeric' });

  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  // Earliest bookable day is TOMORROW — same-day bookings can land on a
  // slot that's already passed (e.g. booking "today 8 AM" at 6 PM), so
  // today itself is disabled alongside all past dates.
  const earliestSelectable = new Date(); earliestSelectable.setHours(0,0,0,0);
  earliestSelectable.setDate(earliestSelectable.getDate() + 1);

  grid.innerHTML = '';
  for (let i = 0; i < firstDay; i++) {
    grid.appendChild(document.createElement('span'));
  }
  for (let d = 1; d <= daysInMonth; d++) {
    const cellDate = new Date(year, month, d);
    const dateStr = toLocalDateStr(cellDate);
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = d;
    btn.className = 'date-cell';
    const isDeepClean = isDeepCleanService();
    const knownUnavailable = isDeepClean
      ? guestDeepCleanUnavailableDates.has(dateStr)
      : guestFullyUnavailableDates.has(dateStr);
    if (cellDate < earliestSelectable) {
      btn.disabled = true;
      btn.classList.add('date-cell-disabled');
    } else if (knownUnavailable) {
      btn.disabled = true;
      btn.classList.add('date-cell-disabled');
      btn.title = isDeepClean
        ? 'Unavailable for Deep Clean'
        : 'Fully booked';
    } else {
      btn.addEventListener('click', () => selectDate(cellDate, btn));
    }
    if (selectedDate && cellDate.toDateString() === selectedDate.toDateString()) {
      btn.classList.add('date-cell-selected');
    }
    grid.appendChild(btn);
  }
}

async function selectDate(date, btnEl) {
  const dateStr = toLocalDateStr(date);

  // Check live availability before committing — a date can look open
  // (unchecked so far) but turn out fully booked once queried.
  const availability = await checkGuestDateAvailability(dateStr);
  const dateUnavailableForService = availability && (
    isDeepCleanService()
      ? availability.deep_clean_unavailable
      : availability.fully_unavailable
  );
  if (dateUnavailableForService) {
    renderCalendar();
    alert(isDeepCleanService()
      ? 'This date is unavailable for Deep Clean. Please select another date.'
      : 'This date is no longer available. Please select another date.');
    return;
  }

  selectedDate = date;
  document.getElementById('mDate').value = dateStr;
  document.querySelectorAll('.date-cell').forEach(c => c.classList.remove('date-cell-selected'));
  if (btnEl) btnEl.classList.add('date-cell-selected');
  document.getElementById('datePicker').classList.remove('field-error');

  // Deep Clean uses the 7 AM-3 PM guest-service window
  // (available_service_times); Maintenance Wash uses the same 7 AM-7 PM
  // 4-hour-slot window as a membership visit (available_maintenance_times)
  // — see isDeepCleanService() below.
  const fallback = isDeepCleanService() ? DEEP_CLEAN_TIME_SLOTS : MAINTENANCE_WASH_TIME_SLOTS;
  const times = availability
    ? (isDeepCleanService() ? availability.available_service_times : availability.available_maintenance_times)
    : fallback;
  renderGuestTimeSlots(times || []);
}

// Mirrors the database's public.is_deep_clean_service(): true only for
// the 'Deep Clean' service, false for either Maintenance Wash variant
// (or anything else). Reads the currently selected service from the
// form — by the time the date/time step is reached, the service is
// already chosen in an earlier step.
function isDeepCleanService() {
  const service = document.getElementById('mService').value || '';
  return service.trim().toLowerCase().startsWith('deep clean');
}

// Renders the correct STATIC fallback time list for whichever service is
// currently selected — used before a date is picked (or if no date is
// picked yet when Step 3 first opens), so Maintenance Wash never shows
// the Deep Clean-only 7 AM-3 PM list. See DEEP_CLEAN_TIME_SLOTS /
// MAINTENANCE_WASH_TIME_SLOTS above and isDeepCleanService().
function renderInitialGuestTimeSlots() {
  const initialTimes = isDeepCleanService() ? DEEP_CLEAN_TIME_SLOTS : MAINTENANCE_WASH_TIME_SLOTS;
  renderGuestTimeSlots(initialTimes);
}

// Rebuilds the guest-service time-slot buttons to whichever list is
// passed in — either the service-appropriate static fallback (see
// renderInitialGuestTimeSlots()) or the live per-date list from
// selectDate()/get_booking_availability. book_one_time_service() still
// re-validates the exact time server-side regardless of what's shown here.
function renderGuestTimeSlots(times) {
  const timeGrid = document.getElementById('timeSlotGrid');
  if (!timeGrid) return;

  // The previously selected time may no longer be valid for the newly
  // selected date — clear it so the customer must reconfirm.
  selectedTime = null;
  document.getElementById('mTime').value = '';

  if (!times || times.length === 0) {
    timeGrid.innerHTML = '<p class="plans-loading">No service times available for this date.</p>';
    return;
  }

  timeGrid.innerHTML = times.map(t => `<button type="button" class="time-slot" data-time="${t}">${t}</button>`).join('');
}

// ---------------- Custom dropdowns ----------------

/**
 * Programmatically set a custom-select's value from outside the component
 * (e.g. "Book Now" buttons pre-filling the service dropdown). Keeps the
 * visible trigger label, the hidden native select, and the option list's
 * aria-selected state all in sync — same as picking it manually.
 */
function setCustomSelectValue(hiddenSelectId, value) {
  const wrap = document.querySelector(`.custom-select[data-target="${hiddenSelectId}"]`);
  const targetSelect = document.getElementById(hiddenSelectId);
  if (!wrap || !targetSelect) return;

  const list = wrap.querySelector('.custom-select-list');
  const valueEl = wrap.querySelector('.custom-select-value');
  const li = Array.from(list.querySelectorAll('li')).find(o => o.dataset.value === value);
  if (!li) return;

  list.querySelectorAll('li').forEach(o => o.setAttribute('aria-selected', 'false'));
  li.setAttribute('aria-selected', 'true');
  valueEl.textContent = li.textContent;
  valueEl.classList.remove('is-placeholder');
  targetSelect.value = value;
  targetSelect.dispatchEvent(new Event('change', { bubbles: true }));
  wrap.classList.remove('field-error');
}

function initCustomSelects() {
  const selects = document.querySelectorAll('.custom-select');

  function closeAll(except) {
    selects.forEach(s => {
      if (s !== except) {
        s.classList.remove('open');
        s.querySelector('.custom-select-trigger').setAttribute('aria-expanded', 'false');
      }
    });
  }

  function positionDropdown(trigger, list) {
    list.classList.remove('drop-up');
    const triggerRect = trigger.getBoundingClientRect();
    const listHeight = Math.min(list.scrollHeight, 240) + 10;
    const spaceBelow = window.innerHeight - triggerRect.bottom;
    const spaceAbove = triggerRect.top;
    if (spaceBelow < listHeight && spaceAbove > spaceBelow) {
      list.classList.add('drop-up');
    }
  }

  selects.forEach(wrap => {
    const trigger = wrap.querySelector('.custom-select-trigger');
    const list = wrap.querySelector('.custom-select-list');
    const valueEl = wrap.querySelector('.custom-select-value');
    const targetSelect = document.getElementById(wrap.dataset.target);
    const options = Array.from(list.querySelectorAll('li'));

    trigger.addEventListener('click', () => {
      const isOpen = wrap.classList.contains('open');
      closeAll(wrap);
      wrap.classList.toggle('open', !isOpen);
      trigger.setAttribute('aria-expanded', String(!isOpen));
      if (!isOpen) {
        positionDropdown(trigger, list);
        const selected = list.querySelector('li[aria-selected="true"]') || options[0];
        if (selected) selected.focus();
      }
    });

    function selectOption(li) {
      options.forEach(o => o.setAttribute('aria-selected', 'false'));
      li.setAttribute('aria-selected', 'true');
      valueEl.textContent = li.textContent;
      valueEl.classList.remove('is-placeholder');
      targetSelect.value = li.dataset.value;
      targetSelect.dispatchEvent(new Event('change', { bubbles: true }));
      wrap.classList.remove('open');
      trigger.setAttribute('aria-expanded', 'false');
      wrap.classList.remove('field-error');
      trigger.focus();
    }

    options.forEach((li, idx) => {
      li.setAttribute('tabindex', '-1');
      li.addEventListener('click', () => selectOption(li));
      li.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectOption(li); }
        else if (e.key === 'ArrowDown') { e.preventDefault(); (options[idx + 1] || options[0]).focus(); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); (options[idx - 1] || options[options.length - 1]).focus(); }
        else if (e.key === 'Escape') { wrap.classList.remove('open'); trigger.setAttribute('aria-expanded', 'false'); trigger.focus(); }
      });
    });

    trigger.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' || e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        if (!wrap.classList.contains('open')) trigger.click();
      }
    });
  });

  document.addEventListener('click', (e) => {
    if (!e.target.closest('.custom-select')) closeAll(null);
  });
}

document.addEventListener('DOMContentLoaded', () => {
  initCustomSelects();

  const prevBtn = document.getElementById('datePrev');
  const nextBtn = document.getElementById('dateNext');
  if (prevBtn) prevBtn.addEventListener('click', () => {
    calendarViewDate.setMonth(calendarViewDate.getMonth() - 1);
    renderCalendar();
    loadGuestMonthAvailability(calendarViewDate);
  });
  if (nextBtn) nextBtn.addEventListener('click', () => {
    calendarViewDate.setMonth(calendarViewDate.getMonth() + 1);
    renderCalendar();
    loadGuestMonthAvailability(calendarViewDate);
  });

  // Time slots — initial render must be service-aware (Deep Clean:
  // 7 AM-3 PM, either Maintenance Wash: 7 AM-7 PM), not the old single
  // TIME_SLOTS list, so Maintenance Wash never shows Deep Clean's window
  // before a date is picked. See renderInitialGuestTimeSlots().
  const timeGrid = document.getElementById('timeSlotGrid');
  if (timeGrid) {
    renderInitialGuestTimeSlots();
    // Event delegation: works regardless of which service's list is
    // currently rendered inside timeGrid, so this listener never needs
    // to be re-attached when the list is rebuilt.
    timeGrid.addEventListener('click', (e) => {
      const btn = e.target.closest('.time-slot');
      if (!btn) return;
      selectedTime = btn.dataset.time;
      document.getElementById('mTime').value = selectedTime;
      timeGrid.querySelectorAll('.time-slot').forEach(b => b.classList.remove('time-slot-selected'));
      btn.classList.add('time-slot-selected');
      timeGrid.classList.remove('field-error');
    });
  }

  // Rebuild the visible time buttons immediately when the service changes
  // in Step 2 — don't wait until the customer reaches Step 3 or picks a
  // date. Only affects the STATIC fallback list; if a date is already
  // selected, the existing goToStep(3) re-check (above) re-fetches live
  // availability for the new service instead, so this only fires the
  // fallback-list rebuild while no date has been picked yet.
  const mServiceSelect = document.getElementById('mService');
  if (mServiceSelect) {
    mServiceSelect.addEventListener('change', () => {
      // Availability is service-specific: Deep Clean treats any occupied
      // date as unavailable, while Maintenance only disables a date when
      // no maintenance slot remains. Re-render immediately when the
      // service changes so the calendar never shows stale availability.
      renderCalendar();
      if (!selectedDate) {
        renderInitialGuestTimeSlots();
      }
    });
  }

  // Add-on checkbox visual state (fallback for browsers without :has() support)
  document.querySelectorAll('.addon-check input[type="checkbox"]').forEach(cb => {
    const syncState = () => cb.closest('.addon-check').classList.toggle('addon-check-selected', cb.checked);
    cb.addEventListener('change', syncState);
    syncState();
  });

  // Update Decon add-on price based on chosen vehicle type
  const vehicleTypeSelect = document.getElementById('mVehicleType');
  const deconPriceEl = document.getElementById('deconPrice');
  function updateDeconPrice() {
    if (!vehicleTypeSelect || !deconPriceEl) return;
    const isSuv = vehicleTypeSelect.value === 'SUV / MPV / Large SUV';
    deconPriceEl.textContent = isSuv ? '+₹2,999' : '+₹1,999';
  }
  if (vehicleTypeSelect) {
    vehicleTypeSelect.addEventListener('change', updateDeconPrice);
  }

  // Service card "Book Now" -> scroll to form + prefill service, jump to step 1
  document.querySelectorAll('.service-book-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      setCustomSelectValue('mService', btn.dataset.service);
      goToStep(1);
      document.getElementById('bookTitle').scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  });

  // Step navigation
  document.getElementById('modalNext').addEventListener('click', () => {
    if (!validateStep(currentStep)) return;
    if (currentStep < TOTAL_STEPS) goToStep(currentStep + 1);
  });
  document.getElementById('modalBack').addEventListener('click', () => {
    if (currentStep > 1) goToStep(currentStep - 1);
  });

  // Progress step click (only allow going back to completed steps)
  document.querySelectorAll('.book-progress .progress-step').forEach(el => {
    el.addEventListener('click', () => {
      const target = Number(el.dataset.step);
      if (target < currentStep) goToStep(target);
    });
  });

  document.getElementById('modalConfirm').addEventListener('click', sendBookingToWhatsapp);

  // Initialize on load
  goToStepSilent(1);
});

// Same as goToStep but without scrolling (used on page load)
function goToStepSilent(step) {
  currentStep = step;
  document.querySelectorAll('.modal-step').forEach(el => {
    el.classList.toggle('active', Number(el.dataset.step) === step);
  });
  document.querySelectorAll('.book-progress .progress-step').forEach(el => {
    const s = Number(el.dataset.step);
    el.classList.toggle('active', s === step);
    el.classList.toggle('completed', s < step);
  });
  document.getElementById('modalBack').style.display = 'none';
  document.getElementById('modalNext').style.display = 'inline-flex';
  document.getElementById('modalConfirm').style.display = 'none';
}

// ---------------- Pricing (mirrors the Services section prices) ----------------
const SERVICE_PRICES = {
  'Deep Clean': { sedan: 2499, suv: 3499 },
  'Maintenance Wash (Exterior Only)': { sedan: 999, suv: 1299 },
  'Maintenance Wash (Exterior + Interior)': { sedan: 1199, suv: 1699 },
};

function calculateBookingTotal(service, vehicleType, addonEls) {
  const isSuv = vehicleType === 'SUV / MPV / Large SUV';
  const segmentKey = isSuv ? 'suv' : 'sedan';

  let total = 0;
  const basePrice = SERVICE_PRICES[service];
  if (basePrice) total += basePrice[segmentKey];

  addonEls.forEach(el => {
    let price = el.dataset.price;
    if (el.dataset.priceSedan) {
      price = isSuv ? el.dataset.priceSuv : el.dataset.priceSedan;
    }
    if (price) total += Number(price);
  });

  return total;
}

// ---------------- Review ----------------
function getFormData() {
  const addonEls = Array.from(document.querySelectorAll('input[name="addon"]:checked'));
  const isSuv = document.getElementById('mVehicleType').value === 'SUV / MPV / Large SUV';
  const addons = addonEls.map(el => {
    let price = el.dataset.price;
    if (el.dataset.priceSedan) {
      price = isSuv ? el.dataset.priceSuv : el.dataset.priceSedan;
    }
    return price ? `${el.value} (+₹${Number(price).toLocaleString('en-IN')})` : el.value;
  });
  const service = document.getElementById('mService').value;
  const vehicleType = document.getElementById('mVehicleType').value;
  const calculatedTotal = calculateBookingTotal(service, vehicleType, addonEls);

  return {
    name: document.getElementById('mFullName').value.trim(),
    phone: document.getElementById('mPhone').value.trim(),
    address: document.getElementById('mAddress').value.trim(),
    area: document.getElementById('mArea').value.trim(),
    landmark: document.getElementById('mLandmark').value.trim(),
    vehicleType: vehicleType,
    vehicleModel: document.getElementById('mVehicleModel').value.trim(),
    seatMaterial: document.getElementById('mSeatMaterial').value,
    service: service,
    addons: addons,
    calculatedTotal: calculatedTotal,
    date: selectedDate ? selectedDate.toLocaleDateString('en-IN', { day: 'numeric', month: 'long', year: 'numeric' }) : '',
    time: selectedTime || '',
    notes: document.getElementById('mNotes').value.trim()
  };
}

function renewStepFromField(fieldId) {
  const stepMap = {
    mFullName: 1, mPhone: 1, mAddress: 1, mArea: 1, mLandmark: 1,
    mVehicleType: 2, mVehicleModel: 2, mSeatMaterial: 2, mService: 2
  };
  return stepMap[fieldId] || 3;
}

function renderReview() {
  const data = getFormData();
  const list = document.getElementById('reviewList');

  const rows = [
    ['Name', data.name, 'mFullName'],
    ['Mobile', data.phone, 'mPhone'],
    ['Address', data.address, 'mAddress'],
    ['Area', data.area, 'mArea'],
    ['Landmark', data.landmark || '—', 'mLandmark'],
    ['Vehicle', `${data.vehicleType} · ${data.vehicleModel}`, 'mVehicleType'],
    ['Seat Material', data.seatMaterial, 'mSeatMaterial'],
    ['Service', data.service, 'mService'],
    ['Add-ons', data.addons.length ? data.addons.join(', ') : 'None selected', null],
    ['Estimated Total', `₹${data.calculatedTotal.toLocaleString('en-IN')}`, null],
    ['Date & Time', `${data.date} at ${data.time}`, null],
    ['Notes', data.notes || '—', null],
  ];

  list.innerHTML = rows.map(([label, value, editField]) => `
    <div class="review-row">
      <span class="review-label">${label}</span>
      <span class="review-value">${value}</span>
      ${editField ? `<button type="button" class="review-edit" data-goto="${renewStepFromField(editField)}">Edit</button>` : ''}
    </div>
  `).join('');

  list.querySelectorAll('.review-edit').forEach(btn => {
    btn.addEventListener('click', () => goToStep(Number(btn.dataset.goto)));
  });
}

async function sendBookingToWhatsapp() {
  if (!validateStep(1)) { goToStep(1); return; }
  if (!validateStep(2)) { goToStep(2); return; }
  if (!validateStep(3)) { goToStep(3); return; }
  const data = getFormData();

  const confirmBtn = document.getElementById('modalConfirm');
  confirmBtn.disabled = true; // guards against duplicate bookings from a double-click

  // The atomic book_one_time_service() RPC is the real source of truth
  // for availability and concurrency — it re-checks (under row locks,
  // inside one transaction) that no confirmed service and no maintenance
  // booking already occupy this date before inserting. A race between
  // two guests picking the same date can never both succeed.
  const { data: booking, error } = await supabaseClient.rpc('book_one_time_service', {
    p_customer_name: data.name,
    p_customer_phone: data.phone,
    p_service: data.service,
    p_vehicle_type: data.vehicleType,
    p_vehicle_model: data.vehicleModel,
    p_seat_material: data.seatMaterial,
    p_addons: data.addons,
    p_service_address: `${data.address}, ${data.area}${data.landmark ? ' (near ' + data.landmark + ')' : ''}`,
    p_requested_date: selectedDate ? toLocalDateStr(selectedDate) : null,
    p_requested_time: data.time,
    p_notes: data.notes || null,
    p_calculated_price: data.calculatedTotal,
  });

  confirmBtn.disabled = false;

  if (error) {
    const message = error.message || '';
    const dateStr = selectedDate ? toLocalDateStr(selectedDate) : null;

    if (message.includes('DATE_FULLY_BOOKED')) {
      if (dateStr) {
        delete guestAvailabilityCache[dateStr];
        guestFullyUnavailableDates.add(dateStr);
      }
      renderCalendar();
      alert('This date is already fully booked. Please choose another date.');
      goToStep(3);
      return;
    }
    if (message.includes('OUTSIDE_SERVICE_HOURS') || message.includes('MISSING_TIME')) {
      // Service-specific: Deep Clean's window is 7 AM-3 PM, Maintenance
      // Wash's is 7 AM-7 PM — the old message hardcoded the Deep Clean
      // window even when a Maintenance Wash booking was the one rejected.
      alert(isDeepCleanService()
        ? 'Please choose a valid Deep Clean time between 7:00 AM and 3:00 PM.'
        : 'Please choose a valid Maintenance Wash time between 7:00 AM and 7:00 PM.');
      goToStep(3);
      return;
    }
    if (message.includes('DATE_IN_PAST')) {
      alert('Please select a valid upcoming date.');
      goToStep(3);
      return;
    }
    console.error('Booking failed:', error);
    alert("We couldn't complete the booking. Please try again.");
    return;
  }

  const message =
`New Booking — Just Detail

Name: ${data.name}
Phone: ${data.phone}
Address: ${data.address}, ${data.area}${data.landmark ? ' (near ' + data.landmark + ')' : ''}

Vehicle: ${data.vehicleType} — ${data.vehicleModel}
Seat Material: ${data.seatMaterial}
Service: ${data.service}
Add-ons: ${data.addons.length ? data.addons.join(', ') : 'None'}
Estimated Total: ₹${data.calculatedTotal.toLocaleString('en-IN')}

Confirmed Date: ${data.date}
Confirmed Time: ${data.time}
Notes: ${data.notes || '—'}`;

  // Booking is already confirmed in the database at this point — WhatsApp
  // is just the existing handoff to notify the business, unchanged from
  // before other than now happening after a confirmed reservation.
  const encoded = encodeURIComponent(message);
  const waUrl = `https://wa.me/${OWNER_WHATSAPP_NUMBER}?text=${encoded}`;
  window.open(waUrl, '_blank');

  resetBookingForm();
}

function resetBookingForm() {
  // Capture the just-booked date BEFORE the form fields are cleared below.
  const justBookedDateStr = selectedDate ? toLocalDateStr(selectedDate) : null;

  document.getElementById('modalBookingForm').reset();
  document.querySelectorAll('input[name="addon"]').forEach(cb => cb.checked = false);
  document.querySelectorAll('.addon-check').forEach(el => el.classList.remove('addon-check-selected'));

  selectedDate = null;
  selectedTime = null;
  document.getElementById('mDate').value = '';
  document.getElementById('mTime').value = '';
  document.querySelectorAll('.time-slot').forEach(b => b.classList.remove('time-slot-selected'));

  // Reset custom dropdowns back to their placeholder state
  document.querySelectorAll('.custom-select').forEach(wrap => {
    const valueEl = wrap.querySelector('.custom-select-value');
    valueEl.textContent = valueEl.dataset.placeholder;
    valueEl.classList.add('is-placeholder');
    wrap.querySelectorAll('li').forEach(li => li.setAttribute('aria-selected', 'false'));
  });

  // The just-booked date is now fully unavailable for everyone (a
  // confirmed one-time service always blocks the whole day). Drop the
  // stale cache entry AND mark it disabled immediately, then re-render
  // the calendar so a second booking attempt in the same session (no
  // page reload) can't select it — this is what item #1/#2 requires:
  // the date must appear disabled right away, not just be rejected by
  // the database on a later attempt.
  if (justBookedDateStr) {
    delete guestAvailabilityCache[justBookedDateStr];
    guestFullyUnavailableDates.add(justBookedDateStr);
    guestDeepCleanUnavailableDates.add(justBookedDateStr);
  }
  renderCalendar();

  goToStepSilent(1);
  showBookingConfirmation();
}

function showBookingConfirmation() {
  const banner = document.createElement('div');
  banner.className = 'booking-sent-banner';
  banner.textContent = '✓ Your service booking is confirmed.';
  const bookCard = document.querySelector('.book-card');
  bookCard.parentNode.insertBefore(banner, bookCard);
  setTimeout(() => banner.remove(), 5000);
}
