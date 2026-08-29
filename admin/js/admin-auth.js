// =========================================================
// Admin auth guard — used on every admin page except login.html
// Requires ../js/config.js (supabaseClient) loaded first.
// =========================================================

/**
 * Confirms the current session belongs to an admin (present in admin_users).
 * Redirects to admin login if not. Returns the user object if valid.
 */
async function requireAdmin() {
  const { data: userData, error: userError } = await supabaseClient.auth.getUser();

  if (userError || !userData.user) {
    window.location.href = 'login.html';
    return null;
  }

  const { data: adminRow, error: adminError } = await supabaseClient
    .from('admin_users')
    .select('id')
    .eq('id', userData.user.id)
    .maybeSingle();

  if (adminError || !adminRow) {
    // Logged in, but not an admin — do not leak admin UI, send them away.
    await supabaseClient.auth.signOut();
    window.location.href = 'login.html';
    return null;
  }

  return userData.user;
}

async function adminSignOut() {
  await supabaseClient.auth.signOut();
  window.location.href = 'login.html';
}