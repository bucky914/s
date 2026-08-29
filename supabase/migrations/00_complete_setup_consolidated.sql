-- =========================================================
-- COMPLETE, CONSOLIDATED SETUP — run this ONE file on any
-- Just Detail Supabase project to bring it fully up to date.
--
-- This replaces running the 8 incremental migration files in
-- order. It contains the final, authoritative version of
-- every table/index/function/trigger/cron job across all of
-- them combined. Every statement uses IF NOT EXISTS / IF
-- EXISTS / CREATE OR REPLACE, so it is safe to run on:
--   - a fresh database that only has the original schema
--   - a database that already has some of the older
--     migrations applied (nothing is duplicated or reverted)
--   - a database that already has this exact file applied
--     (re-running it is a no-op)
--
-- Does NOT drop any table, does NOT delete/truncate any row.
-- The only DROP statements are for two obsolete indexes (see
-- STEP 1) and a re-created trigger (DROP TRIGGER IF EXISTS
-- immediately followed by CREATE TRIGGER, standard Postgres
-- pattern for making a trigger definition idempotent).
-- =========================================================

-- ---------------------------------------------------------
-- STEP 1 — Drop the old whole-date-only maintenance uniqueness
-- indexes. These enforced "one active maintenance booking per
-- date" with no time component, which is incompatible with
-- multiple non-overlapping 4-hour bookings sharing a date.
-- Real overlap protection now lives inside book_maintenance_visit()
-- via a transaction-level advisory lock (see STEP 8).
-- ---------------------------------------------------------

DROP INDEX IF EXISTS public.bookings_one_active_date_idx;
DROP INDEX IF EXISTS public.bookings_one_active_confirmed_date_idx;

-- ---------------------------------------------------------
-- STEP 2 — one_time_bookings.status column
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
-- STEP 3 — Indexes for availability queries
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
-- STEP 4 — membership_maintenance_schedule table
-- ---------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.membership_maintenance_schedule (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id uuid NOT NULL REFERENCES public.subscriptions(id),
  sequence_number integer NOT NULL, -- 0 = Deep Clean, 1..N = regular visits
  scheduled_date date NOT NULL,
  scheduled_time text,
  service_type text NOT NULL DEFAULT 'maintenance_wash', -- 'deep_clean' | 'maintenance_wash'
  status text NOT NULL DEFAULT 'scheduled', -- scheduled | booked | completed | skipped | cancelled
  booking_id uuid REFERENCES public.bookings(id), -- set once this occurrence is actually booked
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'membership_schedule_status_check'
  ) THEN
    ALTER TABLE public.membership_maintenance_schedule
      ADD CONSTRAINT membership_schedule_status_check
      CHECK (status IN ('scheduled', 'booked', 'completed', 'skipped', 'cancelled'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'membership_schedule_service_type_check'
  ) THEN
    ALTER TABLE public.membership_maintenance_schedule
      ADD CONSTRAINT membership_schedule_service_type_check
      CHECK (service_type IN ('deep_clean', 'maintenance_wash'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'membership_schedule_unique_sequence'
  ) THEN
    ALTER TABLE public.membership_maintenance_schedule
      ADD CONSTRAINT membership_schedule_unique_sequence
      UNIQUE (subscription_id, sequence_number);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS membership_schedule_subscription_idx
  ON public.membership_maintenance_schedule (subscription_id, sequence_number);

CREATE INDEX IF NOT EXISTS membership_schedule_status_idx
  ON public.membership_maintenance_schedule (status);

-- RLS: readable by the owning client and any admin; writes only via
-- SECURITY DEFINER RPCs (no direct client insert/update policy needed).
ALTER TABLE public.membership_maintenance_schedule ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'membership_maintenance_schedule'
      AND policyname = 'schedule_select_own_or_admin'
  ) THEN
    CREATE POLICY schedule_select_own_or_admin ON public.membership_maintenance_schedule
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1 FROM public.subscriptions s
          WHERE s.id = membership_maintenance_schedule.subscription_id
            AND (s.client_id = auth.uid() OR EXISTS (SELECT 1 FROM public.admin_users a WHERE a.id = auth.uid()))
        )
      );
  END IF;
END $$;

GRANT SELECT ON public.membership_maintenance_schedule TO authenticated;

