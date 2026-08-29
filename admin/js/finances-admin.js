// =========================================================
// Admin Finances
// Actual Revenue = sum of recorded payments in range.
// A booking/subscription is NEVER counted as revenue on its own —
// only explicit `payments` rows count.
// =========================================================

let currentRange = 'today';
let customFrom = null;
let customTo = null;

let payDateField = null;

let confirmPayDateField = null;

async function init() {
  const adminUser = await requireAdmin();
  if (!adminUser) return;

  initAdminShell('finances.html', adminUser);

  initAllCustomSelects();
  payDateField = initDateField('payDate');
  confirmPayDateField = initDateField('confirmPayDate');
  wireRangeFilters();
  wirePaymentModal();
  wireExpenseModal();
  wireConfirmPaymentModal();

  await refreshAll();

  document.getElementById('pageLoading').style.display = 'none';
  document.getElementById('pageContent').style.display = 'block';

  // Arriving from a "Confirm Payment →" link (dashboard's pending-
  // payments panels, or this page's own Payments Awaiting Confirmation
  // table) opens the CONFIRM modal for that existing pending payment —
  // not the general Record Payment modal, since there's nothing new to
  // record here, only an existing pending row to confirm.
  const params = new URLSearchParams(window.location.search);
  const onetimeId = params.get('pay_onetime');
  const subscriptionId = params.get('pay_subscription');
  if (onetimeId) {
    await openConfirmPaymentModal({ type: 'one_time', id: onetimeId });
    window.history.replaceState({}, '', 'finances.html');
  } else if (subscriptionId) {
    await openConfirmPaymentModal({ type: 'subscription', id: subscriptionId });
    window.history.replaceState({}, '', 'finances.html');
  }
}

async function refreshAll() {
  await Promise.all([
    loadTodayMonthSummary(),
    loadRangeData(),
    loadPendingPayments(),
  ]);
}

// ---------------- Payments Awaiting Confirmation ----------------
async function loadPendingPayments() {
  const { data, error } = await supabaseClient
    .from('payments')
    .select(`
      id, amount, created_at,
      one_time_booking_id, subscription_id,
      one_time_bookings(id, customer_name, service),
      subscriptions(id, vehicle_model, clients(full_name), plans(tier_name))
    `)
    .eq('payment_status', 'pending')
    .order('created_at', { ascending: false });

  const tbody = document.getElementById('pendingPaymentsBody');
  const emptyEl = document.getElementById('pendingPaymentsEmpty');
  const tableEl = document.getElementById('pendingPaymentsTable');

  if (error || !data || data.length === 0) {
    tableEl.style.display = 'none';
    emptyEl.style.display = 'block';
    return;
  }

  tableEl.style.display = 'table';
  emptyEl.style.display = 'none';

  tbody.innerHTML = data.map(p => {
    const isOneTime = !!p.one_time_booking_id;
    const customer = isOneTime
      ? (p.one_time_bookings?.customer_name || '—')
      : (p.subscriptions?.clients?.full_name || '—');
    const source = isOneTime
      ? `One-time — ${p.one_time_bookings?.service || ''}`
      : `Membership — ${p.subscriptions?.plans?.tier_name || ''} (${p.subscriptions?.vehicle_model || ''})`;
    const confirmType = isOneTime ? 'one_time' : 'subscription';
    const confirmId = isOneTime ? p.one_time_booking_id : p.subscription_id;

    return `
      <tr>
        <td>${customer}</td>
        <td>${source}</td>
        <td>₹${Number(p.amount).toLocaleString('en-IN')}</td>
        <td>${formatDate(p.created_at)}</td>
        <td><button class="btn btn-success btn-sm" data-confirm-payment="${confirmType}:${confirmId}">Confirm Payment</button></td>
      </tr>
    `;
  }).join('');

  tbody.querySelectorAll('[data-confirm-payment]').forEach(btn => {
    btn.addEventListener('click', () => {
      const [type, id] = btn.dataset.confirmPayment.split(':');
      openConfirmPaymentModal({ type, id });
    });
  });
}

// ---------------- Confirm Payment modal ----------------
let confirmPaymentTarget = null; // { type: 'one_time' | 'subscription', id }

