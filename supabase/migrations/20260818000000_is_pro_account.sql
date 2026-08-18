-- One entitlement answer, now askable about somebody other than the caller.
--
-- `pro_entitlement()` answers "is the account behind this token Pro?", which is
-- the only question a client ever needs to ask. The server has a second one:
-- a trigger deciding whether a row is allowed to carry a Pro-only column has to
-- ask about the row's owner, and `auth.uid()` is not always that person — a
-- service-role write has no `auth.uid()` at all.
--
-- Rather than write the rules twice, the body moves into
-- `pro_entitlement_for(uuid)` and `pro_entitlement()` becomes a one-line
-- wrapper over it. Same columns, same order, same values, so every existing
-- caller — the website, the iOS app, the profile card on the forum — reads it
-- untouched.
--
-- WHY THIS MATTERS BEYOND TIDINESS. Until now every Pro gate in the product
-- lived in a client: the app's `Entitlements`, the website's `refreshProStatus`.
-- That is fine for hiding a button and useless for anything that writes a row,
-- because PostgREST is a public API and a determined free account can just POST
-- to it. `is_pro_account()` is what lets a Pro-only *column* be enforced in the
-- database, where a client cannot argue with it.

create or replace function public.pro_entitlement_for(p_uid uuid)
returns table (
  is_pro boolean,
  source text,
  status text,
  until timestamp with time zone,
  cancel_at_period_end boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_sub   public.subscriptions%rowtype;
  v_prof  public.profiles%rowtype;
  v_apple public.app_store_subscriptions%rowtype;
  -- Stripe retries a failed card for up to about two weeks. Matching that
  -- keeps the app from locking someone whose payment is still in flight.
  v_grace interval := interval '14 days';
  -- Apple's own billing-retry window is longer, and a grace period offer can
  -- add another 16 days on top. Same principle, Apple's numbers.
  v_apple_grace interval := interval '16 days';
begin
  if p_uid is null then
    return query select false, 'signed-out'::text, null::text, null::timestamptz, false;
    return;
  end if;

  select * into v_prof from public.profiles p where p.id = p_uid;

  -- The App Store, first.
  --
  -- Sandbox rows are ignored on purpose: they exist so the purchase flow can
  -- be tested, and a TestFlight tester's sandbox subscription must not unlock
  -- Pro on the website. Revoked rows -- a refund -- are ignored for the
  -- obvious reason. Of what is left, the row that is entitled longest wins,
  -- so somebody who bought a month and then the lifetime unlock keeps the
  -- lifetime.
  select * into v_apple
    from public.app_store_subscriptions a
   where a.user_id = p_uid
     and a.revoked_at is null
     and a.environment = 'Production'
     and (
       a.kind = 'lifetime'
       or (a.status in ('active', 'grace')
           and (a.expires_at is null or a.expires_at > now()))
       or (a.status = 'billing_retry' and a.expires_at is not null
           and a.expires_at > now() - v_apple_grace)
     )
   order by (a.kind = 'lifetime') desc, a.expires_at desc nulls first
   limit 1;

  if v_apple.original_transaction_id is not null then
    if v_apple.kind = 'lifetime' then
      return query select true, 'app-store-lifetime'::text, v_apple.status,
                          null::timestamptz, false;
    else
      return query select true, 'app-store'::text, v_apple.status,
                          v_apple.expires_at, not v_apple.auto_renew;
    end if;
    return;
  end if;

  -- Then Stripe, exactly as before.
  select * into v_sub from public.subscriptions s
   where s.user_id = p_uid
   order by s.updated_at desc
   limit 1;

  if v_sub.user_id is not null then
    -- Live: paid up, and inside the period that was paid for.
    --
    -- 'canceled' is included deliberately. Stripe's own convention is to leave
    -- a cancelling subscription 'active' with cancel_at_period_end until the
    -- period runs out, but process-stripe-payment writes 'canceled' the moment
    -- the cancellation webhook lands -- while current_period_end is still in
    -- the future. Reading only the status there would pull the app off a pilot
    -- who has paid through the end of the month, which is the one thing the
    -- billing card promises will not happen. A cancelled row with NO period end
    -- is not covered: there is no paid period to honour, so it has ended.
    if (v_sub.status in ('active', 'trialing')
        and (v_sub.current_period_end is null or v_sub.current_period_end > now()))
       or (v_sub.status = 'canceled'
        and v_sub.current_period_end is not null
        and v_sub.current_period_end > now()) then
      return query select true, 'subscription'::text, v_sub.status,
                          v_sub.current_period_end, v_sub.cancel_at_period_end;
      return;
    end if;

    -- Dunning. Stripe is still trying the card; do not pull the app yet.
    if v_sub.status = 'past_due'
       and (v_sub.current_period_end is null or v_sub.current_period_end > now() - v_grace) then
      return query select true, 'grace'::text, v_sub.status,
                          v_sub.current_period_end, v_sub.cancel_at_period_end;
      return;
    end if;

    -- Ended. This is the lock, and it deliberately beats profiles.is_pro: if
    -- the webhook was missed, the expired period still closes the account.
    -- A grandfathered account falls back to what it had before it ever paid.
    if coalesce(v_prof.legacy_pro, false) then
      return query select true, 'legacy'::text, v_sub.status,
                          v_sub.current_period_end, v_sub.cancel_at_period_end;
      return;
    end if;

    return query select false, 'expired'::text, v_sub.status,
                        v_sub.current_period_end, v_sub.cancel_at_period_end;
    return;
  end if;

  -- No subscription row at all: a manual grant, or a grandfathered account.
  if coalesce(v_prof.is_pro, false) then
    return query select true, 'profile'::text, null::text, null::timestamptz, false;
    return;
  end if;
  if coalesce(v_prof.legacy_pro, false) then
    return query select true, 'legacy'::text, null::text, null::timestamptz, false;
    return;
  end if;

  return query select false, 'free'::text, null::text, null::timestamptz, false;
end $function$;

-- Deliberately NOT granted to `authenticated`.
--
-- Whether somebody else is paying is nobody's business, and this takes an
-- arbitrary uuid. It is called by `pro_entitlement()` and by the triggers
-- below, both of which are `security definer` and run as the owner.
revoke all on function public.pro_entitlement_for(uuid) from public;
revoke all on function public.pro_entitlement_for(uuid) from anon;
revoke all on function public.pro_entitlement_for(uuid) from authenticated;

-- The caller's own entitlement, unchanged in every observable way.
create or replace function public.pro_entitlement()
returns table (
  is_pro boolean,
  source text,
  status text,
  until timestamp with time zone,
  cancel_at_period_end boolean
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select * from public.pro_entitlement_for(auth.uid());
$function$;

grant execute on function public.pro_entitlement() to authenticated;

-- The one-bit form, for policies and triggers.
--
-- Signed out is not Pro, an account with no rows anywhere is not Pro, and an
-- entitlement that cannot be read for any reason is not Pro. Every failure
-- direction here is "free", which is the correct way round for a gate: the
-- other way, an error in the entitlement logic hands Pro to everyone.
create or replace function public.is_pro_account(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select e.is_pro from public.pro_entitlement_for(p_uid) e), false);
$function$;

revoke all on function public.is_pro_account(uuid) from public;
revoke all on function public.is_pro_account(uuid) from anon;
revoke all on function public.is_pro_account(uuid) from authenticated;