-- ---------------------------------------------------------
-- STEP 5 — payments RLS: client can read their own subscription's
-- payment rows (needed for the dashboard's payment-pending banner).
-- ---------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'payments' AND policyname = 'payments_select_own_subscription'
  ) THEN
    CREATE POLICY payments_select_own_subscription ON public.payments
      FOR SELECT
      USING (
        subscription_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.subscriptions s
          WHERE s.id = payments.subscription_id AND s.client_id = auth.uid()
        )
      );
  END IF;
END $$;

-- ---------------------------------------------------------
-- STEP 6 — time_label_to_minutes(text) helper
-- Parses labels like '1:00 PM' into minutes since midnight.
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
-- STEP 7 — get_business_hours(): maintenance window, 7 AM-7 PM
-- default fallback, capped by business_settings.working_hours
-- if that's set and tighter.
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
    o_min := 7 * 60;   -- 7:00 AM fallback (was 8:00 AM)
    c_min := 19 * 60;  -- 7:00 PM fallback (was 6:00 PM)
  END IF;

  RETURN QUERY SELECT o_min, c_min;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_business_hours() TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 8 — get_service_hours(): guest-service window, 7 AM-3 PM
-- default. Uses an explicit alias (t.open_minutes/t.close_minutes)
-- on the inner get_business_hours() call — an earlier version
-- without this alias caused ERROR 42702 (ambiguous column
-- reference) because this function's own OUT parameters share
-- the same names (open_minutes/close_minutes).
-- ---------------------------------------------------------


CREATE OR REPLACE FUNCTION public.get_service_hours()
RETURNS TABLE (open_minutes integer, close_minutes integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_biz_open integer;
  v_biz_close integer;
  o_min integer := 7 * 60;
  c_min integer := 15 * 60;
BEGIN
  SELECT t.open_minutes, t.close_minutes
  INTO v_biz_open, v_biz_close
  FROM public.get_business_hours() AS t;

  IF v_biz_open IS NOT NULL AND v_biz_open > o_min THEN
    o_min := v_biz_open;
  END IF;
  IF v_biz_close IS NOT NULL AND v_biz_close < c_min THEN
    c_min := v_biz_close;
  END IF;

  IF c_min <= o_min THEN
    o_min := 7 * 60;
    c_min := 15 * 60;
  END IF;

  RETURN QUERY SELECT o_min, c_min;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_service_hours() TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 9 — date_has_deep_clean(date): true if a confirmed Deep
-- Clean booking exists that date. A Deep Clean takes a full day
-- to complete, so it blocks the ENTIRE day the same way a
-- confirmed one-time service does — for other Deep Cleans, for
-- guest one-time bookings, and for regular maintenance visits.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.date_has_deep_clean(p_date date)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.bookings
    WHERE COALESCE(confirmed_date, requested_date) = p_date
      AND visit_type = 'deep_clean'
      AND status IN ('confirmed', 'rescheduled_by_admin')
  );
$$;

GRANT EXECUTE ON FUNCTION public.date_has_deep_clean(date) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 10 — get_booking_availability(date): the calendar's
-- source of truth. Returns full-day availability plus the
-- 4-hour-slot maintenance list and the 7 AM-3 PM guest-service
-- list for a given date. A date is fully_unavailable when a
-- confirmed one-time service OR a confirmed Deep Clean exists
-- that day, or every maintenance slot is otherwise taken.
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
  v_svc_open_min integer;
  v_svc_close_min integer;
  v_maintenance_duration integer := 240;
  v_slot_labels text[] := ARRAY['7:00 AM','8:00 AM','9:00 AM','10:00 AM','11:00 AM','12:00 PM','1:00 PM','2:00 PM','3:00 PM','4:00 PM','5:00 PM','6:00 PM','7:00 PM'];
  v_service_slot_labels text[] := ARRAY['7:00 AM','8:00 AM','9:00 AM','10:00 AM','11:00 AM','12:00 PM','1:00 PM','2:00 PM','3:00 PM'];
  v_available_times text[] := '{}';
  v_available_service_times text[] := '{}';
  v_label text;
  v_start_min integer;
  v_end_min integer;
  v_conflict boolean;
  v_intervals int[][];
  i integer;
