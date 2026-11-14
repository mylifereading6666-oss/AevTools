-- AevNetwork team invite codes become single-use (one successful participant per code).
CREATE OR REPLACE FUNCTION public.aevnetwork_redeem_team_invite(
  p_code_hash text,
  p_user_id uuid
)
RETURNS TABLE(team_id uuid, team_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_team_id uuid;
  v_team_name text;
  v_issued_at timestamptz;
  v_existing record;
BEGIN
  IF p_code_hash IS NULL OR length(p_code_hash) <> 64 OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'invite_code_used_or_invalid';
  END IF;

  -- Lock the matching team row. Only one transaction can redeem this code.
  SELECT t.id, t.name, t.invite_code_updated_at
    INTO v_team_id, v_team_name, v_issued_at
  FROM public.aevnetwork_teams t
  WHERE t.invite_code_hash = p_code_hash
  FOR UPDATE;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'invite_code_used_or_invalid';
  END IF;

  IF v_issued_at IS NULL
     OR v_issued_at > now()
     OR v_issued_at <= now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'invite_code_expired';
  END IF;

  SELECT m.id, m.status, m.role
    INTO v_existing
  FROM public.aevnetwork_team_members m
  WHERE m.team_id = v_team_id
    AND m.user_id = p_user_id;

  IF FOUND AND (v_existing.status = 'approved' OR v_existing.role = 'leader') THEN
    RAISE EXCEPTION 'already_team_member';
  END IF;

  -- Consume the code inside the same transaction as membership creation.
  UPDATE public.aevnetwork_teams
  SET invite_code_hash = NULL,
      invite_code_updated_at = NULL
  WHERE id = v_team_id
    AND invite_code_hash = p_code_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invite_code_used_or_invalid';
  END IF;

  INSERT INTO public.aevnetwork_team_members
    (team_id, user_id, role, status, reviewed_at)
  VALUES
    (v_team_id, p_user_id, 'member', 'approved', now())
  ON CONFLICT (team_id, user_id)
  DO UPDATE SET
    role = 'member',
    status = 'approved',
    reviewed_at = now();

  RETURN QUERY SELECT v_team_id, v_team_name;
END;
$function$;

REVOKE ALL ON FUNCTION public.aevnetwork_redeem_team_invite(text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.aevnetwork_redeem_team_invite(text, uuid)
  TO service_role;
