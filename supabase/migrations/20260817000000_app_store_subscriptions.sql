-- Inflight Pro, bought on the App Store.
--
-- The web build sells Pro through Stripe (`public.subscriptions`); the iOS app
-- sells it through StoreKit, because that is the only lawful way to sell it
-- inside an app. Both end up answering the same question — "is this account
-- Pro?" — so both are read by `public.pro_entitlement()`, and this table is
-- the App Store's half of that answer.
--
-- Nothing here is client-writable. A client that can set its own entitlement
-- is a client that can grant itself Pro, so every row is written by the
-- `apple-subscription-sync` and `apple-notifications` Edge Functions, both of
-- which verify Apple's signature over the transaction before they write.

create table if not exists public.app_store_subscriptions (
  -- Apple's stable identity for a subscription across every renewal, and for
  -- a non-consumable across every restore. The natural key: one row per thing
  -- bought, however many times it renews.
  original_transaction_id text primary key,

  user_id uuid not null references auth.users (id) on delete cascade,

  product_id text not null,

  -- Auto-renewable, or the one-off lifetime unlock. A lifetime row has no
  -- expiry and is never re-checked; a subscription row lives and dies by
  -- `expires_at`.
  kind text not null default 'subscription'
    check (kind in ('subscription', 'lifetime')),

  -- Apple's own view of the subscription, mapped onto the five states that
  -- change what the app should do. `billing_retry` and `grace` both still
  -- entitle: Apple is retrying the card, and pulling the app out from under
  -- someone mid-retry is what the grace period exists to prevent.
  status text not null default 'active'
    check (status in ('active', 'grace', 'billing_retry', 'expired', 'revoked')),

  purchased_at timestamptz,

  -- When the paid period runs out. Null for a lifetime row.
  expires_at timestamptz,

  auto_renew boolean not null default true,
  is_trial boolean not null default false,

  -- 'Production' or 'Sandbox'. A sandbox row is kept — it is how the flow is
  -- tested — but `pro_entitlement()` ignores it, so a TestFlight tester's
  -- sandbox subscription never unlocks Pro on the website.
  environment text not null default 'Production',

  -- Set on a refund. Apple has taken the money back, so the entitlement goes
  -- with it, whatever `expires_at` says.
  revoked_at timestamptz,

  -- The most recent transaction seen for this subscription, so a replayed or
  -- out-of-order notification can be recognised rather than applied twice.
  latest_transaction_id text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists app_store_subscriptions_user_id_idx
  on public.app_store_subscriptions (user_id);

alter table public.app_store_subscriptions enable row level security;

-- Readable by its owner, and by nobody else. There is deliberately no insert,
-- update or delete policy: the Edge Functions hold the service role, which
-- bypasses RLS, and nothing else is allowed to write an entitlement.
drop policy if exists "Pilots read their own App Store subscription"
  on public.app_store_subscriptions;

create policy "Pilots read their own App Store subscription"
  on public.app_store_subscriptions
  for select
  using (auth.uid() = user_id);

create or replace function public.app_store_subscriptions_touch()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists app_store_subscriptions_touch
  on public.app_store_subscriptions;

create trigger app_store_subscriptions_touch
  before update on public.app_store_subscriptions
  for each row execute function public.app_store_subscriptions_touch();