BEGIN
  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  SELECT open_minutes, close_minutes INTO v_svc_open_min, v_svc_close_min FROM public.get_service_hours();

  -- A confirmed one-time service OR a confirmed Deep Clean blocks the
  -- whole day for both maintenance and further guest/service bookings.
  v_service_booked := (
    EXISTS (
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = p_date AND status = 'confirmed'
    )
    OR public.date_has_deep_clean(p_date)
  );

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

      IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
        v_conflict := true;
      END IF;

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

    FOREACH v_label IN ARRAY v_service_slot_labels LOOP
      v_start_min := public.time_label_to_minutes(v_label);
      IF v_start_min >= v_svc_open_min AND v_start_min <= v_svc_close_min THEN
        v_available_service_times := array_append(v_available_service_times, v_label);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'date', p_date,
    'fully_unavailable', v_service_booked OR (array_length(v_available_times, 1) IS NULL OR array_length(v_available_times, 1) = 0),
    'service_booked', v_service_booked,
    'maintenance_bookings', v_maintenance,
    'available_maintenance_times', to_jsonb(v_available_times),
    'available_service_times', to_jsonb(v_available_service_times)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_booking_availability(date) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 11 — book_maintenance_visit(...): atomic, auth.uid()-
-- scoped maintenance booking RPC. Enforces business hours, the
-- 4-hour overlap rule, the one-time-service/Deep-Clean whole-day
-- block, and links the booking to the earliest still-'scheduled'
-- occurrence in membership_maintenance_schedule (so booking early
-- consumes that occurrence instead of creating a duplicate).
-- Concurrency-safe via pg_advisory_xact_lock (never FOR UPDATE
-- on an aggregate/EXISTS result, which raises ERROR 0A000).
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
  v_schedule_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF p_requested_date IS NULL THEN
    RAISE EXCEPTION 'MISSING_DATE' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

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

  -- A confirmed one-time service OR a confirmed Deep Clean on this date
  -- blocks all other maintenance.
  v_service_booked := (
    EXISTS (
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = p_requested_date AND status = 'confirmed'
    )
    OR public.date_has_deep_clean(p_requested_date)
  );

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

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

  SELECT id INTO v_schedule_id
  FROM public.membership_maintenance_schedule
  WHERE subscription_id = p_subscription_id
    AND sequence_number >= 1
    AND status = 'scheduled'
  ORDER BY sequence_number ASC
  LIMIT 1;

  IF v_schedule_id IS NOT NULL THEN
    UPDATE public.membership_maintenance_schedule
    SET status = 'booked',
        booking_id = v_booking.id,
        scheduled_date = p_requested_date,
        scheduled_time = p_requested_time,
        updated_at = now()
    WHERE id = v_schedule_id;
  END IF;

  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_maintenance_visit(uuid, date, text) TO authenticated;

