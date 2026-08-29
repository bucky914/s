// =========================================================
// Supabase project configuration
// =========================================================
const SUPABASE_URL = 'https://powdsowqehbinjsohyzg.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBvd2Rzb3dxZWhiaW5qc29oeXpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc3NTAwODcsImV4cCI6MjEwMzMyNjA4N30.9tZ3g0oilBf6yNlmg0UHXbKexGSIa5OPKj88uS4md80';

// Single shared Supabase client used across the site.
//
// window.supabase comes from the @supabase/supabase-js CDN <script>
// tag that must load BEFORE this file. If that CDN request is blocked
// (offline, ad blocker, network policy, or it simply hasn't finished
// loading yet), window.supabase is undefined and
// window.supabase.createClient(...) throws immediately — which would
// stop every other script on the page from running at all, including
// auth.js, with no specific error message pointing at the real cause.
// This guard makes that failure visible and gives every page a
// consistent, catchable error instead of a silent dead page.
let supabaseClient;
if (typeof window.supabase === 'undefined') {
  console.error('Supabase library failed to load (window.supabase is undefined). Check your internet connection or whether an ad blocker/network policy is blocking cdn.jsdelivr.net.');
  supabaseClient = null;
} else {
  supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
}

// Owner's WhatsApp number for one-time bookings (E.164 format, no + or spaces)
// TODO: replace with the real business WhatsApp number
const OWNER_WHATSAPP_NUMBER = '919629885790';
