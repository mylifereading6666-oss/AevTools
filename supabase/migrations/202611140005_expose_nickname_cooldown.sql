-- Expose the nickname change timestamp so both sites can lock the editor
-- during the existing 14-day nickname cooldown.
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
  v_changed_at timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT nickname, COALESCE(profile_data, '{}'::jsonb), nickname_changed_at
  INTO v_nickname, v_profile, v_changed_at
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
    'nickname_changed_at', v_changed_at,
    'is_admin', v_admin,
    'role', CASE WHEN v_admin THEN 'admin' ELSE 'user' END,
    'role_label', CASE WHEN v_admin THEN '👑 管理者 / 🛠 開発者' ELSE NULL END,
    'profile', COALESCE(v_profile, '{}'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.aevtools_profile_json() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aevtools_profile_json() TO authenticated;