-- ---------------------------------------------------------
-- STEP 12 — admin_reschedule_maintenance_visit(...): same rules
-- as book_maintenance_visit(), restricted to admins, excludes
-- the booking's own current slot from its own conflict check.
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

  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_new_date::text));

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

  v_service_booked := (
    EXISTS (
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = p_new_date AND status = 'confirmed'
    )
    OR public.date_has_deep_clean(p_new_date)
  );

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

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
-- STEP 13 — book_membership(...): creates the subscription
-- (status = 'active' immediately, no admin approval), one
-- pending payments row (admin confirms it separately — see
-- STEP 15/16), books the Deep Clean as a real conflict-checked,
-- WHOLE-DAY-blocking booking, and generates the rest of the
-- expected maintenance schedule from the chosen frequency.
-- No payment method is collected from the customer.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.book_membership(
  p_plan_id uuid,
  p_vehicle_model text,
  p_frequency text,
  p_service_address text,
  p_deep_clean_date date,
  p_deep_clean_time text
)
RETURNS public.subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan public.plans;
  v_sub public.subscriptions;
  v_open_min integer;
  v_close_min integer;
  v_start_min integer;
  v_end_min integer;
  v_duration integer := 240;
  v_service_booked boolean;
  v_conflict_count integer;
  v_deep_clean_booking public.bookings;
  v_interval_days integer;
  v_next_date date;
  v_seq integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'MISSING_PLAN' USING ERRCODE = 'P0001';
  END IF;
  IF p_vehicle_model IS NULL OR btrim(p_vehicle_model) = '' THEN
    RAISE EXCEPTION 'MISSING_VEHICLE' USING ERRCODE = 'P0001';
  END IF;
  IF p_frequency IS NULL OR btrim(p_frequency) = '' THEN
    RAISE EXCEPTION 'MISSING_FREQUENCY' USING ERRCODE = 'P0001';
  END IF;
  IF p_service_address IS NULL OR btrim(p_service_address) = '' THEN
    RAISE EXCEPTION 'MISSING_ADDRESS' USING ERRCODE = 'P0001';
  END IF;
  IF p_deep_clean_date IS NULL THEN
    RAISE EXCEPTION 'MISSING_DATE' USING ERRCODE = 'P0001';
  END IF;
  IF p_deep_clean_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'DATE_IN_PAST' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_plan FROM public.plans WHERE id = p_plan_id AND active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PLAN_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (p_frequency = ANY(v_plan.frequency_options)) THEN
    RAISE EXCEPTION 'INVALID_FREQUENCY' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_deep_clean_date::text));

  v_start_min := public.time_label_to_minutes(p_deep_clean_time);
  v_end_min := v_start_min + v_duration;

  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_BUSINESS_HOURS' USING ERRCODE = 'P0001';
  END IF;

  -- A confirmed one-time service OR an existing confirmed Deep Clean
  -- blocks this date from hosting another Deep Clean too.
  v_service_booked := (
    EXISTS (
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = p_deep_clean_date AND status = 'confirmed'
    )
    OR public.date_has_deep_clean(p_deep_clean_date)
  );

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  SELECT COUNT(*) INTO v_conflict_count
  FROM public.bookings
  WHERE COALESCE(confirmed_date, requested_date) = p_deep_clean_date
    AND status IN ('confirmed', 'rescheduled_by_admin')
    AND NOT (
      v_start_min >= (public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration)
      OR v_end_min <= public.time_label_to_minutes(COALESCE(confirmed_time, requested_time))
    );

  IF v_conflict_count > 0 THEN
    RAISE EXCEPTION 'SLOT_CONFLICT' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.subscriptions (
    client_id, plan_id, vehicle_model, vehicle_segment, frequency,
    washes_remaining, washes_used, bonus_perk_used, mid_year_reset_used,
    service_address, status, start_date
  ) VALUES (
    auth.uid(), v_plan.id, p_vehicle_model, v_plan.vehicle_segment, p_frequency,
    v_plan.total_regular_washes, 0, false, false,
    p_service_address, 'active', CURRENT_DATE
  )
  RETURNING * INTO v_sub;

  IF v_plan.price > 0 THEN
    INSERT INTO public.payments (
      subscription_id, amount, payment_method, payment_status, notes
    ) VALUES (
      v_sub.id, v_plan.price, 'pending', 'pending',
      'Awaiting admin payment confirmation for membership enrollment.'
    );
  END IF;

  INSERT INTO public.bookings (
    subscription_id, visit_type, requested_date, requested_time, status
  ) VALUES (
    v_sub.id, 'deep_clean', p_deep_clean_date, p_deep_clean_time, 'confirmed'
  )
  RETURNING * INTO v_deep_clean_booking;

  INSERT INTO public.membership_maintenance_schedule (
    subscription_id, sequence_number, scheduled_date, scheduled_time,
    service_type, status, booking_id
  ) VALUES (
    v_sub.id, 0, p_deep_clean_date, p_deep_clean_time,
    'deep_clean', 'booked', v_deep_clean_booking.id
  );

  v_interval_days := CASE
    WHEN p_frequency = 'biweekly' THEN 15
    WHEN p_frequency = 'monthly' THEN 30
    ELSE 30
  END;

  v_next_date := p_deep_clean_date;
  FOR v_seq IN 1 .. GREATEST(v_plan.total_regular_washes, 0) LOOP
    v_next_date := v_next_date + v_interval_days;
    INSERT INTO public.membership_maintenance_schedule (
      subscription_id, sequence_number, scheduled_date, scheduled_time,
      service_type, status
    ) VALUES (
      v_sub.id, v_seq, v_next_date, p_deep_clean_time,
      'maintenance_wash', 'scheduled'
    );
  END LOOP;

  RETURN v_sub;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_membership(uuid, text, text, text, date, text) TO authenticated;

