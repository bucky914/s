// =========================================================
// Shared auth helpers — used by signup.html, login.html, dashboard.html
// Requires config.js (supabaseClient) to be loaded first.
// =========================================================

/**
 * Guards every function below against config.js failing to load or
 * failing to create a real Supabase client (e.g. the CDN script was
 * blocked, or SUPABASE_URL/SUPABASE_ANON_KEY in config.js are missing
 * or invalid). Without this, calling supabaseClient.auth.signUp(...)
 * on an undefined/broken client throws an opaque ReferenceError/
 * TypeError that can be missed if DevTools wasn't already open and
 * recording — the submit button would then stay stuck on its "in
 * progress" text forever with no visible explanation. This turns that
 * into a clear, catchable error with a message the calling page's
 * showAlert() can actually display.
 */
function assertSupabaseClientReady() {
  if (typeof supabaseClient === 'undefined' || !supabaseClient || typeof supabaseClient.auth === 'undefined') {
    throw new Error('Could not connect to the server. Please refresh the page and try again. If this keeps happening, check that js/config.js is loaded correctly.');
  }
}

/**
 * Sign up a new client: creates a Supabase auth user, then a row in `clients`.
 * Returns { user, error }
 */
async function signUpClient({ fullName, phone, email, password }) {
  assertSupabaseClientReady();

  const { data: authData, error: authError } = await supabaseClient.auth.signUp({
    email,
    password,
  });

  if (authError) return { user: null, error: authError };

  const user = authData.user;
  const session = authData.session;

  if (!user) {
    return { user: null, error: null, needsConfirmation: true };
  }

  if (!session) {
    // User was created but no session yet — email confirmation is required
    // by the Supabase project's auth settings. Without a session, auth.uid()
    // is null and the clients insert would be rejected by RLS, so stop here
    // and tell the person to confirm their email first.
    return { user, error: null, needsConfirmation: true };
  }

  // Create the matching clients row (id must equal auth.users.id per RLS policy)
  const { error: clientError } = await supabaseClient
    .from('clients')
    .insert({ id: user.id, full_name: fullName, phone, email });

  if (clientError) return { user, error: clientError };

  return { user, error: null };
}

/**
 * Log in an existing client.
 * Returns { user, error }
 */
async function signInClient({ email, password }) {
  assertSupabaseClientReady();

  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) return { user: null, error };
  return { user: data.user, error: null };
}

/**
 * Get the current logged-in user (or null). Use to guard dashboard access.
 * Deliberately does NOT throw if the client isn't ready — callers
 * (including the page-load "already logged in?" checks in signup.html/
 * login.html) treat this as "not logged in" rather than crashing on
 * page load, which would block the person from even seeing the form.
 */
async function getCurrentUser() {
  if (typeof supabaseClient === 'undefined' || !supabaseClient || typeof supabaseClient.auth === 'undefined') {
    console.error('supabaseClient is not available — check that js/config.js loaded correctly.');
    return null;
  }
  const { data, error } = await supabaseClient.auth.getUser();
  if (error || !data.user) return null;
  return data.user;
}

/**
 * Sign out and redirect to login.
 */
async function signOutClient() {
  assertSupabaseClientReady();
  await supabaseClient.auth.signOut();
  window.location.href = 'login.html';
}

/**
 * Redirect to login.html if no user is signed in. Call at the top of
 * protected pages (dashboard.html). Returns the user if signed in.
 */
async function requireAuth() {
  const user = await getCurrentUser();
  if (!user) {
    window.location.href = 'login.html';
    return null;
  }
  return user;
}