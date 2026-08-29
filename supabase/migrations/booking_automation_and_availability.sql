-- =========================================================
-- Booking automation + time-slot availability
--
-- Builds on top of the EXISTING schema and the EXISTING
-- maintenance_booking_date_availability.sql migration. Does NOT
-- drop any table, does NOT delete any row, does NOT touch
-- historical data. Safe to re-run: every DDL statement uses
-- IF NOT EXISTS / IF EXISTS / CREATE OR REPLACE.
--
-- REVISION NOTE: an earlier version of this migration used
-- "SELECT COUNT(*) ... FOR UPDATE" / "SELECT EXISTS(...) FOR UPDATE"
-- inside book_maintenance_visit(), admin_reschedule_maintenance_visit(),
-- and book_one_time_service() to try to lock the rows being checked for
-- conflicts. That is invalid PostgreSQL — FOR UPDATE cannot be applied
-- to an aggregate or EXISTS result (ERROR 0A000: "FOR UPDATE is not
-- allowed with aggregate functions"), and every one of Supabase's RPC
-- calls to book_maintenance_visit failed with a 400 as a result. This
-- version replaces that pattern everywhere it appeared with a
-- transaction-level advisory lock (pg_advisory_xact_lock) keyed on the
-- booking date, taken before any availability read in each writer
-- function. See the comments inside each function below for details.
--
-- What this migration does:
--   1. Drops the old "one maintenance booking = whole date" unique
--      indexes (superseded by real 4-hour overlap checking).
--   2. Adds a status column to one_time_bookings (default 'confirmed').
--   3. Adds indexes for the new availability queries.
--   4. Creates get_business_hours() — parses business_settings.working_hours
--      with a safe fallback.
--   5. Creates get_booking_availability(date) — the read-only RPC the
--      frontend calendars call.
--   6. Creates book_maintenance_visit(...) and
--      admin_reschedule_maintenance_visit(...) — atomic, SECURITY
--      DEFINER RPCs, concurrency-safe via pg_advisory_xact_lock.
--   7. Creates book_one_time_service(...) — atomic, SECURITY DEFINER
--      RPC for guest bookings, same locking strategy.
--   8. Changes the default status on new subscriptions to 'active'
--      (enrollment itself is done by a normal insert from the
--      frontend, RLS already allows the client to insert their own row —
--      this migration does not add a new default requirement beyond that).
-- =========================================================

-- ---------------------------------------------------------
-- STEP 1 — Drop the old date-level uniqueness indexes
--
-- These enforced "one active booking per date" — incompatible with
-- multiple non-overlapping 4-hour maintenance bookings sharing a date.
-- Overlap protection is now enforced inside book_maintenance_visit()
-- via a transaction-level advisory lock (see STEP 6), so dropping
-- these does not remove concurrency safety.
-- ---------------------------------------------------------

DROP INDEX IF EXISTS public.bookings_one_active_date_idx;
DROP INDEX IF EXISTS public.bookings_one_active_confirmed_date_idx;

-- ---------------------------------------------------------
-- STEP 2 — one_time_bookings.status
-- ---------------------------------------------------------

ALTER TABLE public.one_time_bookings
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'confirmed';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'one_time_bookings_status_check'
  ) THEN
    ALTER TABLE public.one_time_bookings
      ADD CONSTRAINT one_time_bookings_status_check
      CHECK (status IN ('confirmed', 'completed', 'cancelled'));
  END IF;
END $$;

-- Backfill: historical rows had no status column, so they were inserted
-- before this concept existed. Treat them as 'confirmed' (their
-- original, pre-status meaning) rather than leaving them ambiguous —
-- this does not change any other column and does not delete anything.
UPDATE public.one_time_bookings SET status = 'confirmed' WHERE status IS NULL;

-- ---------------------------------------------------------
-- STEP 3 — Indexes
-- ---------------------------------------------------------

CREATE INDEX IF NOT EXISTS bookings_requested_date_status_idx
  ON public.bookings (requested_date, status);

CREATE INDEX IF NOT EXISTS bookings_confirmed_date_status_idx
  ON public.bookings (confirmed_date, status)
  WHERE confirmed_date IS NOT NULL;

CREATE INDEX IF NOT EXISTS bookings_subscription_id_status_idx
  ON public.bookings (subscription_id, status);

CREATE INDEX IF NOT EXISTS one_time_bookings_requested_date_status_idx
  ON public.one_time_bookings (requested_date, status);