-- ---------------------------------------------------------
-- STEP 14 — book_one_time_service(...): atomic guest-booking
-- RPC. Rejects the booking if EITHER a confirmed one-time
-- service already exists that date, OR any confirmed maintenance
-- booking exists that date (this already includes Deep Clean
-- bookings, since it checks status regardless of visit_type) —
-- this is what makes a Deep Clean correctly block new guest
-- bookings on the same date. Creates a pending payments row
-- alongside the booking; admin confirms it separately.
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
  v_svc_open_min integer;
  v_svc_close_min integer;
  v_start_min integer;
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

  IF p_requested_time IS NULL OR btrim(p_requested_time) = '' THEN
    RAISE EXCEPTION 'MISSING_TIME' USING ERRCODE = 'P0001';
  END IF;

  SELECT open_minutes, close_minutes INTO v_svc_open_min, v_svc_close_min FROM public.get_service_hours();
  v_start_min := public.time_label_to_minutes(p_requested_time);
  IF v_start_min < v_svc_open_min OR v_start_min > v_svc_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_SERVICE_HOURS' USING ERRCODE = 'P0001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

  SELECT COUNT(*) INTO v_existing_service_count
  FROM public.one_time_bookings
  WHERE requested_date = p_requested_date AND status = 'confirmed';

  IF v_existing_service_count > 0 THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

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

  -- Payment stays PENDING until admin confirms it (see
  -- admin_confirm_onetime_payment() above) — the booking itself still
  -- confirms and blocks the date immediately regardless of payment.
  IF p_calculated_price IS NOT NULL AND p_calculated_price > 0 THEN
    INSERT INTO public.payments (
      one_time_booking_id, amount, payment_method, payment_status, notes
    ) VALUES (
      v_booking.id, p_calculated_price, 'pending', 'pending',
      'Awaiting admin payment confirmation for one-time booking.'
    );
  END IF;

  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_one_time_service(
  text, text, text, text, text, text, text[], text, date, text, text, numeric
) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 15 — admin_confirm_subscription_payment(...): the ONLY
-- way a subscription's pending membership payment becomes 'paid'.
-- Idempotent — a second call on an already-paid subscription
-- raises ALREADY_PAID rather than creating a duplicate payment.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_confirm_subscription_payment(
  p_subscription_id uuid,
  p_payment_method text,
  p_payment_date date
)
RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment public.payments;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid()) THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED' USING ERRCODE = '42501';
  END IF;

  IF p_payment_method IS NULL OR btrim(p_payment_method) = '' THEN
    RAISE EXCEPTION 'MISSING_PAYMENT_METHOD' USING ERRCODE = 'P0001';
  END IF;

  -- Single-row target by subscription_id + status — FOR UPDATE is valid
  -- here (not an aggregate/EXISTS result); locks this specific pending
  -- payment against a concurrent double-click confirming it twice.
  SELECT * INTO v_payment
  FROM public.payments
  WHERE subscription_id = p_subscription_id AND payment_status = 'pending'
  ORDER BY created_at ASC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Distinguish "already paid" from "no membership payment exists at
    -- all" so the frontend can show the right message either way.
    IF EXISTS (SELECT 1 FROM public.payments WHERE subscription_id = p_subscription_id AND payment_status = 'paid') THEN
      RAISE EXCEPTION 'ALREADY_PAID' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'NO_PENDING_PAYMENT' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.payments
  SET payment_status = 'paid',
      payment_method = p_payment_method,
      payment_date = COALESCE(p_payment_date, CURRENT_DATE)
  WHERE id = v_payment.id
  RETURNING * INTO v_payment;

  RETURN v_payment;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_confirm_subscription_payment(uuid, text, date) TO authenticated;

