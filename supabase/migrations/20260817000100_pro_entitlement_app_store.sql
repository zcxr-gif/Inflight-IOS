-- Teach the one entitlement answer about the App Store.
--
-- `public.pro_entitlement()` is where every client — web and iOS — asks "is
-- this account Pro?". Before this it knew about two things: a Stripe
-- subscription, and the flags on `profiles`. It now knows about a third, and
-- checks it first, because an App Store purchase is the one an iOS pilot has
-- just made and expects to see honoured everywhere.
--
-- The shape of the answer is unchanged — same five columns, same order — so
-- the web build reads it without being touched. What is new is two possible
-- values of `source`: 'app-store' and 'app-store-lifetime'.

create or replace function public.pro_entitlement()
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
  v_uid   uuid := auth.uid();
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
  if v_uid is null then
    return query select false, 'signed-out'::text, null::text, null::timestamptz, false;
    return;
  end if;

  select * into v_prof from public.profiles where id = v_uid;

  -- The App Store, first.
  --
  -- Sandbox rows are ignored on purpose: they exist so the purchase flow can
  -- be tested, and a TestFlight tester's sandbox subscription must not unlock
  -- Pro on the website. Revoked rows — a refund — are ignored for the obvious
  -- reason. Of what is left, the row that is entitled longest wins, so
  -- somebody who bought a month and then the lifetime unlock keeps the
  -- lifetime.
  select * into v_apple
    from public.app_store_subscriptions
   where user_id = v_uid
     and revoked_at is null
     and environment = 'Production'
     and (
       kind = 'lifetime'
       or (status in ('active', 'grace') and (expires_at is null or expires_at > now()))
       or (status = 'billing_retry' and expires_at is not null
           and expires_at > now() - v_apple_grace)
     )
   order by (kind = 'lifetime') desc, expires_at desc nulls first
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
  select * into v_sub  from public.subscriptions
   where user_id = v_uid
   order by updated_at desc
   limit 1;

  if v_sub.user_id is not null then
    -- Live: paid up, and inside the period that was paid for.
    --
    -- 'canceled' is included deliberately. Stripe's own convention is to leave
    -- a cancelling subscription 'active' with cancel_at_period_end until the
    -- period runs out, but process-stripe-payment writes 'canceled' the moment
    -- the cancellation webhook lands — while current_period_end is still in
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

grant execute on function public.pro_entitlement() to authenticated;
