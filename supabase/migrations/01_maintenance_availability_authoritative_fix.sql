-- =========================================================
-- RUN THIS AFTER 00_complete_setup_consolidated.sql.
--
-- 00_complete_setup_consolidated.sql's header describes itself as
-- the final, authoritative version of every function — but it does
-- NOT contain the fix below. This file is the authoritative layer
-- on top of it: every function it touches uses CREATE OR REPLACE,
-- so re-running this after (or instead of re-running) STEP 10/11/
-- 13/14/15 of the consolidated file brings the database to the
-- state actually required by the app.
--
-- Safe to run on a fresh DB that already has
-- 00_complete_setup_consolidated.sql applied, or re-run any number
-- of times. No DROP, no data touched.
-- =========================================================
--
-- Guest "Maintenance Wash" one-time bookings now take 4 hours, not the
-- whole day. Only "Deep Clean" one-time bookings still block the
-- entire day.
--
-- WHAT WAS WRONG
--
-- The guest booking form (index.html) actually offers THREE distinct
-- services: 'Deep Clean', 'Maintenance Wash (Exterior Only)', and
-- 'Maintenance Wash (Exterior + Interior)'. But book_one_time_service()
-- and get_booking_availability() treated every confirmed
-- one_time_bookings row identically as a whole-day block, with no
-- distinction by p_service/service at all, and no 4-hour interval
-- concept for one_time_bookings whatsoever.
--
-- Only a Deep Clean genuinely takes a full day to complete. A guest
-- Maintenance Wash — like a membership maintenance visit — takes 4
-- hours, and other maintenance (guest or membership) should be
-- bookable before and after it on the same day, exactly like two
-- membership visits already can be.
--
-- FIX
--
-- 1. public.is_deep_clean_service(text) — a small helper that decides
--    whether a service label is a Deep Clean (case-insensitive match
--    on 'deep clean'), so this isn't hardcoded to one exact string in
--    five different places.
--
-- 2. book_one_time_service(...): the whole-day block now only applies
--    when EITHER an existing confirmed one_time_bookings row for that
--    date is a Deep Clean, OR the NEW booking being created is itself
--    a Deep Clean (in which case it must reject a date that already
--    has ANY confirmed maintenance activity, guest or membership).
--    For a non-Deep-Clean guest booking, the function now computes its
--    4-hour interval and rejects only on a genuine overlap against
--    other confirmed maintenance activity that day (both bookings and
--    other one_time_bookings) — the same interval math already used
--    by book_maintenance_visit().
--
-- 3. get_booking_availability(p_date): 'fully_unavailable'/'service_booked'
--    now only reflect a confirmed Deep Clean (guest or, as before, a
--    membership Deep Clean booking). The maintenance-slot interval
--    list now also includes confirmed non-Deep-Clean one_time_bookings
--    rows as occupied 4-hour windows, so the membership calendar
--    correctly shows a slot as taken when a guest Maintenance Wash has
--    it, and vice versa via available_service_times.
--
-- 4. admin_reschedule_maintenance_visit(...): the day-blocking check it
--    already had against one_time_bookings now only fires for Deep
--    Clean rows, matching the above — a guest Maintenance Wash no
--    longer blocks an admin from rescheduling a membership visit onto
--    a non-overlapping time that same day.
--
-- 5. book_maintenance_visit(...) (the MEMBERSHIP booking RPC): had the
--    exact same stale bug — its whole-day check also treated ANY
--    confirmed one_time_bookings row as a full block, which would have
--    kept rejecting a membership visit on a day that only had a guest
--    Maintenance Wash, even after this fix let guest bookings share
--    the day. Now uses date_has_deep_clean() (Deep-Clean-only) for the
--    whole-day check, and its overlap query now also includes
--    confirmed non-Deep-Clean one_time_bookings intervals — so a
--    membership visit and a guest Maintenance Wash correctly see and
--    avoid each other's exact time window, not just share the day
--    blindly.
--
-- 6. book_membership(...) (the Deep Clean's own slot check) and
--    auto_book_due_maintenance() (the daily auto-book job): same fix
--    applied for consistency — both had the identical stale
--    unqualified one_time_bookings check.
--
-- date_has_deep_clean() (STEP 2 below) now checks BOTH public.bookings
-- (visit_type = 'deep_clean') AND public.one_time_bookings (a
-- confirmed row whose service is a Deep Clean) — previously it only
-- looked at public.bookings, so a guest Deep Clean booking wouldn't
-- have blocked a membership visit's whole-day check at all.
--
-- CREATE OR REPLACE only. No signature changes anywhere. No data
-- touched. Safe to re-run.

-- ---------------------------------------------------------
-- STEP 1 — is_deep_clean_service(text) helper
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_deep_clean_service(p_service text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_service IS NOT NULL AND lower(btrim(p_service)) LIKE 'deep clean%';
$$;

GRANT EXECUTE ON FUNCTION public.is_deep_clean_service(text) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 2 — date_has_deep_clean(date): now also checks confirmed guest
-- Deep Clean bookings in one_time_bookings, not just membership Deep
-- Clean rows in public.bookings.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.date_has_deep_clean(p_date date)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM public.bookings
      WHERE COALESCE(confirmed_date, requested_date) = p_date
        AND visit_type = 'deep_clean'
        AND status IN ('confirmed', 'rescheduled_by_admin')
    )
    OR EXISTS (
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = p_date
        AND status = 'confirmed'
        AND public.is_deep_clean_service(service)
    );
$$;

GRANT EXECUTE ON FUNCTION public.date_has_deep_clean(date) TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 3 — get_booking_availability(date): whole-day block is now
-- Deep-Clean-only (via the updated date_has_deep_clean() above); the
-- 4-hour interval list now also includes confirmed non-Deep-Clean
-- one_time_bookings, so a guest Maintenance Wash and a membership
-- visit correctly see and respect each other's time window.
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

    -- Guest-service start times now also need to avoid overlapping an
    -- existing 4-hour interval (previously this list was only capped
    -- by business hours, with no overlap check at all — harmless
    -- before, since every one-time booking blocked the whole day
    -- anyway, but now a Maintenance Wash guest slot must respect
    -- other bookings the same way a maintenance visit does).
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
-- STEP 4 — book_one_time_service(...): whole-day block now only
-- applies when the NEW booking is a Deep Clean (rejects any date with
-- existing confirmed maintenance activity), or an EXISTING confirmed
-- Deep Clean already occupies that date. A non-Deep-Clean booking
-- (Maintenance Wash, guest) now computes its own 4-hour interval and
-- is rejected only on genuine overlap — same interval math as
-- book_maintenance_visit(). Locking/concurrency strategy unchanged.
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

  SELECT open_minutes, close_minutes INTO v_svc_open_min, v_svc_close_min FROM public.get_service_hours();
  v_start_min := public.time_label_to_minutes(p_requested_time);
  IF v_start_min < v_svc_open_min OR v_start_min > v_svc_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_SERVICE_HOURS' USING ERRCODE = 'P0001';
  END IF;

  v_is_deep_clean := public.is_deep_clean_service(p_service);
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
-- STEP 5 — admin_reschedule_maintenance_visit(...): the whole-day
-- check against one_time_bookings now correctly routes through the
-- updated date_has_deep_clean() (Deep-Clean-only), instead of
-- treating every confirmed one_time_bookings row as a day block.
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

  v_service_booked := public.date_has_deep_clean(p_new_date);

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  SELECT COUNT(*) INTO v_conflict_count
  FROM (
    SELECT
      public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) AS s,
      public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration AS e
    FROM public.bookings
    WHERE id <> p_booking_id
      AND COALESCE(confirmed_date, requested_date) = p_new_date
      AND status IN ('confirmed', 'rescheduled_by_admin')
    UNION ALL
    SELECT
      public.time_label_to_minutes(requested_time) AS s,
      public.time_label_to_minutes(requested_time) + v_duration AS e
    FROM public.one_time_bookings
    WHERE requested_date = p_new_date
      AND status = 'confirmed'
      AND NOT public.is_deep_clean_service(service)
  ) x
  WHERE NOT (v_start_min >= x.e OR v_end_min <= x.s);

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
-- STEP 6 — book_maintenance_visit(...) (membership visit RPC): same
-- fix as book_one_time_service()/admin_reschedule_maintenance_visit()
-- above — whole-day check is now Deep-Clean-only, and the overlap
-- query now also includes confirmed non-Deep-Clean one_time_bookings
-- intervals, so a membership visit correctly sees and avoids a guest
-- Maintenance Wash's exact time window (and vice versa, via the
-- corresponding change in get_booking_availability()/
-- book_one_time_service() above).
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

  -- A confirmed Deep Clean (guest or membership) blocks the whole day.
  -- A confirmed guest Maintenance Wash is a normal 4-hour interval,
  -- handled by the overlap check below alongside membership bookings.
  v_service_booked := public.date_has_deep_clean(p_requested_date);

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

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
-- STEP 7 — book_membership(...): same fix for the Deep Clean's own
-- slot check. A new membership Deep Clean still requires the date to
-- be otherwise completely free of confirmed maintenance activity
-- (guest or membership), now checked correctly via a real union
-- instead of the stale unqualified one_time_bookings check.
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

  -- An existing confirmed Deep Clean (guest or membership) blocks this
  -- date entirely, since a NEW Deep Clean is itself a whole-day event.
  v_service_booked := public.date_has_deep_clean(p_deep_clean_date);

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  -- A new Deep Clean also requires the date to be free of ANY other
  -- confirmed maintenance activity (guest or membership) — checked as
  -- presence, not overlap, since the whole day is being claimed.
  SELECT COUNT(*) INTO v_conflict_count
  FROM (
    SELECT 1 FROM public.bookings
    WHERE COALESCE(confirmed_date, requested_date) = p_deep_clean_date
      AND status IN ('confirmed', 'rescheduled_by_admin')
    UNION ALL
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_deep_clean_date AND status = 'confirmed'
  ) x;

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
-- STEP 8 — auto_book_due_maintenance(): same fix as
-- book_maintenance_visit() above — this is the automatic version of
-- exactly that same booking, run daily for schedule occurrences whose
-- date has arrived.
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

    -- A confirmed Deep Clean (guest or membership) blocks this date.
    v_service_booked := public.date_has_deep_clean(v_row.scheduled_date);

    IF v_service_booked THEN
      UPDATE public.membership_maintenance_schedule
      SET scheduled_date = v_row.scheduled_date + 1, updated_at = now()
      WHERE id = v_row.id;
      result := 'deferred: date fully booked by a deep clean, retrying next day';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT COUNT(*) INTO v_conflict_count
    FROM (
      SELECT
        public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) AS s,
        public.time_label_to_minutes(COALESCE(confirmed_time, requested_time)) + v_duration AS e
      FROM public.bookings
      WHERE COALESCE(confirmed_date, requested_date) = v_row.scheduled_date
        AND status IN ('confirmed', 'rescheduled_by_admin')
      UNION ALL
      SELECT
        public.time_label_to_minutes(requested_time) AS s,
        public.time_label_to_minutes(requested_time) + v_duration AS e
      FROM public.one_time_bookings
      WHERE requested_date = v_row.scheduled_date
        AND status = 'confirmed'
        AND NOT public.is_deep_clean_service(service)
    ) x
    WHERE NOT (v_start_min >= x.e OR v_end_min <= x.s);

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
-- Notes
--
-- * All 6 writer/reader functions now share the same rule
--   consistently: a confirmed Deep Clean (guest or membership) blocks
--   the whole day everywhere; a confirmed Maintenance Wash (guest or
--   membership) is a normal 4-hour interval everywhere, checked with
--   the same [start, end) overlap math throughout.
-- * No DROP TABLE, TRUNCATE, or DELETE statements appear anywhere in
--   this migration. Existing bookings, one_time_bookings, and
--   payments are all preserved untouched.
-- * This migration has NOT been executed against any database by the
--   assistant. Run it via the Supabase SQL editor or CLI, after
--   00_complete_setup_consolidated.sql has been applied.
-- =========================================================