function wireConfirmPaymentModal() {
  const overlay = document.getElementById('confirmPaymentModalOverlay');
  document.getElementById('confirmPaymentModalClose').addEventListener('click', () => closeModal(overlay));
  overlay.addEventListener('click', (e) => { if (e.target === overlay) closeModal(overlay); });
  document.getElementById('confirmPaymentForm').addEventListener('submit', submitConfirmPayment);
}

async function openConfirmPaymentModal(target) {
  confirmPaymentTarget = target;
  const overlay = document.getElementById('confirmPaymentModalOverlay');
  document.getElementById('confirmPaymentForm').reset();
  if (confirmPayDateField) confirmPayDateField.setDate(new Date());

  // Reset the method dropdown's visible state (form.reset() only clears
  // the hidden native select, not the custom UI on top of it)
  const methodWrap = document.getElementById('confirmPayMethodCustom');
  const methodValueEl = methodWrap.querySelector('.custom-select-value');
  methodValueEl.textContent = methodValueEl.dataset.placeholder;
  methodValueEl.classList.add('is-placeholder');
  methodWrap.querySelectorAll('li').forEach(li => li.setAttribute('aria-selected', 'false'));

  const summaryEl = document.getElementById('confirmPaymentSummary');
  summaryEl.textContent = 'Loading…';

  if (target.type === 'one_time') {
    const { data } = await supabaseClient
      .from('payments')
      .select('amount, one_time_bookings(customer_name, service)')
      .eq('one_time_booking_id', target.id)
      .eq('payment_status', 'pending')
      .maybeSingle();
    summaryEl.textContent = data
      ? `${data.one_time_bookings?.customer_name || 'Customer'} — ${data.one_time_bookings?.service || ''} — ₹${Number(data.amount).toLocaleString('en-IN')}`
      : 'This payment may have already been confirmed.';
  } else {
    const { data } = await supabaseClient
      .from('payments')
      .select('amount, subscriptions(vehicle_model, clients(full_name), plans(tier_name))')
      .eq('subscription_id', target.id)
      .eq('payment_status', 'pending')
      .maybeSingle();
    summaryEl.textContent = data
      ? `${data.subscriptions?.clients?.full_name || 'Customer'} — ${data.subscriptions?.plans?.tier_name || ''} — ₹${Number(data.amount).toLocaleString('en-IN')}`
      : 'This payment may have already been confirmed.';
  }

  overlay.classList.add('open');
  document.body.style.overflow = 'hidden';
}

async function submitConfirmPayment(e) {
  e.preventDefault();
  if (!confirmPaymentTarget) return;

  const btn = document.getElementById('confirmPaySubmit');
  btn.disabled = true;
  btn.textContent = 'Confirming…';

  const method = document.getElementById('confirmPayMethod').value;
  const date = document.getElementById('confirmPayDate').value;

  // admin_confirm_onetime_payment() / admin_confirm_subscription_payment()
  // are idempotent: calling either on an already-paid target raises a
  // distinct ALREADY_PAID error instead of creating a duplicate payments
  // row or double-counting revenue — see supabase/migrations/
  // membership_schedule_and_pending_payments.sql.
  const rpcName = confirmPaymentTarget.type === 'one_time'
    ? 'admin_confirm_onetime_payment'
    : 'admin_confirm_subscription_payment';
  const rpcParams = confirmPaymentTarget.type === 'one_time'
    ? { p_one_time_booking_id: confirmPaymentTarget.id, p_payment_method: method, p_payment_date: date }
    : { p_subscription_id: confirmPaymentTarget.id, p_payment_method: method, p_payment_date: date };

  const { error } = await supabaseClient.rpc(rpcName, rpcParams);

  btn.disabled = false;
  btn.textContent = 'Confirm Payment';

  if (error) {
    const message = error.message || '';
    if (message.includes('ALREADY_PAID')) {
      showToast('This payment has already been confirmed.', 'error');
      closeModal(document.getElementById('confirmPaymentModalOverlay'));
      await refreshAll();
      return;
    }
    if (message.includes('NO_PENDING_PAYMENT')) {
      showToast('No pending payment found for this booking/membership.', 'error');
      closeModal(document.getElementById('confirmPaymentModalOverlay'));
      await refreshAll();
      return;
    }
    showToast('Failed to confirm payment: ' + error.message, 'error');
    return;
  }

  showToast('Payment confirmed. Revenue updated successfully.');
  closeModal(document.getElementById('confirmPaymentModalOverlay'));
  await refreshAll();
}

