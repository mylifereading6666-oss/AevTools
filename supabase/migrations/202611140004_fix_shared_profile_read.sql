-- Fix shared profile reads for both AevTools and AevNetwork.
-- Preserve the legacy user/admin fields and include the shared profile_data.

CREATE OR REPLACE FUNCTION public.aevtools_profile_json()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_nickname text;
  v_admin boolean;
  v_profile jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT nickname, COALESCE(profile_data, '{}'::jsonb)
  INTO v_nickname, v_profile
  FROM public.aevtools_profiles
  WHERE user_id = v_uid;

  SELECT EXISTS (
    SELECT 1 FROM public.aevtools_admin WHERE user_id = v_uid
  ) INTO v_admin;

  IF v_nickname IS NULL THEN
    v_nickname := CASE
      WHEN v_admin THEN 'Aev0rnJP'
      ELSE 'ユーザー' || upper(substr(replace(v_uid::text, '-', ''), 1, 6))
    END;
  END IF;

  RETURN jsonb_build_object(
    'user_id', v_uid,
    'nickname', v_nickname,
    'is_admin', v_admin,
    'role', CASE WHEN v_admin THEN 'admin' ELSE 'user' END,
    'role_label', CASE WHEN v_admin THEN '👑 管理者 / 🛠 開発者' ELSE NULL END,
    'profile', COALESCE(v_profile, '{}'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.aevtools_get_my_profile()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
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

REVOKE ALL ON FUNCTION public.aevtools_profile_json() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aevtools_profile_json() TO authenticated;
REVOKE ALL ON FUNCTION public.aevtools_get_my_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aevtools_get_my_profile() TO authenticated;