CREATE INDEX IF NOT EXISTS subscriptions_client_id_status_idx
  ON public.subscriptions (client_id, status);

-- ---------------------------------------------------------
-- STEP 4 — Business hours helper
--
-- business_settings.working_hours is a free-text field (admin types
-- e.g. "8:00 AM - 6:00 PM"). This parses it defensively; if it can't
-- be parsed, falls back to 8 AM - 6 PM so the booking system never
-- breaks because of a free-text settings field.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_business_hours()
RETURNS TABLE (open_minutes integer, close_minutes integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  raw text;
  parts text[];
  open_str text;
  close_str text;
  o_min integer;
  c_min integer;
BEGIN
  SELECT working_hours INTO raw FROM public.business_settings WHERE id = 1;

  IF raw IS NOT NULL THEN
    parts := regexp_match(raw, '(\d{1,2}(:\d{2})?\s*[AaPp][Mm]).*?(\d{1,2}(:\d{2})?\s*[AaPp][Mm])');
    IF parts IS NOT NULL THEN
      open_str := parts[1];
      close_str := parts[3];
      BEGIN
        o_min := (EXTRACT(HOUR FROM open_str::time) * 60 + EXTRACT(MINUTE FROM open_str::time))::integer;
        c_min := (EXTRACT(HOUR FROM close_str::time) * 60 + EXTRACT(MINUTE FROM close_str::time))::integer;
      EXCEPTION WHEN OTHERS THEN
        o_min := NULL;
        c_min := NULL;
      END;
    END IF;
  END IF;

  IF o_min IS NULL OR c_min IS NULL OR c_min <= o_min THEN
    o_min := 8 * 60;   -- 8:00 AM fallback
    c_min := 18 * 60;  -- 6:00 PM fallback
  END IF;

  RETURN QUERY SELECT o_min, c_min;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_business_hours() TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 5a — timeToMinutes-equivalent SQL helper
-- Parses labels like '1:00 PM' / '12:00 PM' into minutes since midnight.
-- Created before get_booking_availability, which calls it.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.time_label_to_minutes(p_label text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (EXTRACT(HOUR FROM p_label::time) * 60 + EXTRACT(MINUTE FROM p_label::time))::integer;
$$;

GRANT EXECUTE ON FUNCTION public.time_label_to_minutes(text) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 5b — Availability RPC (read-only, safe for anon)
--
-- Interval semantics are [start, end) throughout: 1PM-5PM does not
-- overlap 5PM-9PM, but does overlap 4PM-8PM.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_booking_availability(p_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_service_booked boolean;
  v_maintenance jsonb;
  v_open_min integer;
  v_close_min integer;
  v_maintenance_duration integer := 240; -- 4 hours, minutes
  v_slot_labels text[] := ARRAY['8:00 AM','9:00 AM','10:00 AM','11:00 AM','12:00 PM','1:00 PM','2:00 PM','3:00 PM','4:00 PM','5:00 PM','6:00 PM'];
  v_available_times text[] := '{}';
  v_label text;
  v_start_min integer;
  v_end_min integer;
  v_conflict boolean;
  v_intervals int[][];
  i integer;
BEGIN
  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();

  -- Rule A: any confirmed one-time service on this date blocks the whole day.
  SELECT EXISTS (
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_date AND status = 'confirmed'
  ) INTO v_service_booked;

  -- Existing maintenance bookings on this date (active statuses only),
  -- expressed as [start, end) minute intervals from midnight.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'start', to_char((make_time(0,0,0) + (b.start_min || ' minutes')::interval)::time, 'HH24:MI'),
           'end',   to_char((make_time(0,0,0) + (b.end_min || ' minutes')::interval)::time, 'HH24:MI')
         ) ORDER BY b.start_min), '[]'::jsonb),
         array_agg(ARRAY[b.start_min, b.end_min])
    INTO v_maintenance, v_intervals
  FROM (
    SELECT
      public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) AS start_min,
      public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_maintenance_duration AS end_min
    FROM public.bookings
    WHERE COALESCE(confirmed_date, requested_date) = p_date
      AND status IN ('confirmed', 'rescheduled_by_admin')
  ) b;

  IF v_intervals IS NULL THEN
    v_intervals := ARRAY[]::int[][];
  END IF;

  IF NOT v_service_booked THEN
    FOREACH v_label IN ARRAY v_slot_labels LOOP
      v_start_min := public.time_label_to_minutes(v_label);
      v_end_min := v_start_min + v_maintenance_duration;

      v_conflict := false;

      -- Must fit inside business hours.
      IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
        v_conflict := true;
      END IF;

      -- Must not overlap any existing maintenance interval: candidate is
      -- rejected unless candidateStart >= existingEnd OR candidateEnd <= existingStart.
      IF NOT v_conflict THEN
        FOR i IN 1 .. COALESCE(array_length(v_intervals, 1), 0) LOOP
          IF NOT (v_start_min >= v_intervals[i][2] OR v_end_min <= v_intervals[i][1]) THEN
            v_conflict := true;
            EXIT;
          END IF;
        END LOOP;
      END IF;

      IF NOT v_conflict THEN
        v_available_times := array_append(v_available_times, v_label);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'date', p_date,
    'fully_unavailable', v_service_booked OR (array_length(v_available_times, 1) IS NULL OR array_length(v_available_times, 1) = 0),
    'service_booked', v_service_booked,
    'maintenance_bookings', v_maintenance,
    'available_maintenance_times', to_jsonb(v_available_times)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_booking_availability(date) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 6 — Atomic maintenance booking RPC
