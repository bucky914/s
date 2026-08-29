// =========================================================
// Admin Customers — list + detail
// Note: each row represents one subscription (client + vehicle + plan),
// since a client can have multiple vehicles/plans.
// =========================================================

let allSubscriptions = [];

async function init() {
  const adminUser = await requireAdmin();
  if (!adminUser) return;

  initAdminShell('customers.html', adminUser);

  await loadCustomers();
  document.getElementById('pageLoading').style.display = 'none';
  document.getElementById('listView').style.display = 'block';

  document.getElementById('customerSearch').addEventListener('input', (e) => {
    renderCustomersTable(e.target.value.trim().toLowerCase());
  });

  document.getElementById('backToList').addEventListener('click', (e) => {
    e.preventDefault();
    showListView();
  });

  // Support deep-linking to a specific customer via ?id=
  const params = new URLSearchParams(window.location.search);
  const subId = params.get('id');
  if (subId) openCustomerDetail(subId);
}

async function loadCustomers() {
  const { data, error } = await supabaseClient
    .from('subscriptions')
    .select('*, clients(full_name, phone, email), plans(tier_name, price), payments(amount)')
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Failed to load customers:', error);
    allSubscriptions = [];
  } else {
    allSubscriptions = data || [];
  }

  renderCustomersTable('');
}

function renderCustomersTable(searchTerm) {
  const tbody = document.getElementById('customersBody');
  const emptyEl = document.getElementById('customersEmpty');
  const tableEl = document.getElementById('customersTable');

  const filtered = allSubscriptions.filter(sub => {
    if (!searchTerm) return true;
    const name = (sub.clients?.full_name || '').toLowerCase();
    const vehicle = (sub.vehicle_model || '').toLowerCase();
    return name.includes(searchTerm) || vehicle.includes(searchTerm);
  });

  if (filtered.length === 0) {
    tableEl.style.display = 'none';
    emptyEl.style.display = 'block';
    return;
  }

  tableEl.style.display = 'table';
  emptyEl.style.display = 'none';

  tbody.innerHTML = filtered.map(sub => {
    const planPrice = sub.plans?.price ? Number(sub.plans.price) : 0;
    const paidTotal = (sub.payments || []).reduce((acc, p) => acc + Number(p.amount), 0);
    let paymentBadge;
    if (paidTotal <= 0) {
      paymentBadge = '<span class="badge badge-pending">Unpaid</span>';
    } else if (planPrice && paidTotal < planPrice) {
      paymentBadge = '<span class="badge badge-pending">Partial</span>';
    } else {
      paymentBadge = '<span class="badge badge-active">Paid</span>';
    }

    return `
      <tr data-id="${sub.id}">
        <td>${sub.clients?.full_name || '—'}</td>
        <td>${sub.vehicle_model || '—'}</td>
        <td>${sub.plans?.tier_name || '—'}</td>
        <td>${sub.status === 'active' ? sub.washes_remaining : '—'}</td>
        <td>${badgeHtml(sub.status)}</td>
        <td>${paymentBadge}</td>
      </tr>
    `;
  }).join('');

  tbody.querySelectorAll('tr').forEach(row => {
    row.addEventListener('click', () => openCustomerDetail(row.dataset.id));
  });
}

function showListView() {
  document.getElementById('detailView').style.display = 'none';
  document.getElementById('listView').style.display = 'block';
  window.history.replaceState({}, '', 'customers.html');
}

async function openCustomerDetail(subId) {
  const { data: sub, error } = await supabaseClient
    .from('subscriptions')
    .select('*, clients(full_name, phone, email), plans(tier_name, total_regular_washes, price)')
    .eq('id', subId)
    .maybeSingle();

  if (error || !sub) {
    showToast('Could not load customer details.', 'error');
    return;
  }

  document.getElementById('listView').style.display = 'none';
  document.getElementById('detailView').style.display = 'block';
  window.history.replaceState({}, '', `customers.html?id=${subId}`);

  document.getElementById('detailName').textContent = sub.clients?.full_name || 'Customer';
  document.getElementById('dName').textContent = sub.clients?.full_name || '—';
  document.getElementById('dPhone').textContent = sub.clients?.phone || '—';
  document.getElementById('dEmail').textContent = sub.clients?.email || '—';

  document.getElementById('dVehicleModel').textContent = sub.vehicle_model || '—';
  document.getElementById('dVehicleSegment').textContent = sub.vehicle_segment === 'suv' ? 'SUV / MPV / Large SUV' : 'Sedan / Hatch / Compact SUV';
  document.getElementById('dAddress').textContent = sub.service_address || '—';

  document.getElementById('dPlanName').textContent = sub.plans?.tier_name || '—';
  document.getElementById('dStatus').innerHTML = badgeHtml(sub.status);
  document.getElementById('dStartDate').textContent = sub.start_date ? formatDate(sub.start_date) : '—';
  document.getElementById('dTotalWashes').textContent = sub.plans?.total_regular_washes ?? '—';
  document.getElementById('dCompletedWashes').textContent = sub.washes_used;
  document.getElementById('dRemainingWashes').textContent = sub.washes_remaining;

  await renderPaymentStatus(sub);
  renderCustomerActions(sub);
  await loadCustomerHistory(subId);
}

