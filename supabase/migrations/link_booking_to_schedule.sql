-- Link a booked maintenance visit to the customer's maintenance
-- schedule, so booking an EARLIER date than the next auto-scheduled
-- occurrence consumes that occurrence instead of leaving it as a
-- separate, still-"Upcoming" duplicate entry.
--
-- WHAT WAS MISSING
--
-- book_maintenance_visit() already lets a customer pick any available
-- date/time (earlier or later than their next scheduled occurrence) —
-- the RPC only checks real availability, never the schedule table. But
-- it never touched public.membership_maintenance_schedule at all, so
-- after booking an earlier visit the dashboard kept showing the
-- original scheduled date as "Upcoming" even though the customer had
-- already booked and (eventually) will complete a maintenance visit
-- for that occurrence.
--
-- FIX
--
-- CREATE OR REPLACE of book_maintenance_visit() — identical to the
-- current version in every validation/locking/insert step, with one
-- addition at the end: after the booking is inserted, find this
-- subscription's earliest still-'scheduled' schedule row
-- (sequence_number >= 1 — sequence 0 is the Deep Clean, already
-- booked at enrollment) and mark it 'booked', pointing at the new
-- booking and updated to the actual chosen date/time. If there is no
-- 'scheduled' row left (e.g. every generated occurrence has already
-- been booked, or the plan is exhausted), the booking still succeeds —
-- it just isn't linked to a schedule row, which is correct: the
-- schedule is a plan, not a hard requirement.
--
-- This does not change validation, concurrency, or locking behaviour
-- in any way — only what happens after a successful insert.
-- Safe to re-run. No data is deleted; only the matched schedule row
-- (if any) is updated for this one subscription.

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

  -- Serialize every writer (maintenance booking, reschedule, or guest
  -- service booking) touching this date. Must happen before any
  -- availability read below so those reads are guaranteed consistent.
  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_requested_date::text));

  -- Authenticate, resolve the caller's own subscription, verify
  -- ownership. clients.id = auth.uid() by the existing schema, so
  -- v_sub.client_id = auth.uid() directly encodes "this subscription's
  -- client is the authenticated user".
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

  -- Validate the requested time and compute the 4-hour interval.
  v_start_min := public.time_label_to_minutes(p_requested_time);
  v_end_min := v_start_min + v_duration;

  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_BUSINESS_HOURS' USING ERRCODE = 'P0001';
  END IF;

  -- A confirmed one-time service on this date blocks all maintenance.
  SELECT EXISTS (
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_requested_date AND status = 'confirmed'
  ) INTO v_service_booked;

  IF v_service_booked THEN
    RAISE EXCEPTION 'DATE_FULLY_BOOKED' USING ERRCODE = 'P0001';
  END IF;

  -- No overlapping confirmed maintenance bookings.
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

  -- Insert atomically with status = 'confirmed'.
  INSERT INTO public.bookings (
    subscription_id, visit_type, requested_date, requested_time, status
  ) VALUES (
    p_subscription_id, 'maintenance_wash', p_requested_date, p_requested_time, 'confirmed'
  )
  RETURNING * INTO v_booking;

  -- NEW: consume the earliest still-scheduled maintenance occurrence
  -- for this subscription instead of leaving it as a stale duplicate
  -- "Upcoming" row — this is what makes booking early correctly count
  -- toward the existing schedule instead of adding an extra visit.
  -- sequence_number >= 1 excludes the Deep Clean (sequence 0), which
  -- is booked directly at enrollment and never re-matched here.
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

  -- washes_remaining/washes_used are adjusted by the existing
  -- handle_booking_completion trigger when status becomes 'completed' —
  -- intentionally NOT decremented here to avoid double-counting, and so
  -- cancelling a confirmed booking doesn't consume a wash.

  RETURN v_booking;
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_maintenance_visit(uuid, date, text) TO authenticated;

-- ---------------------------------------------------------
-- Keep membership_maintenance_schedule in sync when a linked booking's
-- status changes later (admin marks it completed/cancelled, or
-- reschedules it) — a trigger on public.bookings rather than
-- duplicating this logic in every place a booking's status can change
-- (admin dashboard, admin bookings page, and any future caller).
--
-- On 'completed'   -> matching schedule row (if any) becomes 'completed'
-- On 'cancelled'   -> matching schedule row (if any) reverts to
--                     'scheduled' so that occurrence becomes bookable
--                     again instead of being stuck showing "Booked"
--                     for a visit that never happened
-- On 'rescheduled_by_admin' / date-time change -> matching schedule
--                     row's date/time are kept in sync so the
--                     dashboard shows the real, current appointment
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

