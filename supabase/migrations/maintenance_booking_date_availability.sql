-- =========================================================
-- Maintenance booking date availability
--
-- Adds database-level "one active maintenance booking per date"
-- protection on top of the EXISTING public.bookings table.
--
-- Does NOT create new tables, does NOT touch existing columns,
-- does NOT touch RLS, does NOT touch one_time_bookings/payments,
-- does NOT delete or modify any existing rows.
--
-- Safe to re-run: every DDL statement uses IF NOT EXISTS /
-- CREATE OR REPLACE.
-- =========================================================

-- ---------------------------------------------------------
-- STEP 1 — Duplicate check (READ-ONLY, run this manually first)
--
-- Run this SELECT by itself before applying the rest of this
-- migration. If it returns any rows, DO NOT proceed past this
-- point — resolve the conflicting bookings by hand (e.g. cancel
-- or reschedule one of each conflicting pair), then re-run this
-- check until it returns zero rows.
--
-- This migration does not automatically delete or modify any
-- row. Nothing below this comment should be applied while
-- duplicates exist, or the CREATE UNIQUE INDEX statements in
-- STEP 2 will fail.
-- ---------------------------------------------------------

SELECT
    requested_date,
    COUNT(*) AS booking_count,
    ARRAY_AGG(id ORDER BY created_at) AS booking_ids
FROM public.bookings
WHERE status IN ('pending', 'confirmed', 'rescheduled_by_admin')
GROUP BY requested_date
HAVING COUNT(*) > 1
ORDER BY requested_date;

-- Also check confirmed_date for the same kind of conflict, since a
-- second partial unique index below protects that column too.
SELECT
    confirmed_date,
    COUNT(*) AS booking_count,
    ARRAY_AGG(id ORDER BY created_at) AS booking_ids
FROM public.bookings
WHERE confirmed_date IS NOT NULL
  AND status IN ('pending', 'confirmed', 'rescheduled_by_admin')
GROUP BY confirmed_date
HAVING COUNT(*) > 1
ORDER BY confirmed_date;

-- =========================================================
-- STEP 2 — Partial unique indexes
--
-- Only apply this section once both duplicate-check queries
-- above return zero rows in your actual database. If either
-- query returns rows, the corresponding CREATE UNIQUE INDEX
-- below will fail with a "duplicate key" error — that failure
-- is expected and is the safeguard, not a bug to work around.
-- =========================================================

-- Only one active (pending/confirmed/rescheduled_by_admin) booking
-- may hold a given customer-requested date.
CREATE UNIQUE INDEX IF NOT EXISTS bookings_one_active_date_idx
ON public.bookings (requested_date)
WHERE status IN ('pending', 'confirmed', 'rescheduled_by_admin');

-- Only one active booking may hold a given admin-confirmed date.
-- requested_date and confirmed_date are independent columns in this
-- schema (admin rescheduling never overwrites requested_date), so
-- this is a separate index rather than a reuse of the one above.
CREATE UNIQUE INDEX IF NOT EXISTS bookings_one_active_confirmed_date_idx
ON public.bookings (confirmed_date)
WHERE confirmed_date IS NOT NULL
  AND status IN ('pending', 'confirmed', 'rescheduled_by_admin');

-- =========================================================
-- STEP 3 — Availability RPC
--
-- Returns only booked-out dates (no customer/booking details),
-- so it's safe to expose to anon/authenticated clients for
-- calendar rendering without weakening existing RLS.
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_booked_maintenance_dates()
RETURNS TABLE (
    booked_date date
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT DISTINCT
        COALESCE(confirmed_date, requested_date) AS booked_date
    FROM public.bookings
    WHERE status IN ('pending', 'confirmed', 'rescheduled_by_admin')
    AND COALESCE(confirmed_date, requested_date) >= CURRENT_DATE
    ORDER BY booked_date;
$$;

GRANT EXECUTE ON FUNCTION public.get_booked_maintenance_dates() TO anon, authenticated;

-- =========================================================
-- Notes
--
-- * cancelled / completed bookings are excluded from both partial
--   indexes and from the RPC's WHERE clause, so a date frees up
--   automatically the moment a booking's status changes to either
--   of those — no cleanup step or extra table required.
-- * This migration was NOT executed against any database by the
--   assistant. Run STEP 1 manually, confirm zero duplicate rows,
--   then apply STEP 2 and STEP 3 via the Supabase SQL editor or CLI.
-- =========================================================
