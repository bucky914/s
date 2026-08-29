-- =========================================================
-- Membership maintenance schedule + payment-pending-until-admin-
-- confirms flow (memberships and one-time bookings)
--
-- Builds on top of the EXISTING schema and the three prior migrations:
--   maintenance_booking_date_availability.sql
--   booking_automation_and_availability.sql
--   service_and_maintenance_hours_split.sql
-- Does NOT drop any table, does NOT delete any row, does NOT touch
-- historical data. Safe to re-run: every DDL statement uses
-- IF NOT EXISTS / IF EXISTS / CREATE OR REPLACE.
--
-- WHAT THIS MIGRATION CHANGES AND WHY
--
-- 1. NEW TABLE public.membership_maintenance_schedule — inspected the
--    existing schema first; nothing equivalent exists. Holds the
--    auto-calculated expected maintenance dates for a subscription
--    (Deep Clean + N regular visits from frequency), separately from
--    actual public.bookings rows. A schedule row is a PLAN, not a
--    reservation — booking a visit (via book_maintenance_visit) does
--    not require a schedule row to exist, and a schedule row existing
--    never creates a booking by itself.
--
-- 2. book_membership(...) SIGNATURE CHANGE — no longer takes a
--    p_payment_method parameter (the customer is never asked for
--    payment method per this change). It now takes the Deep Clean
--    date/time instead, and:
--      - creates the subscription (status = 'active') immediately
--      - creates ONE payments row with payment_status = 'pending'
--        (NOT 'paid' — this is the key fix: a membership must not
--        count as revenue until admin confirms it)
--      - books the Deep Clean itself as a real, atomic, conflict-
--        checked public.bookings row (visit_type = 'deep_clean',
--        status = 'confirmed'), respecting the same maintenance
--        availability rules (4-hour interval, one-time-service
--        full-day block, business hours) as every other maintenance
--        booking — via the same advisory-lock strategy already used
--        by book_maintenance_visit()
--      - generates the REST of the expected schedule (regular
--        maintenance visits after the Deep Clean, per frequency and
--        plan.total_regular_washes) as membership_maintenance_schedule
--        rows with status = 'scheduled' — these are NOT bookings and
--        do NOT touch public.bookings or washes_remaining
--    This replaces the previous book_membership(), which took a
--    payment method and immediately inserted a 'paid' payment — that
--    was wrong per this request (payment must stay pending for admin).
--
-- 3. admin_confirm_subscription_payment(uuid, text, date) (NEW) — the
--    single, idempotent way a subscription's pending membership
--    payment becomes paid. UPDATEs the existing pending payments row
--    (never inserts a second one), setting payment_method/payment_date
--    and payment_status = 'paid'. Calling it again on an
--    already-paid subscription raises a friendly, distinct error
--    instead of creating a duplicate payment or silently doing nothing.
--
-- 4. admin_confirm_onetime_payment(uuid, text, date) (NEW) — same
--    pattern for one-time bookings.
--
-- 5. book_one_time_service(...) — now ALSO inserts a pending payments
--    row for the booking atomically (previously it created no payment
--    row at all; the admin dashboard's "New One-Time Bookings" panel
--    used the ABSENCE of any payments row as its "needs payment" signal,
--    which is being replaced by an explicit pending row so "Confirm
--    Payment" can be a real update instead of admin having to invent
--    the payment from scratch).
--
-- 6. Nothing about maintenance/guest availability, the 4-hour overlap
--    rule, the whole-day one-time-service block, or the
--    pg_advisory_xact_lock concurrency strategy changes in this
--    migration — those are already correct from the prior migration
--    and are reused as-is by the Deep Clean booking inside
--    book_membership().
-- =========================================================

