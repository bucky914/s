-- =========================================================
-- Two-window availability (maintenance vs guest service) +
-- payment-confirmed membership activation
--
-- Builds on top of the EXISTING schema and the two prior migrations:
--   maintenance_booking_date_availability.sql
--   booking_automation_and_availability.sql
-- Does NOT drop any table, does NOT delete any row, does NOT touch
-- historical data (including the two pre-existing maintenance bookings).
-- Safe to re-run: every DDL statement uses IF NOT EXISTS / IF EXISTS /
-- CREATE OR REPLACE.
--
-- WHY THIS MIGRATION EXISTS
--
-- The previous migration derived a single business-hours window from
-- business_settings.working_hours (falling back to 8 AM-6 PM) and used
-- it for BOTH maintenance and guest bookings. That's wrong: maintenance
-- and guest service are two different booking types with two different
-- windows —
--   Maintenance:    7:00 AM - 7:00 PM (4-hour interval booking)
--   Guest service:  7:00 AM - 3:00 PM (booking time is just a start
--                   time; the confirmed booking still blocks the whole
--                   day once confirmed, per Rule 1/18 below)
-- and the guest booking form was drawing from the SAME 8 AM-6 PM slot
-- list as maintenance, which is also wrong.
--
-- This migration:
--   1. Adds public.get_service_hours() — the guest-service window
--      (7 AM-3 PM), capped by business_settings.working_hours the same
--      defensive way get_business_hours() already is.
--   2. Updates public.get_business_hours()'s fallback to 7 AM-7 PM (the
--      correct default maintenance window; previously 8 AM-6 PM).
--   3. Updates get_booking_availability(date) to use the maintenance
--      window and to also return the correct guest-service time list.
--   4. Updates book_maintenance_visit(...) and
--      admin_reschedule_maintenance_visit(...) to validate against the
--      maintenance window (now 7 AM-7 PM by default).
--   5. Updates book_one_time_service(...) to validate the requested
--      time against the guest-service window (7 AM-3 PM) — previously
--      it accepted any time string with no window check at all.
--   6. Adds book_membership(...) — a new atomic RPC that inserts a
--      'paid' payments row and an 'active' subscriptions row together,
--      so a membership can never end up active-but-unpaid or
--      paid-but-inactive. This replaces the direct, no-payment
--      subscriptions insert the frontend previously used.
--   7. Re-confirms (no functional change here — already correct from
--      the previous migration) that no writer function anywhere uses
--      FOR UPDATE on an aggregate/EXISTS result.
--
-- None of the concurrency-control functions from the previous migration
-- (the pg_advisory_xact_lock-based writers) are being reverted or
-- weakened — this migration only widens/splits the time windows they
-- validate against and adds the new membership RPC.
-- =========================================================

-- ---------------------------------------------------------
-- STEP 1 — Guest service hours helper (NEW)
--
-- Mirrors get_business_hours()'s defensive parsing, but represents the
-- guest-service booking window (7 AM-3 PM), which is intentionally
-- shorter than and independent of the maintenance window. If
-- business_settings.working_hours is set AND tighter than 7 AM-3 PM on
-- either end, it's honored as an outer cap (an admin who closes early
-- shouldn't have the system still offer a 2 PM guest slot); otherwise
-- the fixed 7 AM-3 PM default applies.
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
  o_min integer := 7 * 60;   -- 7:00 AM default
  c_min integer := 15 * 60;  -- 3:00 PM default
BEGIN
  SELECT open_minutes, close_minutes INTO v_biz_open, v_biz_close FROM public.get_business_hours();

  IF v_biz_open IS NOT NULL AND v_biz_open > o_min THEN
    o_min := v_biz_open;
  END IF;
  IF v_biz_close IS NOT NULL AND v_biz_close < c_min THEN
    c_min := v_biz_close;
  END IF;

  IF c_min <= o_min THEN
    -- Degenerate configuration (e.g. business_settings closes before
    -- 7 AM) — fall back to the fixed default rather than returning an
    -- empty/inverted window.
    o_min := 7 * 60;
    c_min := 15 * 60;
  END IF;

  RETURN QUERY SELECT o_min, c_min;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_service_hours() TO anon, authenticated;

