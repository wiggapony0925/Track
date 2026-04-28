alter table public.engine_saved_places
	add column if not exists visible_on_map boolean not null default true;

create index if not exists idx_engine_saved_places_visible_map
	on public.engine_saved_places (user_id, visible_on_map, updated_at desc)
	where visible_on_map = true;
