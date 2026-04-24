-- Remove the temporary audit RPCs installed in 20260423230000_temp_audit_rpcs.
-- Diagnostics complete; live state verified clean.

drop function if exists public._audit_policies();
drop function if exists public._audit_rls_state();
drop function if exists public._audit_pg_stat_top();
