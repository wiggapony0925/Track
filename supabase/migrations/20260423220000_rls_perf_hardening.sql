-- ─────────────────────────────────────────────────────────────────────────────
-- RLS performance hardening
--
-- Why: PostgreSQL evaluates `auth.uid() = user_id` per-row when written that
-- way, because the planner can't prove auth.uid() is stable.  Wrapping it as
-- `(select auth.uid()) = user_id` turns it into an InitPlan node — evaluated
-- once per query, then cached.  This is Supabase's #1 advisor-flagged perf
-- anti-pattern (lint: auth_rls_initplan).
--
-- Speedup: 10–1000× on tables with thousands of rows (route_interactions has
-- 1.8k rows today and grows per session — this matters now).
--
-- Also adds the indexes that those policies want under their hot path:
-- a btree on user_id is required for an Index Scan instead of Seq Scan.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Re-create policies with the (select auth.uid()) form ────────────────────

do $$
declare
  t text;
begin
  -- Analytics tables (all use user_id)
  for t in select unnest(array[
    'user_sessions','analytics_events','screen_views','search_queries',
    'route_engagements','map_interactions','error_events',
    'performance_metrics','notification_events','feature_flag_exposures'
  ]) loop
    execute format('drop policy if exists "%s_owner_read" on public.%I;', t, t);
    execute format($p$create policy "%s_owner_read" on public.%I
                       for select to authenticated
                       using ((select auth.uid()) = user_id);$p$, t, t);
  end loop;

  -- Existing user-owned tables (uuid user_id)
  for t in select unnest(array[
    'favorites','schedules','user_settings',
    'commute_patterns','route_interactions','trip_configurations'
  ]) loop
    execute format('drop policy if exists "%s_owner_read" on public.%I;', t, t);
    execute format($p$create policy "%s_owner_read" on public.%I
                       for select to authenticated
                       using ((select auth.uid()) = user_id);$p$, t, t);
  end loop;

  -- profiles uses 'id' as the FK to auth.users
  drop policy if exists "profiles_owner_read" on public.profiles;
  create policy "profiles_owner_read" on public.profiles
    for select to authenticated
    using ((select auth.uid()) = id);
end $$;


-- 2. trip_configurations had a separate policy from its own migration that
--    used the slow `auth.uid() = user_id` form; replace it too.

drop policy if exists "trip configurations own rows" on public.trip_configurations;
create policy "trip configurations own rows" on public.trip_configurations
  for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);


-- 3. Indexes — make sure every user_id (or id, for profiles) used in a
--    policy has a btree.  Most analytics tables already have a composite
--    (user_id, occurred_at desc) which covers the policy filter via the
--    leading column, so we only add the few that were missing.

create index if not exists idx_favorites_user
  on public.favorites (user_id);

create index if not exists idx_schedules_user
  on public.schedules (user_id);

create index if not exists idx_user_settings_user
  on public.user_settings (user_id);

create index if not exists idx_route_interactions_user
  on public.route_interactions (user_id, created_at desc);

create index if not exists idx_commute_patterns_user
  on public.commute_patterns (user_id, last_used desc);


-- 4. Defensive: deduplicate any double-policy state from the previous
--    migration applying both an inline policy and a generated one.

do $$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and policyname like '%_owner_read'
       and tablename not in (
         'user_sessions','analytics_events','screen_views','search_queries',
         'route_engagements','map_interactions','error_events',
         'performance_metrics','notification_events','feature_flag_exposures',
         'profiles','favorites','schedules','user_settings',
         'commute_patterns','route_interactions','trip_configurations'
       )
  loop
    raise notice 'orphan owner_read policy on %.%: %',
      r.schemaname, r.tablename, r.policyname;
  end loop;
end $$;
