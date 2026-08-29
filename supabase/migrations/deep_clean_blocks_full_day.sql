-- Deep Clean bookings occupy the WHOLE DAY, not a 4-hour slot.
--
-- Until now, a 'deep_clean' row in public.bookings was treated exactly
-- like a regular maintenance visit: a 4-hour interval that other
-- maintenance bookings could share the rest of the day around. That's
-- wrong for this business — a confirmed Deep Clean should block the
-- entire date for both other Deep Cleans and any maintenance booking,
-- the same way a confirmed one_time_bookings row already does.
--
-- WHAT WAS MISSING
--
-- get_booking_availability() (the calendar's source of truth) only
-- checked public.one_time_bookings for a whole-day block. A confirmed
-- bookings row with visit_type = 'deep_clean' was invisible to that
-- check — it only showed up in the normal 4-hour overlap math, so the
-- calendar happily offered other times on the same date.
--
-- book_maintenance_visit(), admin_reschedule_maintenance_visit(),
-- book_membership() (for the Deep Clean's own slot), and
-- auto_book_due_maintenance() had the same gap.
--
-- book_one_time_service() did NOT have this gap — it already rejects a
-- new guest booking if ANY confirmed maintenance booking exists that
-- day (not just deep_clean specifically), so it needed no change.
--
-- FIX
--
-- New helper public.date_has_deep_clean(date) — true if a confirmed
-- (or rescheduled_by_admin) 'deep_clean' booking exists for that date.
-- Every function that already checks "is there a confirmed one-time
-- service on this date" now also checks this, with the identical
-- whole-day-block behaviour. CREATE OR REPLACE only — no signature
-- changes anywhere, no data touched. Safe to re-run.

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
-- get_booking_availability(date): a Deep Clean now blocks the day the
-- same way a one-time service does. service_booked in the JSON
-- response now reflects either condition, so the frontend's "fully
-- booked" messaging stays accurate without needing a new field.
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
-- book_maintenance_visit(...): add the Deep Clean whole-day check
-- alongside the existing one-time-service check. No signature or
-- locking-strategy change.
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
-- admin_reschedule_maintenance_visit(...): same addition.
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
-- book_membership(...): the Deep Clean's own slot now also checks for
-- an existing Deep Clean that date (in addition to one-time services),
-- so two members can't both land a Deep Clean on the same day.
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
-- auto_book_due_maintenance(): same addition, so the daily
-- auto-booking job also respects a Deep Clean's whole-day block.
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
-- Notes
--
-- * book_one_time_service() needed NO change: it already rejects a
--   new guest booking whenever ANY confirmed maintenance booking
--   exists that day (see v_maintenance_exists in
--   membership_schedule_and_pending_payments.sql), which already
--   covers a confirmed Deep Clean.
-- * This migration does not touch existing bookings, subscriptions,
--   payments, or schedule rows. Safe to re-run.
-- =========================================================