-- ---------------------------------------------------------
-- STEP 16 — admin_confirm_onetime_payment(...): same idempotent
-- pattern for one_time_bookings.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_confirm_onetime_payment(
  p_one_time_booking_id uuid,
  p_payment_method text,
  p_payment_date date
)
RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment public.payments;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.admin_users WHERE id = auth.uid()) THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED' USING ERRCODE = '42501';
  END IF;

  IF p_payment_method IS NULL OR btrim(p_payment_method) = '' THEN
    RAISE EXCEPTION 'MISSING_PAYMENT_METHOD' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_payment
  FROM public.payments
  WHERE one_time_booking_id = p_one_time_booking_id AND payment_status = 'pending'
  ORDER BY created_at ASC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (SELECT 1 FROM public.payments WHERE one_time_booking_id = p_one_time_booking_id AND payment_status = 'paid') THEN
      RAISE EXCEPTION 'ALREADY_PAID' USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'NO_PENDING_PAYMENT' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.payments
  SET payment_status = 'paid',
      payment_method = p_payment_method,
      payment_date = COALESCE(p_payment_date, CURRENT_DATE)
  WHERE id = v_payment.id
  RETURNING * INTO v_payment;

  RETURN v_payment;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_confirm_onetime_payment(uuid, text, date) TO authenticated;

-- ---------------------------------------------------------
-- STEP 17 — Trigger: keep membership_maintenance_schedule in sync
-- when a linked booking's status changes later (completed,
-- cancelled, or rescheduled by admin).
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sync_schedule_on_booking_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'completed' AND (OLD.status IS DISTINCT FROM 'completed') THEN
    UPDATE public.membership_maintenance_schedule
    SET status = 'completed', updated_at = now()
    WHERE booking_id = NEW.id;
  ELSIF NEW.status = 'cancelled' AND (OLD.status IS DISTINCT FROM 'cancelled') THEN
    UPDATE public.membership_maintenance_schedule
    SET status = 'scheduled', booking_id = NULL, updated_at = now()
    WHERE booking_id = NEW.id;
  ELSIF (NEW.confirmed_date IS DISTINCT FROM OLD.confirmed_date)
     OR (NEW.confirmed_time IS DISTINCT FROM OLD.confirmed_time) THEN
    UPDATE public.membership_maintenance_schedule
    SET scheduled_date = COALESCE(NEW.confirmed_date, NEW.requested_date),
        scheduled_time = COALESCE(NEW.confirmed_time, NEW.requested_time),
        updated_at = now()
    WHERE booking_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_schedule_on_booking_change ON public.bookings;
CREATE TRIGGER trg_sync_schedule_on_booking_change
AFTER UPDATE ON public.bookings
FOR EACH ROW
EXECUTE FUNCTION public.sync_schedule_on_booking_change();