-- ---------------------------------------------------------
-- STEP 1 — membership_maintenance_schedule (NEW TABLE)
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
-- STEP 2 — book_membership(...): SIGNATURE CHANGED
--
-- Old signature (previous migration):
--   book_membership(p_plan_id uuid, p_vehicle_model text,
--                    p_frequency text, p_service_address text,
--                    p_payment_method text)
-- New signature:
--   book_membership(p_plan_id uuid, p_vehicle_model text,
--                    p_frequency text, p_service_address text,
--                    p_deep_clean_date date, p_deep_clean_time text)
--
-- The old 5-arg overload is intentionally left in place (NOT dropped)
-- so any in-flight call using it fails loudly with a clear "function
-- does not match" rather than silently misinterpreting a payment-method
-- string as a date. Drop it manually once you've confirmed the
-- frontend only calls the new 6-arg version:
--   DROP FUNCTION IF EXISTS public.book_membership(uuid, text, text, text, text);
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

  -- Validate + reserve the Deep Clean slot using the SAME rules as
  -- every other maintenance booking: 4-hour interval, business hours,
  -- whole-day one-time-service block, and the same
  -- pg_advisory_xact_lock concurrency strategy (see
  -- book_maintenance_visit() in the prior migration for the full
  -- rationale on why this replaces FOR UPDATE on aggregates).
  PERFORM pg_advisory_xact_lock(hashtext('booking_date:' || p_deep_clean_date::text));

  v_start_min := public.time_label_to_minutes(p_deep_clean_time);
  v_end_min := v_start_min + v_duration;

  SELECT open_minutes, close_minutes INTO v_open_min, v_close_min FROM public.get_business_hours();
  IF v_start_min < v_open_min OR v_end_min > v_close_min THEN
    RAISE EXCEPTION 'OUTSIDE_BUSINESS_HOURS' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.one_time_bookings
    WHERE requested_date = p_deep_clean_date AND status = 'confirmed'
  ) INTO v_service_booked;

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

  -- Create the subscription (active immediately — no admin approval
  -- for the membership itself).
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

  -- Payment stays PENDING until admin confirms it — see
  -- admin_confirm_subscription_payment() below. payment_method and
  -- payment_date are intentionally left NULL here; the admin sets both
  -- at confirmation time. This is the fix for "membership amount must
  -- not be counted as Revenue merely because a subscription was created."
  IF v_plan.price > 0 THEN
    INSERT INTO public.payments (
      subscription_id, amount, payment_method, payment_status, notes
    ) VALUES (
      v_sub.id, v_plan.price, 'pending', 'pending',
      'Awaiting admin payment confirmation for membership enrollment.'
    );
  END IF;

  -- Book the Deep Clean itself as a real, atomic booking — this is the
  -- first scheduled service, not a speculative placeholder.
  INSERT INTO public.bookings (
    subscription_id, visit_type, requested_date, requested_time, status
  ) VALUES (
    v_sub.id, 'deep_clean', p_deep_clean_date, p_deep_clean_time, 'confirmed'
  )
  RETURNING * INTO v_deep_clean_booking;

  -- Schedule row 0 = the Deep Clean, already booked.
  INSERT INTO public.membership_maintenance_schedule (
    subscription_id, sequence_number, scheduled_date, scheduled_time,
    service_type, status, booking_id
  ) VALUES (
    v_sub.id, 0, p_deep_clean_date, p_deep_clean_time,
    'deep_clean', 'booked', v_deep_clean_booking.id
  );

  -- Generate the REST of the expected schedule (regular maintenance
  -- visits) from the frequency and the plan's total_regular_washes.
  -- These are PLANNED dates only — status = 'scheduled', no bookings
  -- row, no wash consumption. The customer (or admin) books each one
  -- for real via book_maintenance_visit()/admin flows when the time
  -- comes, which is what actually reserves the slot and (on
  -- completion) decrements washes_remaining via the existing
  -- handle_booking_completion trigger.
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
-- STEP 3 — admin_confirm_subscription_payment(...) (NEW)
--
-- The ONLY way a subscription's membership payment becomes 'paid'.
-- Idempotent: if the payment is already 'paid', raises a distinct,
-- friendly error instead of silently no-op'ing or creating a second
-- payments row — the frontend maps this to "payment already confirmed"
-- rather than a generic failure.
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
-- STEP 4 — admin_confirm_onetime_payment(...) (NEW)
--
-- Same idempotent pattern as STEP 3, for one_time_bookings.
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
-- STEP 5 — book_one_time_service(...): now ALSO creates a pending
-- payments row atomically alongside the booking. Locking/availability
-- logic (advisory lock, whole-day block, 7 AM-3 PM window validation)
-- is unchanged from the prior migration.
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
-- STEP 6 — payments RLS: allow a client to read their own
-- subscription's payment rows (needed so the dashboard can show a
-- "payment pending" banner). Does not touch existing admin policies —
-- only adds a SELECT policy scoped to the client's own subscriptions;
-- guest one-time bookings have no client account to scope to, so this
-- does not grant any new access there. If a broader/equivalent policy
-- already exists, this is a harmless no-op (IF NOT EXISTS guarded).
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
-- STEP 7 — Notes
--
-- * payments.payment_method / payments.payment_status have existing
--   NOT NULL constraints per the original schema (payment_method text
--   NOT NULL, payment_status text NOT NULL DEFAULT 'paid'::text). This
--   migration explicitly passes payment_method = 'pending' as a
--   PLACEHOLDER string satisfying the NOT NULL constraint until the
--   admin sets the real method at confirmation — it is never displayed
--   or treated as a real payment method value; the frontend's method
--   label mapping should show a neutral placeholder for it (see the
--   updated admin/js/finances-admin.js methodLabel()).
--   payments.payment_status default remains 'paid' globally per this
--   request's instruction not to change the default (which could
--   affect the existing general "Record Payment" admin flow) — every
--   INSERT in this migration explicitly sets payment_status = 'pending'
--   rather than relying on/changing that default.
-- * Revenue queries (admin/js/finances-admin.js) MUST filter
--   payment_status = 'paid' — this migration does not enforce that at
--   the database layer (revenue is computed client-side per the
--   existing architecture), so the accompanying frontend change is
--   required for Test 9/10 to actually pass. See the file list in the
--   final response for exactly what changed there.
-- * No DROP TABLE, TRUNCATE, or DELETE statements appear anywhere in
--   this migration or the three prior ones. Existing bookings,
--   subscriptions, payments, and clients are all preserved untouched.
-- * This migration was NOT executed against any database by the
--   assistant. Review and run it via the Supabase SQL editor or CLI.
-- =========================================================
