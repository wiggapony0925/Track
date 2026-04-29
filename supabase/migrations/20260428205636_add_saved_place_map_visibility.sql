alter table public.engine_saved_places
	add column if not exists visible boolean not null default true;

create index if not exists idx_engine_saved_places_visible_map
	on public.engine_saved_places (user_id, visible, updated_at desc)
	where visible = true;