// ---------------- Date range handling ----------------
function getRangeDates() {
  const now = new Date();
  const startOfDay = (d) => { const x = new Date(d); x.setHours(0,0,0,0); return x; };

  if (currentRange === 'today') {
    const start = startOfDay(now);
    return { from: start, to: start };
  }
  if (currentRange === 'month') {
    const start = new Date(now.getFullYear(), now.getMonth(), 1);
    return { from: start, to: startOfDay(now) };
  }
  if (currentRange === 'year') {
    const start = new Date(now.getFullYear(), 0, 1);
    return { from: start, to: startOfDay(now) };
  }
  if (currentRange === 'custom' && customFrom && customTo) {
    return { from: new Date(customFrom), to: new Date(customTo) };
  }
  const start = startOfDay(now);
  return { from: start, to: start };
}

function toDateStr(d) {
  // Delegates to the shared helper in admin-common.js
  return toLocalDateStr(d);
}

function wireRangeFilters() {
  document.querySelectorAll('#rangeFilters .filter-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('#rangeFilters .filter-chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      currentRange = chip.dataset.range;
      document.getElementById('customRangeRow').style.display = currentRange === 'custom' ? 'block' : 'none';
      if (currentRange !== 'custom') loadRangeData();
    });
  });

  document.getElementById('applyCustomRange').addEventListener('click', () => {
    customFrom = document.getElementById('customFrom').value;
    customTo = document.getElementById('customTo').value;
    if (!customFrom || !customTo) { showToast('Pick both dates.', 'error'); return; }
    loadRangeData();
  });
}

// ---------------- Today / Month summary cards ----------------
// Revenue = sum of PAID payments only. A pending payment (membership
// awaiting admin confirmation, or a one-time booking awaiting payment)
// must never inflate these numbers — this is the fix for "membership
// payment must appear in Revenue only after admin confirmation."
async function loadTodayMonthSummary() {
  const todayStr = toDateStr(new Date());
  const monthStart = toDateStr(new Date(new Date().getFullYear(), new Date().getMonth(), 1));

  const [todayPayments, todayExpenses, monthPayments, monthExpenses] = await Promise.all([
    supabaseClient.from('payments').select('amount').eq('payment_status', 'paid').eq('payment_date', todayStr),
    supabaseClient.from('expenses').select('amount').eq('expense_date', todayStr),
    supabaseClient.from('payments').select('amount').eq('payment_status', 'paid').gte('payment_date', monthStart).lte('payment_date', todayStr),
    supabaseClient.from('expenses').select('amount').gte('expense_date', monthStart).lte('expense_date', todayStr),
  ]);

  const sum = (rows) => (rows || []).reduce((acc, r) => acc + Number(r.amount), 0);

  const tRev = sum(todayPayments.data), tExp = sum(todayExpenses.data);
  const mRev = sum(monthPayments.data), mExp = sum(monthExpenses.data);

  setMoney('todayRevenue', tRev);
  setMoney('todayExpenses', tExp);
  setMoney('todayProfit', tRev - tExp);
  setMoney('monthRevenue', mRev);
  setMoney('monthExpenses', mExp);
  setMoney('monthProfit', mRev - mExp);
}

function setMoney(id, value) {
  document.getElementById(id).textContent = '₹' + Number(value).toLocaleString('en-IN');
}

