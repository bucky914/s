-- =========================================================
-- RUN THIS AFTER 00_complete_setup_consolidated.sql,
-- 01_maintenance_availability_authoritative_fix.sql, AND
-- 02_fix_maintenance_window_business_hours_override.sql.
--
-- BUSINESS RULE CHANGE (not a bug fix in the usual sense)
--
-- get_booking_availability()'s maintenance-slot loop rejected a start
-- time whenever start + 4h (the maintenance duration) fell after the
-- 7:00 PM close — i.e. it required the job to FINISH by 7 PM, not just
-- START by 7 PM. That silently removed 4 PM, 5 PM, 6 PM, and 7 PM from
-- the displayed/available maintenance start times, since a job started
-- at any of those times finishes after 7 PM.
--
-- The current requirement is that 7:00 AM-7:00 PM is the window of
-- valid maintenance START times — a booking rule, not a guarantee that
-- every booked job's own work finishes by the same clock time. This
-- migration changes ONLY that one bound: a maintenance start time is
-- now rejected solely for falling before 7 AM or after 7 PM, not for
-- extending past 7 PM once started.
--
-- The overlap check against existing confirmed bookings (both
-- public.bookings and non-Deep-Clean public.one_time_bookings) is
-- UNCHANGED — a 4 PM start still correctly conflicts with, say, an
-- existing 2 PM-6 PM booking, and still correctly still uses the full
-- 4-hour interval for that overlap math. Only the "must finish by
-- close" bound on the START-time cap is removed.
--
-- WHAT WAS CHANGED
--
-- 1. get_booking_availability(p_date): the maintenance-slot loop's
--    business-hours check changes from
--      v_start_min < v_open_min OR v_end_min > v_close_min
--    to
--      v_start_min < v_open_min OR v_start_min > v_close_min
--    The guest-service (Deep Clean) slot loop is untouched — it
--    already only checked v_start_min against get_service_hours(),
--    never v_end_min, so Deep Clean's 7 AM-3 PM window is unaffected.
--
-- 2. book_one_time_service(p_...): previously validated EVERY guest
--    one-time booking's requested time against get_service_hours()
--    (7 AM-3 PM) regardless of which service was being booked — a
--    guest Maintenance Wash booked for, say, 5 PM would have been
--    rejected with OUTSIDE_SERVICE_HOURS even though the availability
--    list (once fixed above) would show 5 PM as open. This function
--    now branches on is_deep_clean_service(p_service): Deep Clean
--    keeps validating against get_service_hours() (7 AM-3 PM, start
--    time only, as before); a Maintenance Wash now validates its
--    start time against get_business_hours() (7 AM-7 PM), matching
--    the same start-time-only rule as get_booking_availability()
--    above. The existing overlap/conflict logic in this function
--    (against public.bookings and other public.one_time_bookings) is
--    UNCHANGED — still uses the full 4-hour interval, still runs
--    inside the same pg_advisory_xact_lock, still the same
--    concurrency protection as before.
--
-- NOT CHANGED (deliberately out of scope for this migration) —
-- book_maintenance_visit(), admin_reschedule_maintenance_visit(),
-- book_membership(), auto_book_due_maintenance(): these are the
-- MEMBERSHIP-side booking RPCs, not mentioned in this request, and
-- still contain the old "must finish by close" bound
-- (v_end_min > v_close_min) inherited from
-- 01_maintenance_availability_authoritative_fix.sql. That means a
-- membership maintenance visit booked through the client dashboard
-- still cannot be scheduled to START after 3 PM, even though the
-- calendar it reads its availability from (get_booking_availability())
-- will now show 4 PM-7 PM as open for guest bookings. This is a real
-- inconsistency between the guest and membership booking paths — if
-- membership visits should follow the same 7 AM-7 PM start-time rule,
-- that requires a follow-up migration touching those four functions
-- explicitly, since this request scoped the fix to
-- get_booking_availability() and book_one_time_service() only.
--
-- CREATE OR REPLACE only. No signature change on either function. No
-- table touched, no data deleted. Concurrency protection
-- (pg_advisory_xact_lock in book_one_time_service()) is unchanged.
-- =========================================================