-- ---------------------------------------------------------
-- STEP 2 — Maintenance business hours fallback corrected to 7 AM-7 PM
--
-- CREATE OR REPLACE of the existing function from the prior migration.
-- Only the fallback constants change (8 AM/6 PM -> 7 AM/7 PM); the
-- free-text parsing of business_settings.working_hours is unchanged.
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
-- STEP 3 — get_booking_availability(date): maintenance slot labels
-- widened to the 7 AM-7 PM window, plus a new guest-service time list
-- in the same response so the frontend can load both with one call.
--
-- Interval semantics are [start, end) throughout: 1PM-5PM does not
-- overlap 5PM-9PM, but does overlap 4PM-8PM. Unchanged from the prior
-- migration.
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
  v_maintenance_duration integer := 240; -- 4 hours, minutes
  -- 7:00 AM - 7:00 PM in 1-hour steps. Any label whose 4-hour interval
  -- doesn't fit inside get_business_hours() (the maintenance window) is
  -- filtered out below, so widening this list is safe even if the
  -- business is configured with shorter hours.
  v_slot_labels text[] := ARRAY['7:00 AM','8:00 AM','9:00 AM','10:00 AM','11:00 AM','12:00 PM','1:00 PM','2:00 PM','3:00 PM','4:00 PM','5:00 PM','6:00 PM','7:00 PM'];
  -- Guest-service start times, 7:00 AM - 3:00 PM. This is a distinct,
  -- shorter window from the maintenance list above (see STEP 1).
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

  -- Rule: any confirmed one-time service on this date blocks the whole
  -- day for BOTH maintenance and further guest bookings.
  SELECT EXISTS (
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_date AND status = 'confirmed'
  ) INTO v_service_booked;

  -- Existing maintenance bookings on this date (active statuses only),
  -- expressed as [start, end) minute intervals from midnight. This
  -- query also correctly picks up the two pre-existing bookings
  -- created before automation, since it reads whichever of
  -- confirmed_time/requested_time is populated via COALESCE, exactly
  -- as those historical rows store it.
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

      -- Must fit inside the maintenance business window (7 AM-7 PM by
      -- default, or business_settings.working_hours if tighter).
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

    -- Guest-service times: only the 7 AM-3 PM window applies, and
    -- guest booking time does NOT need 4-hour overlap checking against
    -- maintenance — a guest slot is only invalid if the whole day is
    -- already blocked (v_service_booked, handled by the outer IF) or
    -- the time itself falls outside the service window.
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
-- STEP 4 — book_maintenance_visit(...): no signature change, only the
-- business-hours source now yields 7 AM-7 PM by default (via the
-- updated get_business_hours() in STEP 2). Re-created here unchanged
-- otherwise, including the auth.uid()-based ownership check and the
-- pg_advisory_xact_lock concurrency strategy from the previous
-- migration — repeating the fix note for completeness since this
-- CREATE OR REPLACE fully re-defines the function body.
--
-- Ownership check clarified per this request's step-by-step spec:
-- auth.uid() is the authenticated user's id, which is also
-- clients.id (clients.id = auth.users.id by the existing schema/RLS
-- convention — see js/auth.js signUpClient()), so
-- v_sub.client_id <> auth.uid() IS the "does this subscription belong
-- to the authenticated client" check; no separate clients lookup is
-- needed or more correct than comparing the id directly.
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
  -- Postgres does not allow FOR UPDATE on an aggregate/EXISTS result
  -- (ERROR 0A000), so this advisory lock — not row locking — is what
  -- makes the plain SELECT COUNT(*)/SELECT EXISTS reads below safe.
  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

  -- 1-3: authenticate, resolve the caller's own subscription, verify
  -- ownership. clients.id = auth.uid() by the existing schema, so
  -- v_sub.client_id = auth.uid() directly encodes "this subscription's
  -- client is the authenticated user" without a separate clients join.
  SELECT * INTO v_sub
  FROM public.subscriptions
  WHERE id = p_subscription_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF v_sub.client_id <> auth.uid() THEN
    RAISE EXCEPTION 'NOT_YOUR_SUBSCRIPTION' USING ERRCODE = '42501';
  END IF;

  -- 4: subscription must be active.
  IF v_sub.status <> 'active' THEN
    RAISE EXCEPTION 'SUBSCRIPTION_NOT_ACTIVE' USING ERRCODE = 'P0001';
  END IF;

  IF v_sub.washes_remaining <= 0 THEN
    RAISE EXCEPTION 'NO_WASHES_REMAINING' USING ERRCODE = 'P0001';
  END IF;

  IF p_requested_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'DATE_IN_PAST' USING ERRCODE = 'P0001';
  END IF;

  -- 6-7: validate the requested time and compute the 4-hour interval.
  v_start_min := public.time_label_to_minutes(p_requested_time);
  v_end_min := v_start_min + v_duration;

  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_BUSINESS_HOURS' USING ERRCODE = 'P0001';
  END IF;

  -- 5: a confirmed one-time service on this date blocks all
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

  -- 8: no overlapping confirmed maintenance bookings. Plain
  -- SELECT COUNT(*) — no FOR UPDATE (COUNT(*) ... FOR UPDATE is the
  -- exact pattern that raised ERROR 0A000). Safe without row locking
  -- because the advisory lock already serializes writers for this date.
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

  -- 9-10: insert atomically with status = 'confirmed'.
  INSERT INTO public.bookings (
    subscription_id, visit_type, requested_date, requested_time, status
  ) VALUES (
    p_subscription_id, 'maintenance_wash', p_requested_date, p_requested_time, 'confirmed'
  )
  RETURNING * INTO v_booking;

  -- 13: washes_remaining/washes_used are adjusted by the existing
  -- handle_booking_completion trigger when status becomes 'completed' —
  -- intentionally NOT decremented here to avoid double-counting, and so
  -- cancelling a confirmed booking doesn't consume a wash.

  -- 11-12: return the created booking.
  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_maintenance_visit(uuid, date, text) TO authenticated;

