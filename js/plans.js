// =========================================================
// Load and render maintenance plans from Supabase
// =========================================================

let allPlans = [];
let currentSegment = 'sedan_hatch';

async function loadPlans() {
  const grid = document.getElementById('plansGrid');
  try {
    const { data, error } = await supabaseClient
      .from('plans')
      .select('*')
      .eq('active', true)
      .order('tier', { ascending: true });

    if (error) throw error;

    allPlans = data;
    renderPlans();
  } catch (err) {
    console.error('Failed to load plans:', err);
    grid.innerHTML = '<p class="plans-loading">Unable to load plans right now. Please refresh, or reach out on WhatsApp to hear about our care plans.</p>';
  }
}

function formatCurrency(num) {
  return '₹' + Number(num).toLocaleString('en-IN');
}

function frequencyLabel(freqArray) {
  if (freqArray.length === 1) {
    return freqArray[0] === 'biweekly' ? 'Bi-weekly visits' : 'Monthly visits';
  }
  return 'Monthly or bi-weekly';
}

function renderPlans() {
  const grid = document.getElementById('plansGrid');
  const filtered = allPlans.filter(p => p.vehicle_segment === currentSegment);

  if (filtered.length === 0) {
    grid.innerHTML = '<p class="plans-loading">No plans available for this vehicle type yet.</p>';
    return;
  }

  grid.innerHTML = filtered.map(plan => {
    const isVip = plan.tier === 3;
    const savings = plan.standard_value ? plan.standard_value - plan.price : null;

    const features = [];
    features.push(`1 Deep Clean upfront`);
    features.push(`${plan.total_regular_washes} maintenance washes`);
    if (plan.bonus_perk_description) features.push(plan.bonus_perk_description);
    if (plan.mid_year_reset) features.push('Mid-year Deep Clean reset');
    features.push('Priority scheduling');

    return `
      <div class="plan-card ${isVip ? 'plan-card-vip' : ''}">
        ${isVip ? '<span class="plan-vip-badge">VIP</span>' : ''}
        <span class="plan-tier-label">Tier ${plan.tier}</span>
        <h3 class="plan-name">${plan.tier_name}</h3>
        <p class="plan-schedule">${frequencyLabel(plan.frequency_options)}</p>
        <div class="plan-price-block">
          <div class="plan-price">${formatCurrency(plan.price)}</div>
          <div class="plan-price-sub">paid upfront</div>
          ${savings ? `<span class="plan-savings">Save ${formatCurrency(savings)}</span>` : ''}
        </div>
        <ul class="plan-features">
          ${features.map(f => `
            <li>
              <svg viewBox="0 0 20 20" fill="none"><path d="M4 10l4 4 8-8" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>
              <span>${f}</span>
            </li>
          `).join('')}
        </ul>
        <button class="plan-cta" data-plan-id="${plan.id}" onclick="handlePlanEnroll('${plan.id}')">Enroll in this plan</button>
      </div>
    `;
  }).join('');
}

function handlePlanEnroll(planId) {
  // Enrollment requires an account — redirect to signup, carrying the chosen plan.
  window.location.href = `signup.html?plan=${planId}`;
}

document.addEventListener('DOMContentLoaded', () => {
  loadPlans();

  document.querySelectorAll('.segment-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.segment-btn').forEach(b => {
        b.classList.remove('active');
        b.setAttribute('aria-selected', 'false');
      });
      btn.classList.add('active');
      btn.setAttribute('aria-selected', 'true');
      currentSegment = btn.dataset.segment;
      renderPlans();
    });
  });
});