// ---------------- Range-filtered lists ----------------
// Same payment_status = 'paid' filter as above — the Revenue tables and
// the range total must only ever reflect confirmed payments.
async function loadRangeData() {
  const { from, to } = getRangeDates();
  const fromStr = toDateStr(from);
  const toStr = toDateStr(to);

  const [oneTimePayments, subPayments, expenses] = await Promise.all([
    supabaseClient
      .from('payments')
      .select('*, one_time_bookings(customer_name, service)')
      .not('one_time_booking_id', 'is', null)
      .eq('payment_status', 'paid')
      .gte('payment_date', fromStr).lte('payment_date', toStr)
      .order('payment_date', { ascending: false }),
    supabaseClient
      .from('payments')
      .select('*, subscriptions(vehicle_model, clients(full_name), plans(tier_name))')
      .not('subscription_id', 'is', null)
      .eq('payment_status', 'paid')
      .gte('payment_date', fromStr).lte('payment_date', toStr)
      .order('payment_date', { ascending: false }),
    supabaseClient
      .from('expenses')
      .select('*')
      .gte('expense_date', fromStr).lte('expense_date', toStr)
      .order('expense_date', { ascending: false }),
  ]);

  renderOneTimeRevenue(oneTimePayments.data || []);
  renderMaintenanceRevenue(subPayments.data || []);
  renderExpenses(expenses.data || []);

  const totalRevenue = [...(oneTimePayments.data || []), ...(subPayments.data || [])]
    .reduce((acc, p) => acc + Number(p.amount), 0);
  const totalExpenses = (expenses.data || []).reduce((acc, e) => acc + Number(e.amount), 0);

  document.getElementById('rangeRevenue').textContent = '₹' + totalRevenue.toLocaleString('en-IN') + ' revenue';
  document.getElementById('rangeExpenses').textContent = '₹' + totalExpenses.toLocaleString('en-IN') + ' expenses';
  document.getElementById('rangeProfit').textContent = '₹' + (totalRevenue - totalExpenses).toLocaleString('en-IN') + ' profit';
}

function methodLabel(m) {
  const map = { cash: 'Cash', upi: 'UPI', card: 'Card', bank_transfer: 'Bank Transfer', other: 'Other' };
  return map[m] || m;
}
function paymentStatusBadge(s) {
  return s === 'paid'
    ? '<span class="badge badge-active">Paid</span>'
    : '<span class="badge badge-pending">Partial</span>';
}

function renderOneTimeRevenue(rows) {
  const tbody = document.getElementById('oneTimeRevenueBody');
  const emptyEl = document.getElementById('oneTimeRevenueEmpty');
  const tableEl = document.getElementById('oneTimeRevenueTable');

  if (rows.length === 0) { tableEl.style.display = 'none'; emptyEl.style.display = 'block'; return; }
  tableEl.style.display = 'table'; emptyEl.style.display = 'none';

  tbody.innerHTML = rows.map(p => `
    <tr>
      <td>${p.one_time_bookings?.customer_name || '—'}</td>
      <td>${p.one_time_bookings?.service || '—'}</td>
      <td>₹${Number(p.amount).toLocaleString('en-IN')}</td>
      <td>${methodLabel(p.payment_method)}</td>
      <td>${paymentStatusBadge(p.payment_status)}</td>
      <td>${formatDate(p.payment_date)}</td>
    </tr>
  `).join('');
}

function renderMaintenanceRevenue(rows) {
  const tbody = document.getElementById('maintenanceRevenueBody');
  const emptyEl = document.getElementById('maintenanceRevenueEmpty');
  const tableEl = document.getElementById('maintenanceRevenueTable');

  if (rows.length === 0) { tableEl.style.display = 'none'; emptyEl.style.display = 'block'; return; }
  tableEl.style.display = 'table'; emptyEl.style.display = 'none';

  tbody.innerHTML = rows.map(p => `
    <tr>
      <td>${p.subscriptions?.clients?.full_name || '—'}</td>
      <td>${p.subscriptions?.plans?.tier_name || '—'}</td>
      <td>₹${Number(p.amount).toLocaleString('en-IN')}</td>
      <td>${methodLabel(p.payment_method)}</td>
      <td>${paymentStatusBadge(p.payment_status)}</td>
      <td>${formatDate(p.payment_date)}</td>
    </tr>
  `).join('');
}

function categoryLabel(c) {
  const map = {
    fuel: 'Fuel', cleaning_products: 'Cleaning Products', equipment: 'Equipment',
    equipment_repair: 'Equipment Repair', marketing: 'Marketing', staff: 'Staff', other: 'Other',
  };
  return map[c] || c;
}

