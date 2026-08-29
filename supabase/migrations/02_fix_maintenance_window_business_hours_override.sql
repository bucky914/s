-- =========================================================
-- RUN THIS AFTER 00_complete_setup_consolidated.sql AND
-- 01_maintenance_availability_authoritative_fix.sql.
--
-- WHAT WAS WRONG
--
-- Reported symptom: before selecting a date, Maintenance Wash
-- correctly showed 7:00 AM-7:00 PM. After selecting a date, the same
-- service's time list silently shrank back to 7:00 AM-3:00 PM.
--
-- get_booking_availability(p_date) itself was already correct (see
-- 01_maintenance_availability_authoritative_fix.sql) — its maintenance
-- slot loop is capped by public.get_business_hours(), and its guest-
-- service slot loop is capped by public.get_service_hours(), which are
-- two different windows with two different intents.
--
-- The actual bug is inside get_business_hours() (the function that is
-- supposed to represent the MAINTENANCE window, 7 AM-7 PM). Since
-- service_and_maintenance_hours_split.sql, it has parsed the admin's
-- free-text "Working Hours" field (business_settings.working_hours,
-- edited from admin/settings.html, e.g. "Tue-Sun, 8:00 AM - 6:00 PM")
-- and used it as an outer CAP on the maintenance window — falling back
-- to the fixed 7 AM-7 PM default ONLY when that field is empty or
-- fails to parse.
--
-- That field predates the current two-window (maintenance vs Deep
-- Clean/service) requirement and was never meant to be a second,
-- competing source of truth for the maintenance booking window. If an
-- admin had ever set it to something like "7:00 AM - 3:00 PM" (a very
-- plausible value, since that historically WAS the shop's single
-- window before the split), get_business_hours() silently returns
-- 7 AM-3 PM instead of 7 AM-7 PM — which is exactly what
-- get_booking_availability() then uses to build
-- available_maintenance_times, reproducing the reported bug on every
-- date, not just specific ones.
--
-- get_service_hours() (the Deep Clean/guest-service window) is
-- unaffected by this file and is NOT changed — it must remain
-- 7 AM-3 PM and continue to be derived independently.
--
-- FIX
--
-- get_business_hours() no longer reads business_settings.working_hours
-- at all. It always returns the fixed maintenance window, 7:00 AM-
-- 7:00 PM, full stop. The admin's "Working Hours" text field remains in
-- the database and the settings UI (not touched, not deleted, still
-- editable) — it simply no longer feeds into any booking-availability
-- calculation. This matches the explicit current requirement: the
-- maintenance window must stay 7 AM-7 PM regardless of what that field
-- contains.
--
-- Every function that calls get_business_hours() (get_service_hours(),
-- get_booking_availability(), book_maintenance_visit(),
-- admin_reschedule_maintenance_visit(), book_membership(),
-- auto_book_due_maintenance()) picks up the fix automatically — none
-- of them need to change, since they all already just SELECT the
-- returned open_minutes/close_minutes without their own separate
-- parsing logic.
--
-- CREATE OR REPLACE only. No signature change. No table touched, no
-- data deleted, no booking deleted. business_settings and its
-- working_hours column are left exactly as they are — only the
-- function that used to read from them is updated to stop doing so.
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_business_hours()
RETURNS TABLE (open_minutes integer, close_minutes integer)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  -- Fixed maintenance window: 7:00 AM - 7:00 PM. Deliberately NOT
  -- derived from business_settings.working_hours (see header above) —
  -- that field is informational/display-only for the admin and must
  -- never narrow the maintenance booking window.
  SELECT (7 * 60)::integer, (19 * 60)::integer;
$$;

GRANT EXECUTE ON FUNCTION public.get_business_hours() TO anon, authenticated;

-- ---------------------------------------------------------
-- Notes
--
-- * get_service_hours() is untouched by this migration. It still
--   calls get_business_hours() internally (for a defensive outer cap
--   only), but since get_business_hours() now always returns a fixed
--   7 AM-7 PM (which is wider than get_service_hours()'s own 7 AM-3 PM
--   default on both ends), that cap is now a no-op in practice —
--   get_service_hours() continues to return exactly 7 AM-3 PM.
-- * This migration has NOT been executed against any database by the
--   assistant. Run it via the Supabase SQL editor or CLI, after
--   00_complete_setup_consolidated.sql and
--   01_maintenance_availability_authoritative_fix.sql have both been
--   applied.
-- =========================================================