async function renderPaymentStatus(sub) {
  const planPrice = sub.plans?.price ? Number(sub.plans.price) : 0;
  const { data: payments } = await supabaseClient
    .from('payments')
    .select('amount')
    .eq('subscription_id', sub.id);

  const paidTotal = (payments || []).reduce((acc, p) => acc + Number(p.amount), 0);
  const el = document.getElementById('dPaymentStatus');

  if (paidTotal <= 0) {
    el.innerHTML = '<span class="badge badge-pending">Unpaid</span>';
  } else if (planPrice && paidTotal < planPrice) {
    el.innerHTML = `<span class="badge badge-pending">Partial — ₹${paidTotal.toLocaleString('en-IN')} of ₹${planPrice.toLocaleString('en-IN')}</span>`;
  } else {
    el.innerHTML = `<span class="badge badge-active">Paid — ₹${paidTotal.toLocaleString('en-IN')}</span>`;
  }
}

function renderCustomerActions(sub) {
  const actionsEl = document.getElementById('dActions');
  actionsEl.innerHTML = '';

  // 'pending_confirmation' only applies to historical subscriptions
  // created before enrollment became automatic (see js/dashboard.js) —
  // new enrollments go straight to 'active' and never reach this branch.
  if (sub.status === 'pending_confirmation') {
    actionsEl.innerHTML = `
      <button class="btn btn-success btn-sm" id="detailApprove">Approve</button>
      <button class="btn btn-danger btn-sm" id="detailReject">Reject</button>
    `;
    document.getElementById('detailApprove').addEventListener('click', async () => {
      const approveBtn = document.getElementById('detailApprove');
      approveBtn.disabled = true;
      approveBtn.textContent = 'Approving…';

      await supabaseClient.from('subscriptions')
        .update({ status: 'active', start_date: toLocalDateStr(new Date()) })
        .eq('id', sub.id);

      const planPrice = sub.plans?.price ? Number(sub.plans.price) : 0;
      if (planPrice > 0) {
        await supabaseClient.from('payments').insert({
          subscription_id: sub.id,
          amount: planPrice,
          payment_method: 'cash',
          payment_status: 'paid',
          payment_date: toLocalDateStr(new Date()),
          notes: 'Recorded automatically on plan approval (paid upfront).',
        });
      }

      showToast('Approved and payment recorded — now active.');
      await loadCustomers();
      openCustomerDetail(sub.id);
    });
    document.getElementById('detailReject').addEventListener('click', async () => {
      if (!confirm('Reject this request?')) return;
      await supabaseClient.from('subscriptions').update({ status: 'cancelled' }).eq('id', sub.id);
      showToast('Request rejected.');
      await loadCustomers();
      showListView();
    });
  } else if (sub.status === 'active') {
    actionsEl.innerHTML = `
      <button class="btn btn-outline btn-sm" id="detailCancel">Cancel Subscription</button>
      <a href="finances.html?pay_subscription=${sub.id}"
         class="payment-adjust-link"
         title="Payment is recorded automatically when you approve an enrollment. Use this only to correct a mistake or add a top-up payment.">
        Need to correct or add a payment?
      </a>
    `;
    document.getElementById('detailCancel').addEventListener('click', async () => {
      if (!confirm('Cancel this customer\'s active subscription?')) return;
      await supabaseClient.from('subscriptions').update({ status: 'cancelled' }).eq('id', sub.id);
      showToast('Subscription cancelled.');
      await loadCustomers();
      openCustomerDetail(sub.id);
    });
  }
  // Note: washes_remaining/washes_used are intentionally NOT editable here —
  // they only change automatically when a booking is marked Completed
  // (handled in Bookings, backed by a DB trigger).
}

async function loadCustomerHistory(subId) {
  const { data, error } = await supabaseClient
    .from('bookings')
    .select('*')
    .eq('subscription_id', subId)
    .order('requested_date', { ascending: false });

  const tbody = document.getElementById('historyBody');
  const emptyEl = document.getElementById('historyEmpty');
  const tableEl = document.getElementById('historyTable');

  if (error || !data || data.length === 0) {
    tableEl.style.display = 'none';
    emptyEl.style.display = 'block';
    return;
  }

  tableEl.style.display = 'table';
  emptyEl.style.display = 'none';

  tbody.innerHTML = data.map(b => `
    <tr>
      <td>${formatDate(b.confirmed_date || b.requested_date)}</td>
      <td>${visitTypeLabel(b.visit_type)}</td>
      <td>${badgeHtml(b.status)}</td>
    </tr>
  `).join('');
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