function renderExpenses(rows) {
  const tbody = document.getElementById('expensesBody');
  const emptyEl = document.getElementById('expensesEmpty');
  const tableEl = document.getElementById('expensesTable');

  if (rows.length === 0) { tableEl.style.display = 'none'; emptyEl.style.display = 'block'; return; }
  tableEl.style.display = 'table'; emptyEl.style.display = 'none';

  tbody.innerHTML = rows.map(e => `
    <tr>
      <td>${categoryLabel(e.category)}</td>
      <td>₹${Number(e.amount).toLocaleString('en-IN')}</td>
      <td>${formatDate(e.expense_date)}</td>
      <td>${e.description || '—'}</td>
      <td><button class="expense-delete-btn" data-delete-expense="${e.id}">Delete</button></td>
    </tr>
  `).join('');

  tbody.querySelectorAll('[data-delete-expense]').forEach(btn => {
    btn.addEventListener('click', async () => {
      if (!confirm('Delete this expense?')) return;
      await supabaseClient.from('expenses').delete().eq('id', btn.dataset.deleteExpense);
      showToast('Expense deleted.');
      await refreshAll();
    });
  });
}

// ---------------- Record Payment modal ----------------
function wirePaymentModal() {
  const overlay = document.getElementById('paymentModalOverlay');
  document.getElementById('openRecordPayment').addEventListener('click', () => openPaymentModal());
  document.getElementById('paymentModalClose').addEventListener('click', () => closeModal(overlay));
  overlay.addEventListener('click', (e) => { if (e.target === overlay) closeModal(overlay); });

  document.getElementById('paySource').addEventListener('change', (e) => {
    const isOneTime = e.target.value === 'one_time';
    document.getElementById('payOneTimeRow').style.display = isOneTime ? 'block' : 'none';
    document.getElementById('paySubscriptionRow').style.display = isOneTime ? 'none' : 'block';
  });

  document.getElementById('paySubscription').addEventListener('change', (e) => {
    autoFillSubscriptionAmount(e.target.value);
  });

  document.getElementById('paymentForm').addEventListener('submit', submitPayment);
}

async function openPaymentModal(preset) {
  const overlay = document.getElementById('paymentModalOverlay');
  document.getElementById('paymentForm').reset();
  document.getElementById('payOneTimeRow').style.display = 'none';
  document.getElementById('paySubscriptionRow').style.display = 'none';
  if (payDateField) payDateField.setDate(new Date());
  document.getElementById('payAmountHint').textContent = '';

  // Reset paySource's visible dropdown state (form.reset() only clears the
  // hidden native select, not the custom UI on top of it)
  const sourceWrap = document.getElementById('paySourceCustom');
  const sourceValueEl = sourceWrap.querySelector('.custom-select-value');
  sourceValueEl.textContent = sourceValueEl.dataset.placeholder;
  sourceValueEl.classList.add('is-placeholder');
  sourceWrap.querySelectorAll('li').forEach(li => li.setAttribute('aria-selected', 'false'));

  await Promise.all([populateOneTimeOptions(), populateSubscriptionOptions()]);

  if (preset && preset.type === 'one_time') {
    setCustomSelectValue('paySource', 'one_time');
    document.getElementById('payOneTimeRow').style.display = 'block';
    setCustomSelectValue('payOneTimeBooking', preset.id);
  } else if (preset && preset.type === 'subscription') {
    setCustomSelectValue('paySource', 'subscription');
    document.getElementById('paySubscriptionRow').style.display = 'block';
    setCustomSelectValue('paySubscription', preset.id);
    await autoFillSubscriptionAmount(preset.id);
  }

  overlay.classList.add('open');
  document.body.style.overflow = 'hidden';
}

async function populateOneTimeOptions() {
  const { data } = await supabaseClient
    .from('one_time_bookings')
    .select('id, customer_name, service, created_at')
    .order('created_at', { ascending: false })
    .limit(100);

  const wrap = document.getElementById('payOneTimeBookingCustom');
  const items = (data || []).map(b => ({
    value: b.id,
    label: `${b.customer_name} — ${b.service} (${formatDate(b.created_at)})`,
  }));
  populateCustomSelectList(wrap, items.length ? items : [{ value: '', label: 'No bookings found' }]);
}

let subscriptionPriceLookup = {};