--
-- SECURITY DEFINER so it can read/write across the client's own rows
-- under RLS, but auth.uid() is used throughout to make sure a caller
-- can only ever book against their own subscription — never trusts a
-- client-supplied client_id.
--
-- Concurrency: a transaction-level advisory lock keyed on the requested
-- date (pg_advisory_xact_lock) is taken FIRST, before any availability
-- read. Postgres does not allow FOR UPDATE on an aggregate/EXISTS
-- result (SELECT COUNT(*) ... FOR UPDATE and SELECT EXISTS(...) FOR
-- UPDATE are both syntax errors — ERROR 0A000), so row-level locking
-- can't be used to protect the count/exists checks below directly.
-- The advisory lock instead serializes ALL writers for the same date:
-- a second transaction requesting the same date blocks on
-- pg_advisory_xact_lock until the first commits or rolls back, so by
-- the time it runs its own availability checks it is guaranteed to see
-- the first transaction's just-inserted row (or its absence, on
-- rollback). This makes the plain SELECT COUNT(*)/SELECT EXISTS reads
-- that follow safe without needing FOR UPDATE at all. The lock is
-- released automatically at transaction end (COMMIT or ROLLBACK) —
-- pg_advisory_xact_lock, not pg_advisory_lock, so there's no risk of
-- leaking a held lock if the function raises.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.book_maintenance_visit(
  p_subscription_id uuid,
  p_requested_date date,
  p_requested_time text
)
RETURNS public.bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub public.subscriptions;
  v_open_min integer;
  v_close_min integer;
  v_start_min integer;
  v_end_min integer;
  v_duration integer := 240;
  v_service_booked boolean;
  v_conflict_count integer;
  v_booking public.bookings;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF p_requested_date IS NULL THEN
    RAISE EXCEPTION 'MISSING_DATE' USING ERRCODE = 'P0001';
  END IF;

  -- Serialize every writer (maintenance booking, reschedule, or guest
  -- service booking) touching this date. Must happen before any
  -- availability read below so those reads are guaranteed consistent.
  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

  -- Load + validate the subscription. No FOR UPDATE needed here — the
  -- advisory lock above already serializes concurrent bookings against
  -- this date, and a subscription is only ever mutated by its owning
  -- client or an admin outside of this date-scoped conflict, so a
  -- plain read is sufficient and keeps this a normal (non-aggregate,
  -- non-EXISTS) single-row SELECT, which FOR UPDATE would in fact be
  -- valid on if we wanted it — but it isn't the source of the bug and
  -- isn't needed for correctness once the date lock is held.
  SELECT * INTO v_sub
  FROM public.subscriptions
  WHERE id = p_subscription_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF v_sub.client_id <> auth.uid() THEN
    RAISE EXCEPTION 'NOT_YOUR_SUBSCRIPTION' USING ERRCODE = '42501';
  END IF;

  IF v_sub.status <> 'active' THEN
    RAISE EXCEPTION 'SUBSCRIPTION_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;

  IF v_sub.washes_remaining <= 0 THEN
    RAISE EXCEPTION 'NO_WASHES_REMAINING' USING ERRCODE = 'P0001';
  END IF;

  IF p_requested_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'DATE_IN_PAST' USING ERRCODE = 'P0001';
  END IF;

  v_start_min := public.time_label_to_minutes(p_requested_time);
  v_end_min := v_start_min + v_duration;

  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_BUSINESS_HOURS' USING ERRCODE = 'P0001';
  END IF;

  -- Rule A: a confirmed one-time service on this date blocks all
  -- maintenance. Plain SELECT EXISTS — no FOR UPDATE, and none needed:
  -- the advisory lock above already guarantees no concurrent writer can
  -- be mid-insert/update on this date while we hold it.
  SELECT EXISTS (
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_requested_date AND status = 'confirmed'
  ) INTO v_service_booked;

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  -- Rule B: no overlapping maintenance bookings. Plain SELECT COUNT(*)
  -- — no FOR UPDATE (which is invalid on an aggregate anyway; this is
  -- the exact pattern that raised ERROR 0A000). Safe without row
  -- locking because the advisory lock already serializes writers.
  SELECT COUNT(*) INTO v_conflict_count
  FROM public.bookings
  WHERE COALESCE(confirmed_date, requested_date) = p_requested_date
    AND status IN ('confirmed', 'rescheduled_by_admin')
    AND NOT (
      v_start_min >= (public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration)
      OR v_end_min <= public.time_label_to_minutes(COALESCE(confirmed_time, requested_time))
    );

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION 'SLOT_CONFLICT' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.bookings (
    subscription_id, visit_type, requested_date, requested_time, status
  ) VALUES (
    p_subscription_id, 'maintenance_wash', p_requested_date, p_requested_time, 'confirmed'
  )
  RETURNING * INTO v_booking;

  -- washes_remaining/washes_used are adjusted by the existing
  -- handle_booking_completion trigger when status becomes 'completed' —
  -- intentionally NOT decremented here to avoid double-counting, and so
  -- cancelling a confirmed booking doesn't consume a wash.

  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_maintenance_visit(uuid, date, text) TO authenticated;