-- ---------------------------------------------------------
-- STEP 1 — get_booking_availability(date): maintenance start-time
-- bound changed from "must finish by close" to "must start by close".
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

  -- Whole-day block now happens ONLY for a confirmed Deep Clean
  -- (guest or membership) — a Maintenance Wash, guest or membership,
  -- is a normal 4-hour interval like any other.
  v_service_booked := public.date_has_deep_clean(p_date);

  -- Occupied 4-hour intervals: confirmed/rescheduled maintenance
  -- bookings (public.bookings) UNION confirmed non-Deep-Clean guest
  -- one-time bookings (public.one_time_bookings). Both sides use the
  -- same 4-hour duration and the same [start, end) interval semantics.
  -- This interval math is unchanged by this migration — only the
  -- business-hours BOUND on candidate start times (below) changes.
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

    UNION ALL

    SELECT
      public.time_label_to_minutes(requested_time) AS start_min,
      public.time_label_to_minutes(requested_time) + v_maintenance_duration AS end_min
    FROM public.one_time_bookings
    WHERE requested_date = p_date
      AND status = 'confirmed'
      AND NOT public.is_deep_clean_service(service)
  ) b;

  IF v_intervals IS NULL THEN
    v_intervals := ARRAY[]::int[][];
  END IF;

  IF NOT v_service_booked THEN
    FOREACH v_label IN ARRAY v_slot_labels LOOP
      v_start_min := public.time_label_to_minutes(v_label);
      v_end_min := v_start_min + v_maintenance_duration;

      v_conflict := false;

      -- CHANGED: a maintenance start time is only rejected for falling
      -- before open or after close — NOT for the job's own 4-hour
      -- duration extending past close. Previously this compared
      -- v_end_min > v_close_min, which silently removed every start
      -- time from 4 PM onward. The overlap check just below (which
      -- still uses the full v_start_min/v_end_min interval) is what
      -- correctly rejects a start time that would collide with an
      -- existing booking — that logic is untouched.
      IF v_start_min < v_open_min OR v_start_min > v_close_min THEN
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

    -- Guest-service (Deep Clean) start times — UNCHANGED by this
    -- migration. This loop already only bounded v_start_min against
    -- get_service_hours() (7 AM-3 PM), never v_end_min, so Deep Clean
    -- was never affected by the maintenance bug fixed above.
    FOREACH v_label IN ARRAY v_service_slot_labels LOOP
      v_start_min := public.time_label_to_minutes(v_label);
      v_end_min := v_start_min + v_maintenance_duration;
      v_conflict := false;

      IF v_start_min < v_svc_open_min OR v_start_min > v_svc_close_min THEN
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
-- STEP 2 — book_one_time_service(...): validate the requested time
-- against the RIGHT window for the service being booked (Deep Clean:
-- get_service_hours(), 7 AM-3 PM; Maintenance Wash: get_business_hours(),
-- 7 AM-7 PM, start-time only) instead of always checking
-- get_service_hours() regardless of service. Overlap/conflict logic
-- and locking are unchanged.
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
  v_is_deep_clean boolean;
  v_svc_open_min integer;
  v_svc_close_min integer;
  v_start_min integer;
  v_end_min integer;
  v_duration integer := 240;
  v_date_has_deep_clean boolean;
  v_conflict_count integer;
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

  v_is_deep_clean := public.is_deep_clean_service(p_service);
  v_start_min := public.time_label_to_minutes(p_requested_time);

  -- CHANGED: which window validates the requested start time now
  -- depends on the service being booked, instead of always using
  -- get_service_hours() (7 AM-3 PM) even for a Maintenance Wash.
  IF v_is_deep_clean THEN
    SELECT open_minutes, close_minutes INTO v_svc_open_min, v_svc_close_min FROM public.get_service_hours();
  ELSE
    SELECT open_minutes, close_minutes INTO v_svc_open_min, v_svc_close_min FROM public.get_business_hours();
  END IF;

  IF v_start_min < v_svc_open_min OR v_start_min > v_svc_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_SERVICE_HOURS' USING ERRCODE = 'P0001';
  END IF;

  v_end_min := v_start_min + v_duration;

  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

  -- An existing confirmed Deep Clean (guest or membership) always
  -- blocks the whole day, regardless of what's being booked now.
  v_date_has_deep_clean := public.date_has_deep_clean(p_requested_date);
  IF v_date_has_deep_clean THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  IF v_is_deep_clean THEN
    -- Booking a NEW Deep Clean requires the date to be otherwise
    -- completely free — any existing confirmed maintenance activity
    -- (guest or membership) blocks it, the same way an existing Deep
    -- Clean blocks a new maintenance booking elsewhere in the system.
    SELECT COUNT(*) INTO v_conflict_count
    FROM (
      SELECT 1 FROM public.bookings
      WHERE COALESCE(confirmed_date, requested_date) = p_requested_date
        AND status IN ('confirmed', 'rescheduled_by_admin')
      UNION ALL
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = p_requested_date AND status = 'confirmed'
    ) x;

    IF v_conflict_count > 0 THEN
      RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- Non-Deep-Clean guest booking (Maintenance Wash): reject only on
    -- a genuine 4-hour overlap against other confirmed maintenance
    -- activity that day — same interval rule as book_maintenance_visit().
    -- UNCHANGED: still the full 4-hour [start, end) overlap check.
    SELECT COUNT(*) INTO v_conflict_count
    FROM (
      SELECT
        public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) AS s,
        public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration AS e
      FROM public.bookings
      WHERE COALESCE(confirmed_date, requested_date) = p_requested_date
        AND status IN ('confirmed', 'rescheduled_by_admin')
      UNION ALL
      SELECT
        public.time_label_to_minutes(requested_time) AS s,
        public.time_label_to_minutes(requested_time) + v_duration AS e
      FROM public.one_time_bookings
      WHERE requested_date = p_requested_date
        AND status = 'confirmed'
        AND NOT public.is_deep_clean_service(service)
    ) x
    WHERE NOT (v_start_min >= x.e OR v_end_min <= x.s);

    IF v_conflict_count > 0 THEN
      RAISE EXCEPTION 'SLOT_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
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
-- Notes
--
-- * No DROP, no TRUNCATE, no DELETE anywhere in this migration.
--   Existing bookings, one_time_bookings, and payments are untouched.
-- * pg_advisory_xact_lock concurrency protection in
--   book_one_time_service() is unchanged — still acquired before the
--   conflict checks, still released automatically at transaction end.
-- * This migration has NOT been executed against any database by the
--   assistant. Run it via the Supabase SQL editor or CLI, after
--   00_complete_setup_consolidated.sql,
--   01_maintenance_availability_authoritative_fix.sql, and
--   02_fix_maintenance_window_business_hours_override.sql have all
--   been applied.
-- =========================================================
