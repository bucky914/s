// =========================================================
// Admin Settings
// =========================================================

async function init() {
  const adminUser = await requireAdmin();
  if (!adminUser) return;

  initAdminShell('settings.html', adminUser);

  document.getElementById('adminEmail').textContent = adminUser.email;
  document.getElementById('adminCreated').textContent = adminUser.created_at ? formatDate(adminUser.created_at) : '—';

  await loadBusinessSettings();

  document.getElementById('pageLoading').style.display = 'none';
  document.getElementById('pageContent').style.display = 'block';

  document.getElementById('settingsLogout').addEventListener('click', adminSignOut);
  document.getElementById('businessForm').addEventListener('submit', saveBusinessSettings);
}

async function loadBusinessSettings() {
  const { data, error } = await supabaseClient
    .from('business_settings')
    .select('*')
    .eq('id', 1)
    .maybeSingle();

  if (error || !data) {
    console.error('Failed to load business settings:', error);
    return;
  }

  document.getElementById('bizName').value = data.business_name || '';
  document.getElementById('bizPhone').value = data.phone || '';
  document.getElementById('bizWhatsapp').value = data.whatsapp_number || '';
  document.getElementById('bizArea').value = data.service_area || '';
  document.getElementById('bizHours').value = data.working_hours || '';
}

async function saveBusinessSettings(e) {
  e.preventDefault();
  const submitBtn = e.target.querySelector('button[type="submit"]');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Saving…';

  const { error } = await supabaseClient
    .from('business_settings')
    .update({
      business_name: document.getElementById('bizName').value.trim(),
      phone: document.getElementById('bizPhone').value.trim(),
      whatsapp_number: document.getElementById('bizWhatsapp').value.trim(),
      service_area: document.getElementById('bizArea').value.trim(),
      working_hours: document.getElementById('bizHours').value.trim(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', 1);

  submitBtn.disabled = false;
  submitBtn.textContent = 'Save Business Info';

  if (error) {
    showToast('Failed to save: ' + error.message, 'error');
    return;
  }

  showToast('Business info saved.');
}

document.addEventListener('DOMContentLoaded', init);