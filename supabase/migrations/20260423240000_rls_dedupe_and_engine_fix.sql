-- ─────────────────────────────────────────────────────────────────────────────
-- Final RLS cleanup: fix engine_* policies, dedupe, repair profiles INSERT.
--
-- Findings from live audit:
-- 1. engine_calendar_events / engine_recent_trips / engine_saved_places /
--    engine_saved_trips use the SLOW pattern `(auth.uid())::text = user_id`
--    (re-evaluated per row).  Convert to InitPlan form.
--
-- 2. Duplicate SELECT policies on commute_patterns / favorites /
--    route_interactions / schedules / user_settings — both an older
--    "Users can manage own X" (FOR ALL) and my new "_owner_read" (FOR SELECT)
--    cover the same path.  Keep the FOR ALL ones (they cover insert/update/
--    delete too) and drop my redundant SELECT-only twins.  Make sure the
--    FOR ALL ones are in InitPlan form.
--
-- 3. profiles has BOTH "Users can view own profile" AND "profiles_owner_read"
--    for SELECT — drop the older one.
--
-- 4. profiles INSERT policy has empty qual + no with_check — repair.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. engine_* — replace slow text-cast policies ────────────────────────────

do $$
declare
  spec record;
begin
  for spec in
    select * from (values
      ('engine_calendar_events', 'engine calendar events own rows'),
      ('engine_recent_trips',    'engine recent trips own rows'),
      ('engine_saved_places',    'engine saved places own rows'),
      ('engine_saved_trips',     'engine saved trips own rows')
    ) as t(table_name, policy_name)
  loop
    execute format('drop policy if exists %I on public.%I;',
                   spec.policy_name, spec.table_name);
    -- engine_* tables store user_id as TEXT (Apple sub).  RLS still works
    -- when JWT carries an Apple-sub claim cast to text via auth.jwt().
    -- These are currently service-role-only writes from the backend, so the
    -- policy here is read-only insurance for the day clients connect direct.
    execute format($p$create policy %I on public.%I
                       for all
                       to authenticated
                       using (((select auth.uid())::text = user_id))
                       with check (((select auth.uid())::text = user_id));$p$,
                   spec.policy_name, spec.table_name);
  end loop;
end $$;


-- 2. Dedupe SELECT-only twins.  Keep the older FOR ALL policies and drop my
--    new _owner_read SELECT-only ones where they overlap.  Then upgrade the
--    older ones to InitPlan form.

drop policy if exists "favorites_owner_read"          on public.favorites;
drop policy if exists "schedules_owner_read"          on public.schedules;
drop policy if exists "user_settings_owner_read"      on public.user_settings;
drop policy if exists "commute_patterns_owner_read"   on public.commute_patterns;

-- Upgrade the surviving FOR ALL policies (they were already InitPlan from
-- our previous migration but let's be explicit):

drop policy if exists "Users can manage own favorites"        on public.favorites;
create policy "favorites_own_rows" on public.favorites
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can manage own schedules"        on public.schedules;
create policy "schedules_own_rows" on public.schedules
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can manage own settings"         on public.user_settings;
create policy "user_settings_own_rows" on public.user_settings
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can manage own commute patterns" on public.commute_patterns;
create policy "commute_patterns_own_rows" on public.commute_patterns
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);


-- 3. route_interactions: keep INSERT + SELECT split, drop redundant SELECT.

drop policy if exists "route_interactions_owner_read"            on public.route_interactions;
drop policy if exists "Users can view own interactions"          on public.route_interactions;
create policy "route_interactions_own_read" on public.route_interactions
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Authenticated users can insert own interactions" on public.route_interactions;
create policy "route_interactions_own_insert" on public.route_interactions
  for insert to authenticated
  with check ((select auth.uid()) = user_id);


-- 4. profiles: drop legacy duplicates + repair insert.

drop policy if exists "Users can view own profile"   on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
drop policy if exists "Users can insert own profile" on public.profiles;
-- profiles_owner_read (SELECT) survives from previous migration.

create policy "profiles_own_update" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create policy "profiles_own_insert" on public.profiles
  for insert to authenticated
  with check ((select auth.uid()) = id);


-- 5. trip_configurations: dedupe (we have both "trip configurations own rows"
--    and "trip_configurations_owner_read" — keep the FOR ALL one).

drop policy if exists "trip_configurations_owner_read" on public.trip_configurations;


-- (Audit RPCs are dropped in a separate migration after re-verification.)
