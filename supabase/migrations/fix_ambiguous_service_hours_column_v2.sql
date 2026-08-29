-- Fix: ambiguous column reference "open_minutes" in get_service_hours()
-- Cause: get_service_hours() returns columns named open_minutes/close_minutes,
-- and its body selected columns of the SAME names from get_business_hours()
-- without an alias, so Postgres could not tell which "open_minutes" was meant.
-- Fix: alias the inner call as t and reference t.open_minutes / t.close_minutes.

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
