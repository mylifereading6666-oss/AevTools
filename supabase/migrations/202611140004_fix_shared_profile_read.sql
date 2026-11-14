-- Fix shared profile reads for both AevTools and AevNetwork.
-- The legacy getter returned only nickname/role and omitted profile_data.
CREATE OR REPLACE FUNCTION public.aevtools_get_my_profile()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'login_required';
  END IF;

  INSERT INTO public.aevtools_profiles (user_id, nickname)
  VALUES (
    v_uid,
    CASE
      WHEN public.aevtools_is_admin() THEN 'Aev0rnJP'
      ELSE 'ユーザー' || upper(substr(replace(v_uid::text, '-', ''), 1, 6))
    END
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN public.aevtools_profile_json();
END;
$$;

REVOKE ALL ON FUNCTION public.aevtools_get_my_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aevtools_get_my_profile() TO authenticated;