-- ---------------------------------------------------------
-- STEP 6b — Admin reschedule RPC
--
-- Separate from book_maintenance_visit() because a reschedule updates
-- an existing booking (excluding it from its own conflict check) and is
-- restricted to admins rather than the owning client. Uses the same
-- [start, end) overlap rule and the same full-day service block, so the
-- admin can never create a conflict the customer-facing flow would
-- reject either.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_reschedule_maintenance_visit(
  p_booking_id uuid,
  p_new_date date,
  p_new_time text,
  p_note text
)
RETURNS public.bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_open_min integer;
  v_close_min integer;
  v_start_min integer;
  v_end_min integer;
  v_duration integer := 240;
  v_service_booked boolean;
  v_conflict_count integer;
  v_booking public.bookings;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid()) THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED' USING ERRCODE = '42501';
  END IF;

  IF p_new_date IS NULL THEN
    RAISE EXCEPTION 'MISSING_DATE' USING ERRCODE = 'P0001';
  END IF;

  -- Serialize every writer touching the destination date, same as
  -- book_maintenance_visit(). Taken before any availability read below.
  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_new_date::text));

  -- This targets a single row by primary key (not an aggregate), so
  -- FOR UPDATE is valid here and genuinely useful: it locks the exact
  -- booking being edited against a concurrent reschedule/cancel of the
  -- same row while we're mutating it.
  PERFORM 1 FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BOOKING_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  v_start_min := public.time_label_to_minutes(p_new_time);
  v_end_min := v_start_min + v_duration;

  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_BUSINESS_HOURS' USING ERRCODE = 'P0001';
  END IF;

  -- Plain SELECT EXISTS — no FOR UPDATE (invalid on this shape anyway;
  -- see book_maintenance_visit()'s comment). The advisory lock above
  -- makes this read safe against concurrent writers for this date.
  SELECT EXISTS (
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_new_date AND status = 'confirmed'
  ) INTO v_service_booked;

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  -- Plain SELECT COUNT(*) — no FOR UPDATE (this exact combination is
  -- what raised ERROR 0A000). Safe without row locking because the
  -- advisory lock already serializes writers for this date.
  SELECT COUNT(*) INTO v_conflict_count
  FROM public.bookings
  WHERE id <> p_booking_id
    AND COALESCE(confirmed_date, requested_date) = p_new_date
    AND status IN ('confirmed', 'rescheduled_by_admin')
    AND NOT (
      v_start_min >= (public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration)
      OR v_end_min <= public.time_label_to_minutes(COALESCE(confirmed_time, requested_time))
    );

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION 'SLOT_CONFLICT' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.bookings
  SET confirmed_date = p_new_date,
      confirmed_time = p_new_time,
      status = 'rescheduled_by_admin',
      admin_note = COALESCE(p_note, admin_note),
      updated_at = now()
  WHERE id = p_booking_id
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_reschedule_maintenance_visit(uuid, date, text, text) TO authenticated;


-- ---------------------------------------------------------
-- STEP 7 — Atomic one-time (guest) service booking RPC
--
-- Guests are not authenticated, so this validates required fields
-- server-side instead of relying on auth.uid(). SECURITY DEFINER lets
-- it write to one_time_bookings under RLS designed for admin/service use.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.book_one_time_service(
  p_customer_name text,
  p_customer_phone text,
  p_service text,
  p_vehicle_type text,
  p_vehicle_model text,
  p_seat_material text,
  p_addons text[],
  p_service_address text,
  p_requested_date date,
  p_requested_time text,
  p_notes text,
  p_calculated_price numeric
)
RETURNS public.one_time_bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing_service_count integer;
  v_maintenance_exists boolean;
  v_booking public.one_time_bookings;
BEGIN
  IF p_customer_name IS NULL OR btrim(p_customer_name) = '' THEN
    RAISE EXCEPTION 'MISSING_NAME' USING ERRCODE = 'P0001';
  END IF;
  IF p_customer_phone IS NULL OR btrim(p_customer_phone) = '' THEN
    RAISE EXCEPTION 'MISSING_PHONE' USING ERRCODE = 'P0001';
  END IF;
  IF p_service IS NULL OR btrim(p_service) = '' THEN
    RAISE EXCEPTION 'MISSING_SERVICE' USING ERRCODE = 'P0001';
  END IF;
  IF p_requested_date IS NULL THEN
    RAISE EXCEPTION 'MISSING_DATE' USING ERRCODE = 'P0001';
  END IF;
  IF p_requested_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'DATE_IN_PAST' USING ERRCODE = 'P0001';
  END IF;

  -- Serialize every writer touching this date — same advisory lock key
  -- as book_maintenance_visit()/admin_reschedule_maintenance_visit(), so
  -- a guest booking and a member's maintenance booking for the same
  -- date can never race each other either. Must be taken before either
  -- availability read below.
  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

  -- Plain SELECT COUNT(*) — no FOR UPDATE (COUNT(*) ... FOR UPDATE is
  -- the invalid pattern that raised ERROR 0A000). The advisory lock
  -- above makes this read safe against concurrent writers for this date.
  SELECT COUNT(*) INTO v_existing_service_count
  FROM public.one_time_bookings
  WHERE requested_date = p_requested_date AND status = 'confirmed';

  IF v_existing_service_count > 0 THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  -- Plain SELECT EXISTS — no FOR UPDATE, same reasoning as above.
  SELECT EXISTS (
    SELECT 1
    FROM public.bookings
    WHERE COALESCE(confirmed_date, requested_date) = p_requested_date
      AND status IN ('confirmed', 'rescheduled_by_admin')
  ) INTO v_maintenance_exists;

  IF v_maintenance_exists THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.one_time_bookings (
    customer_name, customer_phone, service, vehicle_type, vehicle_model,
    seat_material, addons, service_address, requested_date, requested_time,
    notes, calculated_price, status
  ) VALUES (
    p_customer_name, p_customer_phone, p_service, p_vehicle_type, p_vehicle_model,
    p_seat_material, p_addons, p_service_address, p_requested_date, p_requested_time,
    p_notes, p_calculated_price, 'confirmed'
  )
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_one_time_service(
  text, text, text, text, text, text, text[], text, date, text, text, numeric
) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 8 — Subscriptions default status
--
-- New enrollments now insert status = 'active' directly from the
-- frontend (see js/dashboard.js), so this only updates the column
-- default for consistency/defensiveness — it does not change any
-- existing row, and the old 'pending_confirmation' default is no
-- longer used for new inserts.
-- ---------------------------------------------------------

ALTER TABLE public.subscriptions ALTER COLUMN status SET DEFAULT 'active';

-- ---------------------------------------------------------
-- Notes
--
-- * Historical rows with status = 'pending' (bookings) or
--   'pending_confirmation' (subscriptions) are left untouched. Only
--   NEW rows use the automatic flow.
-- * get_booked_maintenance_dates() from the earlier migration is left
--   in place (harmless, unused by the new frontend code) rather than
--   dropped, per "don't delete blindly" — it can be removed later once
--   confirmed nothing references it.
-- * This migration was NOT executed against any database by the
--   assistant. Review and run it via the Supabase SQL editor or CLI.
-- =========================================================