async function autoFillSubscriptionAmount(subscriptionId) {
  const planPrice = subscriptionPriceLookup[subscriptionId] || 0;
  if (!planPrice) return;

  // Only PAID payments count toward "already paid" — a pending
  // membership payment (created automatically at enrollment; see
  // book_membership()) must not be treated as money already received.
  const { data: existingPayments } = await supabaseClient
    .from('payments')
    .select('amount')
    .eq('subscription_id', subscriptionId)
    .eq('payment_status', 'paid');

  const alreadyPaid = (existingPayments || []).reduce((acc, p) => acc + Number(p.amount), 0);
  const remaining = Math.max(planPrice - alreadyPaid, 0);

  const amountInput = document.getElementById('payAmount');
  amountInput.value = remaining;

  const hint = document.getElementById('payAmountHint');
  if (hint) {
    hint.textContent = alreadyPaid > 0
      ? `Plan price ₹${planPrice.toLocaleString('en-IN')} — ₹${alreadyPaid.toLocaleString('en-IN')} already paid — ₹${remaining.toLocaleString('en-IN')} remaining`
      : `Plan price: ₹${planPrice.toLocaleString('en-IN')}`;
  }
}

async function populateSubscriptionOptions() {
  const { data } = await supabaseClient
    .from('subscriptions')
    .select('id, vehicle_model, clients(full_name), plans(tier_name, price)')
    .order('created_at', { ascending: false })
    .limit(100);

  subscriptionPriceLookup = {};
  const wrap = document.getElementById('paySubscriptionCustom');
  const items = (data || []).map(s => {
    subscriptionPriceLookup[s.id] = s.plans?.price ? Number(s.plans.price) : 0;
    return {
      value: s.id,
      label: `${s.clients?.full_name || 'Customer'} — ${s.plans?.tier_name || 'Plan'} (${s.vehicle_model || ''})`,
    };
  });
  populateCustomSelectList(wrap, items.length ? items : [{ value: '', label: 'No customers found' }]);
}

async function submitPayment(e) {
  e.preventDefault();
  const btn = document.getElementById('paySubmit');
  btn.disabled = true;
  btn.textContent = 'Saving…';

  const source = document.getElementById('paySource').value;
  const payload = {
    amount: Number(document.getElementById('payAmount').value),
    payment_method: document.getElementById('payMethod').value,
    payment_status: document.getElementById('payStatus').value,
    payment_date: document.getElementById('payDate').value,
    notes: document.getElementById('payNotes').value.trim() || null,
  };

  if (source === 'one_time') {
    payload.one_time_booking_id = document.getElementById('payOneTimeBooking').value;
  } else {
    payload.subscription_id = document.getElementById('paySubscription').value;
  }

  const { error } = await supabaseClient.from('payments').insert(payload);

  btn.disabled = false;
  btn.textContent = 'Record Payment';

  if (error) {
    showToast('Failed to record payment: ' + error.message, 'error');
    return;
  }

  showToast('Payment recorded.');
  closeModal(document.getElementById('paymentModalOverlay'));
  await refreshAll();
}

// ---------------- Add Expense modal ----------------
function wireExpenseModal() {
  const overlay = document.getElementById('expenseModalOverlay');
  document.getElementById('openAddExpense').addEventListener('click', () => {
    document.getElementById('expenseForm').reset();

    // Expense date is always today — expenses are logged at the moment
    // they happen, so there's no picker, just a locked display.
    const today = new Date();
    document.getElementById('expDate').value = toDateStr(today);
    document.getElementById('expDateLockedText').textContent =
      today.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });

    overlay.classList.add('open');
    document.body.style.overflow = 'hidden';
  });
  document.getElementById('expenseModalClose').addEventListener('click', () => closeModal(overlay));
  overlay.addEventListener('click', (e) => { if (e.target === overlay) closeModal(overlay); });

  document.getElementById('expenseForm').addEventListener('submit', submitExpense);
}

async function submitExpense(e) {
  e.preventDefault();
  const btn = document.getElementById('expSubmit');
  btn.disabled = true;
  btn.textContent = 'Saving…';

  const payload = {
    category: document.getElementById('expCategory').value,
    amount: Number(document.getElementById('expAmount').value),
    expense_date: document.getElementById('expDate').value,
    description: document.getElementById('expDescription').value.trim() || null,
  };

  const { error } = await supabaseClient.from('expenses').insert(payload);

  btn.disabled = false;
  btn.textContent = 'Add Expense';

  if (error) {
    showToast('Failed to add expense: ' + error.message, 'error');
    return;
  }

  showToast('Expense added.');
  closeModal(document.getElementById('expenseModalOverlay'));
  await refreshAll();
}

function closeModal(overlay) {
  overlay.classList.remove('open');
  document.body.style.overflow = '';
}

document.addEventListener('DOMContentLoaded', init);