-- ---------------------------------------------------------
-- STEP 5 — admin_reschedule_maintenance_visit(...): no signature or
-- locking-strategy change, only inherits the corrected 7 AM-7 PM
-- maintenance window via get_business_hours(). Re-created here for
-- completeness since CREATE OR REPLACE fully redefines the body.
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
-- STEP 6 — book_one_time_service(...): NOW validates the requested
-- time against the guest-service window (7 AM-3 PM via
-- get_service_hours()) — the previous version accepted any time
-- string with no window check. Locking/concurrency strategy is
-- unchanged from the previous migration.
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

  -- Guest service booking TIME WINDOW (7 AM-3 PM) — distinct from
  -- SERVICE OCCUPANCY, which is always the whole day once confirmed
  -- (handled below/by the availability RPC). A missing/unparseable
  -- time is treated as invalid rather than silently accepted.
  IF p_requested_time IS NULL OR btrim(p_requested_time) = '' THEN
    RAISE EXCEPTION 'MISSING_TIME' USING ERRCODE = 'P0001';
  END IF;

  SELECT open_minutes, close_minutes INTO v_svc_open_min, v_svc_close_min FROM public.get_service_hours();
  v_start_min := public.time_label_to_minutes(p_requested_time);
  IF v_start_min < v_svc_open_min OR v_start_min > v_svc_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_SERVICE_HOURS' USING ERRCODE = 'P0001';
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
  -- Priority rule: an existing confirmed one-time service (checked
  -- above) always wins; this second check additionally blocks a NEW
  -- guest booking from being confirmed on a date that already has ANY
  -- confirmed maintenance appointment, since a confirmed guest service
  -- would retroactively occupy the whole day and conflict with it.
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
-- STEP 7 — book_membership(...) (NEW)
--
-- Atomically creates the payments row (payment_status = 'paid') and
-- the subscriptions row (status = 'active') together, so a membership
-- can never end up active-without-payment or paid-without-activation.
-- This is what "payment confirmation, not admin approval" means here:
-- the customer's own submission — after seeing the plan price and
-- choosing how they paid — is what confirms payment; there is no
-- separate admin approval step, matching the existing business's
-- upfront-payment model (see the historical "Recorded automatically on
-- plan approval (paid upfront)" note in admin/js/customers-admin.js,
-- which this RPC continues, minus the admin-approval gate).
--
-- payment_status is intentionally NOT hardcoded elsewhere in this
-- migration to always mean "active" — this RPC is the one place that
-- ties them together for a NEW enrollment; existing/legacy rows and
-- admin-recorded top-up/correction payments are untouched.
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.book_membership(
  p_plan_id uuid,
  p_vehicle_model text,
  p_frequency text,
  p_service_address text,
  p_payment_method text
)
RETURNS public.subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan public.plans;
  v_sub public.subscriptions;
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
  IF p_payment_method IS NULL OR btrim(p_payment_method) = '' THEN
    RAISE EXCEPTION 'MISSING_PAYMENT_METHOD' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_plan FROM public.plans WHERE id = p_plan_id AND active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PLAN_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (p_frequency = ANY(v_plan.frequency_options)) THEN
    RAISE EXCEPTION 'INVALID_FREQUENCY' USING ERRCODE = 'P0001';
  END IF;

  -- Insert the subscription first (status = 'active' immediately — no
  -- admin approval step), then the payment row referencing it, in the
  -- same transaction: either both succeed or neither does.
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
      subscription_id, amount, payment_method, payment_status, payment_date, notes
    ) VALUES (
      v_sub.id, v_plan.price, p_payment_method, 'paid', CURRENT_DATE,
      'Recorded automatically on membership activation (paid upfront).'
    );
  END IF;

  RETURN v_sub;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_membership(uuid, text, text, text, text) TO authenticated;

-- ---------------------------------------------------------
-- STEP 8 — Notes
--
-- * Historical rows with status = 'pending' (bookings) or
--   'pending_confirmation' (subscriptions) are left untouched. Only
--   NEW rows use the automatic flow.
-- * The two pre-existing maintenance bookings created before automation
--   are NOT modified by this migration. get_booking_availability() and
--   book_maintenance_visit()'s overlap check both read them correctly
--   via COALESCE(confirmed_time, requested_time) / COALESCE(confirmed_date,
--   requested_date), the same fields those rows were originally written
--   with, so they continue to occupy their real 4-hour windows.
-- * subscriptions.status DEFAULT 'active' (set by the previous
--   migration) is unchanged — book_membership() sets it explicitly
--   anyway, so this is only a defensive default for any other insert path.
-- * No DROP TABLE, TRUNCATE, or DELETE statements appear anywhere in
--   this migration or the two prior ones.
-- * This migration was NOT executed against any database by the
--   assistant. Review and run it via the Supabase SQL editor or CLI.
-- =========================================================
