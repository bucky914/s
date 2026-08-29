-- Automatically book a maintenance visit on its allocated schedule
-- date if the customer hasn't booked anything for it themselves by
-- the time that date arrives.
--
-- REQUIREMENTS THIS IMPLEMENTS
--
-- 1. If the customer books an earlier date, that booking should
--    consume/replace the allocated occurrence rather than adding a
--    duplicate, and the occurrence should never disappear from "Your
--    Maintenance Schedule" — it should just show as Booked/Completed
--    instead of Upcoming. This was already implemented by
--    link_booking_to_schedule.sql (book_maintenance_visit() links the
--    new booking to the earliest 'scheduled' row, and the schedule
--    list always renders every row regardless of status — nothing is
--    ever removed from the list, confirmed by inspecting
--    js/dashboard.js's renderSubscriptions(), which maps over every
--    schedule row unconditionally). No change needed for requirement 1.
--
-- 2. NEW: if the customer does nothing and the allocated date arrives,
--    automatically create the booking for that date instead of
--    requiring the customer to act.
--
-- HOW #2 WORKS
--
-- public.auto_book_due_maintenance() is a SECURITY DEFINER function
-- (no auth.uid() involved — it runs as a background job, not on
-- behalf of a logged-in user) that:
--   1. Finds every membership_maintenance_schedule row where
--      status = 'scheduled' and scheduled_date <= CURRENT_DATE (its
--      allocated date has arrived or passed with nothing booked).
--   2. For each one, re-validates the SAME rules book_maintenance_visit()
--      uses: subscription still active, washes_remaining > 0, no
--      confirmed one-time service on that date, no overlapping
--      confirmed maintenance booking, and the interval fits business
--      hours. Uses the identical pg_advisory_xact_lock strategy so it
--      can never race a customer who books that exact date/time at
--      the same moment.
--   3. If the exact scheduled_date/scheduled_time is still available,
--      books it directly (status = 'confirmed') and links the
--      schedule row to it (status = 'booked'), exactly like a normal
--      customer booking would.
--   4. If the exact slot is no longer available (e.g. a guest service
--      or another maintenance booking took it), the row is left as
--      'scheduled' but scheduled_date is pushed forward by one day and
--      retried on the next run — it does NOT silently give up
--      forever, and it does NOT skip/cancel the occurrence on its own.
--      This keeps a human able to intervene (reschedule via admin) if
--      a slot stays unavailable for many days in a row, rather than
--      the system quietly losing track of an occurrence.
--
-- This function is scheduled via pg_cron to run once daily. It is also
-- safe to call manually/on-demand.
--
-- Does NOT touch existing bookings, payments, subscriptions, or
-- historical schedule rows. Safe to re-run.

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

    -- Same advisory lock strategy as book_maintenance_visit() — makes
    -- this safe to run even if a customer is booking the same date at
    -- the same moment.
    PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || v_row.scheduled_date::text));

    v_start_min := public.time_label_to_minutes(v_time);
    v_end_min := v_start_min + v_duration;

    SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();

    IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
      -- Scheduled time doesn't fit business hours (e.g. hours changed
      -- since the schedule was generated) — push one day and retry
      -- tomorrow rather than silently dropping the occurrence.
      UPDATE public.membership_maintenance_schedule
      SET scheduled_date = v_row.scheduled_date + 1, updated_at = now()
      WHERE id = v_row.id;
      result := 'deferred: time no longer fits business hours, retrying next day';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM public.one_time_bookings
      WHERE requested_date = v_row.scheduled_date AND status = 'confirmed'
    ) INTO v_service_booked;

    IF v_service_booked THEN
      UPDATE public.membership_maintenance_schedule
      SET scheduled_date = v_row.scheduled_date + 1, updated_at = now()
      WHERE id = v_row.id;
      result := 'deferred: date fully booked by a one-time service, retrying next day';
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

-- Only admins/service context should be able to invoke this manually —
-- it is not meant to be callable by an ordinary customer session.
GRANT EXECUTE ON FUNCTION public.auto_book_due_maintenance() TO service_role;

-- ---------------------------------------------------------
-- Schedule it to run once a day. Requires the pg_cron extension,
-- which is available on Supabase but not enabled by default.
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
-- Notes
--
-- * If pg_cron is not available on your Supabase plan/project, this
--   migration's CREATE EXTENSION / cron.schedule calls will fail —
--   in that case, remove those two blocks and instead call
--   public.auto_book_due_maintenance() from an external scheduler
--   (e.g. a Supabase Edge Function on a cron trigger, or any daily
--   job that has your service_role key) once a day.
-- * auto_book_due_maintenance() never cancels, skips, or deletes a
--   schedule row on its own — a persistently unbookable occurrence
--   just keeps deferring one day at a time until it succeeds or an
--   admin intervenes (e.g. via admin_reschedule_maintenance_visit for
--   the eventual booking, or by adjusting the schedule row directly).
-- * This migration does not touch existing bookings, subscriptions,
--   payments, or historical schedule rows. Safe to re-run.
-- =========================================================
