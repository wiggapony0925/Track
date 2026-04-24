-- Temporary RLS / index audit RPCs.
-- Created so we can introspect the live database via PostgREST without a
-- direct DB connection.  Will be dropped in the next migration once the
-- audit is captured.

create or replace function public._audit_policies()
returns table (
  table_name text,
  policy_name text,
  cmd text,
  roles text,
  qual text,
  with_check text,
  uses_select_auth boolean
)
language sql
security definer
set search_path = public
as $$
  select c.relname::text,
         p.polname::text,
         case p.polcmd
           when 'r' then 'select'
           when 'a' then 'insert'
           when 'w' then 'update'
           when 'd' then 'delete'
           when '*' then 'all'
         end,
         array_to_string(
           coalesce(
             array(select rolname from pg_roles where oid = any(p.polroles)),
             array['public']
           ), ','
         )::text,
         pg_get_expr(p.polqual, p.polrelid)::text,
         pg_get_expr(p.polwithcheck, p.polrelid)::text,
         coalesce(pg_get_expr(p.polqual, p.polrelid) ilike '%(select auth.%', false)
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
   order by c.relname, p.polname;
$$;

create or replace function public._audit_rls_state()
returns table (
  table_name text,
  rls_enabled boolean,
  policy_count int,
  has_user_id_index boolean,
  row_estimate bigint
)
language sql
security definer
set search_path = public
as $$
  with tabs as (
    select c.oid, c.relname,
           c.relrowsecurity as rls_enabled,
           c.reltuples::bigint as row_estimate
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
  ),
  policy_counts as (
    select polrelid, count(*)::int as cnt
      from pg_policy group by polrelid
  ),
  uid_indexes as (
    select i.indrelid,
           bool_or(
             a.attname in ('user_id','id')
           ) as has_uid_idx
      from pg_index i
      join pg_attribute a
        on a.attrelid = i.indrelid
       and a.attnum = i.indkey[0]
     group by i.indrelid
  )
  select t.relname::text,
         t.rls_enabled,
         coalesce(pc.cnt, 0),
         coalesce(ui.has_uid_idx, false),
         t.row_estimate
    from tabs t
    left join policy_counts pc on pc.polrelid = t.oid
    left join uid_indexes  ui on ui.indrelid = t.oid
   order by t.row_estimate desc nulls last, t.relname;
$$;

create or replace function public._audit_pg_stat_top()
returns table (
  query text,
  calls bigint,
  total_ms double precision,
  mean_ms double precision,
  rows bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
    return;
  end if;
  return query execute $q$
    select left(query, 200) as query,
           calls,
           total_exec_time as total_ms,
           mean_exec_time  as mean_ms,
           rows
      from pg_stat_statements
     where dbid = (select oid from pg_database where datname = current_database())
       and query not ilike '%pg_stat_statements%'
       and query not ilike '%_audit_%'
     order by total_exec_time desc
     limit 15
  $q$;
end $$;

grant execute on function public._audit_policies()    to service_role;
grant execute on function public._audit_rls_state()   to service_role;
grant execute on function public._audit_pg_stat_top() to service_role;