-- ---------------------------------------------------------
-- STEP 18 — auto_book_due_maintenance(): daily job. Books any
-- schedule row whose date has arrived with nothing booked yet,
-- re-validating the same rules as a normal customer booking
-- (including the Deep-Clean/one-time-service whole-day block).
-- If a slot is unavailable, defers one day and retries — never
-- silently drops an occurrence.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.auto_book_due_maintenance()
RETURNS TABLE (schedule_id uuid, subscription_id uuid, result text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row record;
  v_sub public.subscriptions;
  v_open_min integer;
  v_close_min integer;
  v_start_min integer;
  v_end_min integer;
  v_duration integer := 240;
  v_service_booked boolean;
  v_conflict_count integer;
  v_booking public.bookings;
  v_time text;
BEGIN
  FOR v_row IN
    SELECT * FROM public.membership_maintenance_schedule
    WHERE status = 'scheduled'
      AND sequence_number >= 1
      AND scheduled_date <= CURRENT_DATE
    ORDER BY scheduled_date ASC
  LOOP
    schedule_id := v_row.id;
    subscription_id := v_row.subscription_id;

    SELECT * INTO v_sub FROM public.subscriptions WHERE id = v_row.subscription_id;

    IF NOT FOUND OR v_sub.status <> 'active' THEN
      result := 'skipped: subscription not active';
      RETURN NEXT;
      CONTINUE;
    END IF;

    IF v_sub.washes_remaining <= 0 THEN
      result := 'skipped: no washes remaining';
      RETURN NEXT;
      CONTINUE;
    END IF;

    v_time := COALESCE(v_row.scheduled_time, '9:00 AM');

    PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || v_row.scheduled_date::text));

    v_start_min := public.time_label_to_minutes(v_time);
    v_end_min := v_start_min + v_duration;

    SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();

    IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
      UPDATE public.membership_maintenance_schedule
      SET scheduled_date = v_row.scheduled_date + 1, updated_at = now()
      WHERE id = v_row.id;
      result := 'deferred: time no longer fits business hours, retrying next day';
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- A confirmed one-time service OR a confirmed Deep Clean blocks
    -- this date.
    v_service_booked := (
      EXISTS (
        SELECT 1 FROM public.one_time_bookings
        WHERE requested_date = v_row.scheduled_date AND status = 'confirmed'
      )
      OR public.date_has_deep_clean(v_row.scheduled_date)
    );

    IF v_service_booked THEN
      UPDATE public.membership_maintenance_schedule
      SET scheduled_date = v_row.scheduled_date + 1, updated_at = now()
      WHERE id = v_row.id;
      result := 'deferred: date fully booked by a one-time service or deep clean, retrying next day';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT COUNT(*) INTO v_conflict_count
    FROM public.bookings
    WHERE COALESCE(confirmed_date, requested_date) = v_row.scheduled_date
      AND status IN ('confirmed', 'rescheduled_by_admin')
      AND NOT (
        v_start_min >= (public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration)
        OR v_end_min <= public.time_label_to_minutes(COALESCE(confirmed_time, requested_time))
      );

    IF v_conflict_count > 0 THEN
      UPDATE public.membership_maintenance_schedule
      SET scheduled_date = v_row.scheduled_date + 1, updated_at = now()
      WHERE id = v_row.id;
      result := 'deferred: slot conflict, retrying next day';
      RETURN NEXT;
      CONTINUE;
    END IF;

    INSERT INTO public.bookings (
      subscription_id, visit_type, requested_date, requested_time, status
    ) VALUES (
      v_row.subscription_id, 'maintenance_wash', v_row.scheduled_date, v_time, 'confirmed'
    )
    RETURNING * INTO v_booking;

    UPDATE public.membership_maintenance_schedule
    SET status = 'booked',
        booking_id = v_booking.id,
        scheduled_time = v_time,
        updated_at = now()
    WHERE id = v_row.id;

    result := 'booked automatically';
    RETURN NEXT;
  END LOOP;

  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.auto_book_due_maintenance() TO service_role;

-- ---------------------------------------------------------
-- STEP 19 — Schedule auto_book_due_maintenance() to run daily.
-- Requires the pg_cron extension (available on Supabase, not
-- enabled by default). If this errors on your project/plan,
-- skip it and call the function from an external daily job
-- instead — everything else in this file still applies fine.
-- ---------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove any previous schedule with this name first so re-running this
-- migration doesn't create a duplicate daily job.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'auto-book-due-maintenance') THEN
    PERFORM cron.unschedule('auto-book-due-maintenance');
  END IF;
END $$;

-- Runs every day at 06:00 UTC — adjust the schedule string if you want
-- a different time (cron syntax: minute hour day month weekday).
SELECT cron.schedule(
  'auto-book-due-maintenance',
  '0 6 * * *',
  $$SELECT public.auto_book_due_maintenance();$$
);

-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- STEP 20 — Old 5-argument book_membership() overload cleanup
-- (optional). Earlier versions of book_membership() took a
-- payment method instead of a Deep Clean date/time. Both
-- overloads may exist side by side without conflict (PostgREST
-- resolves by argument names), but if you want to remove the
-- stale one, run this separately after confirming your frontend
-- only calls the 6-argument version:
--
--   DROP FUNCTION IF EXISTS public.book_membership(uuid, text, text, text, text);
-- ---------------------------------------------------------

-- =========================================================
-- Notes
--
-- * No DROP TABLE, TRUNCATE, or DELETE statements appear
--   anywhere in this file. Existing clients, subscriptions,
--   bookings, payments, and plans are all preserved untouched.
-- * Every writer function uses pg_advisory_xact_lock, never
--   FOR UPDATE on an aggregate/EXISTS result (that combination
--   is invalid PostgreSQL — ERROR 0A000).
-- * This file was NOT executed against any database by the
--   assistant. Review and run it via the Supabase SQL editor
--   or CLI.
-- =========================================================
