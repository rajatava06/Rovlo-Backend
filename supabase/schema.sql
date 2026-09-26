-- =============================================================================
--  ROVLO — Supabase schema (Postgres + RLS + Realtime + Storage)
--
--  HOW TO APPLY
--    Supabase Dashboard → SQL Editor → New query → paste this whole file → Run.
--    It is idempotent: safe to run again after edits.
--
--  WHAT IT CREATES
--    admin_emails   who is an admin (checked against the signed-in email)
--    profiles       one row per user (private: owner + admins only)
--    RPCs           discover_travelers / nearby_travelers: the safe, public slice
--                   of profiles that other travellers may see (no email/phone)
--    likes, trips   swipe actions (like / pass / save) and saved trips
--    messages       1-to-1 chat (Realtime)
--    broadcasts     admin announcements (Realtime)
--    events         Hotlist events (filled by the sync-events Edge Function)
--    storage        avatars + chat-media buckets
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. ADMINS
-- -----------------------------------------------------------------------------
create table if not exists public.admin_emails (
  email      text primary key,
  created_at timestamptz not null default now()
);

-- Admin / support emails are NOT stored in this (public) file. Add them with
-- supabase/seed_admins.sql (git-ignored, copy of seed_admins.example.sql).

-- True when the *signed-in* user's email is in admin_emails. SECURITY DEFINER so
-- RLS policies can call it without granting read access to the table.
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_emails a
    where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

alter table public.admin_emails enable row level security;
drop policy if exists "admins read admin list" on public.admin_emails;
create policy "admins read admin list" on public.admin_emails
  for select to authenticated using (public.is_admin());
-- No insert/update/delete policies: manage admins from the SQL editor only.

-- -----------------------------------------------------------------------------
-- 2. PROFILES
-- -----------------------------------------------------------------------------
create table if not exists public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  email               text,
  name                text,
  phone_number        text,
  gender              text,
  auth_method         text not null default 'google',
  travel_interests    text[] not null default '{}',
  photo_url           text,
  profile_photos      text[] not null default '{}',
  bio                 text,
  dob                 text,                      -- ISO-8601 string (as the app stores it)
  home_base           text,
  is_verified         boolean not null default false,
  subscription_tier   text not null default 'free',
  emergency_contacts  jsonb not null default '[]'::jsonb,
  is_paused           boolean not null default false,
  is_blocked          boolean not null default false,
  profile_complete    boolean not null default false,
  ghost_mode          boolean not null default false,
  lat                 double precision,
  lng                 double precision,
  city                text,
  location_updated_at timestamptz,
  fcm_token           text,
  trip_destination    text,
  trip_dates          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists profiles_city_idx on public.profiles (lower(city));
create index if not exists profiles_email_idx on public.profiles (lower(email));

-- Create the profile row automatically when someone signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  provider text := coalesce(new.raw_app_meta_data ->> 'provider', 'google');
begin
  insert into public.profiles (id, email, name, photo_url, auth_method)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture'),
    case when provider in ('google', 'apple') then provider else 'phone' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep updated_at fresh and stop normal users from un-blocking / re-keying themselves.
create or replace function public.profiles_guard()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  if auth.uid() is not null and not public.is_admin() then
    new.id                := old.id;
    new.is_blocked        := old.is_blocked;
    new.created_at        := old.created_at;
    -- Paid tier and the blue tick are decided by the server / an admin, never by
    -- the app (a modified app must not be able to grant itself either).
    new.is_verified       := old.is_verified;
    new.subscription_tier := old.subscription_tier;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard_trg on public.profiles;
create trigger profiles_guard_trg
  before update on public.profiles
  for each row execute function public.profiles_guard();

-- Same protection when a profile row is created by the app.
create or replace function public.profiles_guard_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.is_verified       := false;
    new.subscription_tier := 'free';
    new.is_blocked        := false;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard_insert_trg on public.profiles;
create trigger profiles_guard_insert_trg
  before insert on public.profiles
  for each row execute function public.profiles_guard_insert();

alter table public.profiles enable row level security;

drop policy if exists "profiles select own or admin" on public.profiles;
create policy "profiles select own or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());

drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles insert own" on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists "profiles update own or admin" on public.profiles;
create policy "profiles update own or admin" on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());

drop policy if exists "profiles delete own or admin" on public.profiles;
create policy "profiles delete own or admin" on public.profiles
  for delete to authenticated using (id = auth.uid() or public.is_admin());

-- Helper: age in years from the ISO dob string (null if unparsable).
create or replace function public.age_from_dob(p_dob text)
returns int
language sql stable
as $$
  select case
    when p_dob ~ '^\d{4}-\d{2}-\d{2}'
    then date_part('year', age(left(p_dob, 10)::date))::int
  end;
$$;

create or replace function public.haversine_km(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision
language sql immutable
as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- -----------------------------------------------------------------------------
-- 2b. LIKES (declared before the functions that read it)
-- -----------------------------------------------------------------------------
create table if not exists public.likes (
  from_user  uuid not null references auth.users (id) on delete cascade,
  to_user    uuid not null references auth.users (id) on delete cascade,
  kind       text not null check (kind in ('like', 'pass', 'save')),
  created_at timestamptz not null default now(),
  primary key (from_user, to_user, kind),
  check (from_user <> to_user)
);
create index if not exists likes_to_idx on public.likes (to_user, kind);

alter table public.likes enable row level security;
drop policy if exists "likes select own" on public.likes;
create policy "likes select own" on public.likes
  for select to authenticated using (from_user = auth.uid());
drop policy if exists "likes insert own" on public.likes;
create policy "likes insert own" on public.likes
  for insert to authenticated with check (from_user = auth.uid());
drop policy if exists "likes delete own" on public.likes;
create policy "likes delete own" on public.likes
  for delete to authenticated using (from_user = auth.uid());

-- -----------------------------------------------------------------------------
-- 3. PUBLIC TRAVELLER DATA (what other users are allowed to see)
--    Email, phone, exact location, fcm token etc. are NEVER exposed here.
-- -----------------------------------------------------------------------------

-- Cards for the Discover feed. Excludes me, blocked/paused/incomplete profiles
-- and anyone I already liked / passed / saved.
create or replace function public.discover_travelers(
  p_destination text default null,
  p_limit int default 50
)
returns table (
  id uuid, name text, gender text, age int, bio text, photo_url text,
  profile_photos text[], travel_interests text[], home_base text,
  is_verified boolean, city text, trip_destination text, trip_dates text,
  distance_km double precision
)
language sql stable security definer
set search_path = public
as $$
  with me as (
    select lat, lng from public.profiles where id = auth.uid()
  )
  select p.id, p.name, p.gender, public.age_from_dob(p.dob), p.bio, p.photo_url,
         p.profile_photos, p.travel_interests, p.home_base,
         p.is_verified, p.city, p.trip_destination, p.trip_dates,
         case when me.lat is not null and p.lat is not null and not p.ghost_mode
              then public.haversine_km(me.lat, me.lng, p.lat, p.lng) end
  from public.profiles p
  left join me on true
  where auth.uid() is not null
    and p.id <> auth.uid()
    and not p.is_blocked and not p.is_paused and p.profile_complete
    and not exists (select 1 from public.likes l
                    where l.from_user = auth.uid() and l.to_user = p.id)
    and (
      p_destination is null or p_destination = ''
      or p.trip_destination ilike '%' || p_destination || '%'
      or p.city             ilike '%' || p_destination || '%'
      or p.home_base        ilike '%' || p_destination || '%'
    )
  order by 14 asc nulls last, p.created_at desc
  limit greatest(p_limit, 1);
$$;

-- Pins for the map: everybody who is sharing their location. Coordinates are
-- rounded (~100 m). Only Ghost Mode (and blocked / paused / incomplete profiles)
-- hides someone: a person stays on the map at their LAST live location until
-- the next time they open the app and it is refreshed. location_updated_at lets
-- the app say "last live 3 hours ago".
-- (the return type changed over time, so drop first — keeps re-runs working)
drop function if exists public.nearby_travelers(double precision, double precision, double precision, int);
create function public.nearby_travelers(
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision default 25,
  p_limit int default 60
)
returns table (
  id uuid, name text, age int, photo_url text, is_verified boolean,
  city text, bio text, lat double precision, lng double precision,
  distance_km double precision, location_updated_at timestamptz
)
language sql stable security definer
set search_path = public
as $$
  select p.id, p.name, public.age_from_dob(p.dob), p.photo_url, p.is_verified,
         p.city, p.bio,
         round(p.lat::numeric, 3)::double precision,
         round(p.lng::numeric, 3)::double precision,
         public.haversine_km(p_lat, p_lng, p.lat, p.lng),
         p.location_updated_at
  from public.profiles p
  where auth.uid() is not null
    and p.id <> auth.uid()
    and p.lat is not null and p.lng is not null
    and not p.ghost_mode and not p.is_blocked and not p.is_paused
    and p.profile_complete
    and public.haversine_km(p_lat, p_lng, p.lat, p.lng) <= p_radius_km
  order by 10 asc
  limit greatest(p_limit, 1);
$$;

-- -----------------------------------------------------------------------------
-- 4. LIKES / PASSES / SAVES / MATCHES / TRIPS
-- -----------------------------------------------------------------------------
-- Record a swipe. Returns true when it created a mutual match.
create or replace function public.record_swipe(p_to uuid, p_kind text)
returns boolean
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_kind not in ('like', 'pass', 'save') then raise exception 'bad kind'; end if;
  insert into public.likes (from_user, to_user, kind)
  values (auth.uid(), p_to, p_kind)
  on conflict do nothing;
  if p_kind = 'like' then
    return exists (select 1 from public.likes
                   where from_user = p_to and to_user = auth.uid() and kind = 'like');
  end if;
  return false;
end;
$$;

create or replace function public.are_matched(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.likes where from_user = a and to_user = b and kind = 'like')
     and exists (select 1 from public.likes where from_user = b and to_user = a and kind = 'like');
$$;

create or replace function public.my_matches()
returns table (id uuid, name text, photo_url text, is_verified boolean, matched_at timestamptz)
language sql stable security definer
set search_path = public
as $$
  select p.id, p.name, p.photo_url, p.is_verified, greatest(l1.created_at, l2.created_at)
  from public.likes l1
  join public.likes l2
    on l2.from_user = l1.to_user and l2.to_user = l1.from_user and l2.kind = 'like'
  join public.profiles p on p.id = l1.to_user
  where l1.from_user = auth.uid() and l1.kind = 'like' and not p.is_blocked
  order by 5 desc;
$$;

create or replace function public.my_saved_travelers()
returns table (
  id uuid, name text, gender text, age int, bio text, photo_url text,
  profile_photos text[], travel_interests text[], home_base text,
  is_verified boolean, city text, trip_destination text, trip_dates text
)
language sql stable security definer
set search_path = public
as $$
  select p.id, p.name, p.gender, public.age_from_dob(p.dob), p.bio, p.photo_url,
         p.profile_photos, p.travel_interests, p.home_base,
         p.is_verified, p.city, p.trip_destination, p.trip_dates
  from public.likes l
  join public.profiles p on p.id = l.to_user
  where l.from_user = auth.uid() and l.kind = 'save' and not p.is_blocked
  order by l.created_at desc;
$$;

create table if not exists public.trips (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  destination text not null,
  travel_week text,
  travel_month text,
  travel_year text,
  created_at  timestamptz not null default now()
);
alter table public.trips enable row level security;
drop policy if exists "trips own" on public.trips;
create policy "trips own" on public.trips
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 5. CHAT
-- -----------------------------------------------------------------------------
create table if not exists public.messages (
  id           uuid primary key default gen_random_uuid(),
  sender_id    uuid not null references auth.users (id) on delete cascade,
  recipient_id uuid not null references auth.users (id) on delete cascade,
  body         text not null default '',
  image_url    text,
  created_at   timestamptz not null default now(),
  read_at      timestamptz,
  check (sender_id <> recipient_id),
  check (length(body) <= 4000)
);
create index if not exists messages_recipient_idx on public.messages (recipient_id, created_at desc);
create index if not exists messages_sender_idx on public.messages (sender_id, created_at desc);

alter table public.messages enable row level security;
drop policy if exists "messages read own" on public.messages;
create policy "messages read own" on public.messages
  for select to authenticated
  using (sender_id = auth.uid() or recipient_id = auth.uid());

-- Only matched, non-blocked users can message each other.
drop policy if exists "messages send to matches" on public.messages;
create policy "messages send to matches" on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.are_matched(sender_id, recipient_id)
    and not exists (select 1 from public.profiles where id = sender_id and is_blocked)
  );
-- No update/delete policies; reading is done through mark_conversation_read().

create or replace function public.mark_conversation_read(p_peer uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.messages set read_at = now()
  where recipient_id = auth.uid() and sender_id = p_peer and read_at is null;
$$;

-- (section 14 adds columns to the result, so the old shape must be dropped first
--  or re-running this file would fail)
drop function if exists public.my_conversations();
create function public.my_conversations()
returns table (
  peer_id uuid, peer_name text, peer_photo text, peer_verified boolean,
  last_body text, last_image_url text, last_at timestamptz,
  last_sender uuid, unread_count int
)
language sql stable security definer
set search_path = public
as $$
  with mine as (
    select case when m.sender_id = auth.uid() then m.recipient_id else m.sender_id end as peer,
           m.*
    from public.messages m
    where m.sender_id = auth.uid() or m.recipient_id = auth.uid()
  ),
  last_msg as (
    select distinct on (peer) peer, body, image_url, created_at, sender_id
    from mine order by peer, created_at desc
  ),
  unread as (
    select peer, count(*)::int as n from mine
    where recipient_id = auth.uid() and read_at is null group by peer
  )
  select p.id, p.name, p.photo_url, p.is_verified,
         l.body, l.image_url, l.created_at, l.sender_id, coalesce(u.n, 0)
  from last_msg l
  join public.profiles p on p.id = l.peer
  left join unread u on u.peer = l.peer
  order by l.created_at desc;
$$;

-- -----------------------------------------------------------------------------
-- 6. ADMIN BROADCASTS
-- -----------------------------------------------------------------------------
create table if not exists public.broadcasts (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  body            text not null,
  type            text not null default 'announcement',
  target_audience text not null default 'All Users',
  sent_by         text,
  sent_at         timestamptz not null default now()
);
alter table public.broadcasts enable row level security;
drop policy if exists "broadcasts read" on public.broadcasts;
create policy "broadcasts read" on public.broadcasts
  for select to authenticated using (true);
drop policy if exists "broadcasts admin write" on public.broadcasts;
create policy "broadcasts admin write" on public.broadcasts
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- -----------------------------------------------------------------------------
-- 7. EVENTS (Hotlist)
-- -----------------------------------------------------------------------------
create table if not exists public.events (
  id             uuid primary key default gen_random_uuid(),
  source         text not null default 'admin',     -- serpapi | ticketmaster | admin
  external_id    text,
  title          text not null,
  category       text not null default 'Events',
  city           text not null,
  city_key       text not null,                     -- lower-case, trimmed
  venue          text,
  address        text,
  lat            double precision,
  lng            double precision,
  starts_at      timestamptz,
  ends_at        timestamptz,
  date_label     text,                              -- used when only free text is known
  time_label     text,
  image_url      text,
  price_text     text,
  description    text,
  lineup         text[] not null default '{}',
  ticket_url     text,
  google_url     text,
  district_url   text,
  tags           text[] not null default '{}',
  rating         numeric(2,1),
  attending_text text,
  theme_color    text,
  is_featured    boolean not null default false,
  is_active      boolean not null default true,
  fetched_at     timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  unique (source, external_id)
);
create index if not exists events_city_idx on public.events (city_key, starts_at);

alter table public.events enable row level security;
drop policy if exists "events read" on public.events;
create policy "events read" on public.events
  for select to authenticated using (is_active or public.is_admin());
drop policy if exists "events admin write" on public.events;
create policy "events admin write" on public.events
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Cache bookkeeping for the sync-events Edge Function (service role only).
create table if not exists public.event_sync_log (
  city_key     text primary key,
  provider     text,
  fetched_at   timestamptz not null default now(),
  result_count int not null default 0
);
alter table public.event_sync_log enable row level security;

create table if not exists public.saved_events (
  user_id  uuid not null references auth.users (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);
alter table public.saved_events enable row level security;
drop policy if exists "saved events own" on public.saved_events;
create policy "saved events own" on public.saved_events
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 8. ADMIN HELPERS
-- -----------------------------------------------------------------------------
create or replace function public.admin_stats()
returns json
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return (
    select json_build_object(
      'total',    count(*),
      'active',   count(*) filter (where not is_blocked and not is_paused),
      'blocked',  count(*) filter (where is_blocked),
      'verified', count(*) filter (where is_verified),
      'complete', count(*) filter (where profile_complete),
      'newToday', count(*) filter (where created_at > now() - interval '1 day')
    ) from public.profiles
  );
end;
$$;

-- Removes a user completely (auth account + profile + all their data).
create or replace function public.admin_delete_user(p_user uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  delete from auth.users where id = p_user;
end;
$$;

-- Lets a user delete their own account (App Store / Play Store requirement).
create or replace function public.delete_my_account()
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from auth.users where id = auth.uid();
end;
$$;

-- -----------------------------------------------------------------------------
-- 9. PERMISSIONS
-- -----------------------------------------------------------------------------
revoke all on function public.admin_stats()            from public, anon;
revoke all on function public.admin_delete_user(uuid)  from public, anon;
revoke all on function public.delete_my_account()      from public, anon;
revoke all on function public.record_swipe(uuid, text) from public, anon;
revoke all on function public.my_matches()             from public, anon;
revoke all on function public.my_saved_travelers()     from public, anon;
revoke all on function public.my_conversations()       from public, anon;
revoke all on function public.mark_conversation_read(uuid) from public, anon;
revoke all on function public.discover_travelers(text, int) from public, anon;
revoke all on function public.nearby_travelers(double precision, double precision, double precision, int) from public, anon;

grant execute on function public.is_admin()            to authenticated;
grant execute on function public.admin_stats()         to authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;
grant execute on function public.delete_my_account()   to authenticated;
grant execute on function public.record_swipe(uuid, text) to authenticated;
grant execute on function public.are_matched(uuid, uuid) to authenticated;
grant execute on function public.my_matches()          to authenticated;
grant execute on function public.my_saved_travelers()  to authenticated;
grant execute on function public.my_conversations()    to authenticated;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
grant execute on function public.discover_travelers(text, int) to authenticated;
grant execute on function public.nearby_travelers(double precision, double precision, double precision, int) to authenticated;

-- -----------------------------------------------------------------------------
-- 10. REALTIME
-- -----------------------------------------------------------------------------
do $$
begin
  begin alter publication supabase_realtime add table public.messages;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.broadcasts; exception when duplicate_object then null; end;
end $$;

-- -----------------------------------------------------------------------------
-- 11. STORAGE (profile photos + chat images)
--     Files live under <bucket>/<user-id>/<random>.jpg ; only the owner writes.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',    'avatars',    true, 8388608, array['image/jpeg','image/png','image/webp','image/heic']),
  ('chat-media', 'chat-media', true, 8388608, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "rovlo media read" on storage.objects;
create policy "rovlo media read" on storage.objects
  for select using (bucket_id in ('avatars', 'chat-media'));

drop policy if exists "rovlo media insert own folder" on storage.objects;
create policy "rovlo media insert own folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('avatars', 'chat-media')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "rovlo media update own folder" on storage.objects;
create policy "rovlo media update own folder" on storage.objects
  for update to authenticated
  using (
    bucket_id in ('avatars', 'chat-media')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "rovlo media delete own folder" on storage.objects;
create policy "rovlo media delete own folder" on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('avatars', 'chat-media')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- -----------------------------------------------------------------------------
-- 12. SUPPORT CHAT (users <-> Rovlo Support)
--     Every user has one private thread with "Rovlo Support". Only support
--     agents (emails in support_agents) can read all threads and reply.
-- -----------------------------------------------------------------------------
create table if not exists public.support_agents (
  email      text primary key,
  created_at timestamptz not null default now()
);
-- Support agents are seeded from supabase/seed_admins.sql (git-ignored).

create or replace function public.is_support_agent()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.support_agents a
    where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

alter table public.support_agents enable row level security;
drop policy if exists "agents read agent list" on public.support_agents;
create policy "agents read agent list" on public.support_agents
  for select to authenticated using (public.is_support_agent());

create table if not exists public.support_messages (
  id           uuid primary key default gen_random_uuid(),
  thread_user  uuid not null references auth.users (id) on delete cascade,
  sender_id    uuid not null references auth.users (id) on delete cascade,
  from_support boolean not null default false,
  body         text not null default '' check (length(body) <= 4000),
  image_url    text,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);
create index if not exists support_thread_idx
  on public.support_messages (thread_user, created_at);

alter table public.support_messages enable row level security;

drop policy if exists "support read" on public.support_messages;
create policy "support read" on public.support_messages
  for select to authenticated
  using (thread_user = auth.uid() or public.is_support_agent());

drop policy if exists "support write" on public.support_messages;
create policy "support write" on public.support_messages
  for insert to authenticated
  with check (
    sender_id = auth.uid() and (
      (thread_user = auth.uid() and not from_support)
      or (from_support and public.is_support_agent())
    )
  );
-- No update/delete policies; read receipts go through mark_support_read().

-- Marks the *other side's* messages as read.
--   customer: mark_support_read()          -> support replies become read
--   agent:    mark_support_read(<user id>) -> that customer's messages become read
create or replace function public.mark_support_read(p_thread uuid default null)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if p_thread is not null and public.is_support_agent() then
    update public.support_messages set read_at = now()
    where thread_user = p_thread and not from_support and read_at is null;
  else
    update public.support_messages set read_at = now()
    where thread_user = auth.uid() and from_support and read_at is null;
  end if;
end;
$$;

-- Agent inbox: one row per customer, newest first.
create or replace function public.support_threads()
returns table (
  thread_user uuid, name text, email text, photo_url text,
  last_body text, last_image_url text, last_at timestamptz,
  last_from_support boolean, unread_count int
)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_support_agent() then raise exception 'forbidden'; end if;
  return query
  with last_msg as (
    select distinct on (m.thread_user)
           m.thread_user, m.body, m.image_url, m.created_at, m.from_support
    from public.support_messages m
    order by m.thread_user, m.created_at desc
  ),
  unread as (
    select m.thread_user, count(*)::int as n
    from public.support_messages m
    where not m.from_support and m.read_at is null
    group by m.thread_user
  )
  select l.thread_user, p.name, p.email, p.photo_url,
         l.body, l.image_url, l.created_at, l.from_support, coalesce(u.n, 0)
  from last_msg l
  left join public.profiles p on p.id = l.thread_user
  left join unread u on u.thread_user = l.thread_user
  order by l.created_at desc;
end;
$$;

revoke all on function public.mark_support_read(uuid) from public, anon;
revoke all on function public.support_threads() from public, anon;
grant execute on function public.is_support_agent() to authenticated;
grant execute on function public.mark_support_read(uuid) to authenticated;
grant execute on function public.support_threads() to authenticated;

do $$
begin
  begin alter publication supabase_realtime add table public.support_messages;
  exception when duplicate_object then null; end;
end $$;

-- -----------------------------------------------------------------------------
-- 13. LIKE REQUESTS (who liked me / who I liked, waiting for approval)
--     A like is a request. Chat opens only when BOTH people liked each other
--     (see are_matched + the "messages send to matches" policy).
-- -----------------------------------------------------------------------------

-- The person being liked may see that a like arrived (never passes / saves).
drop policy if exists "likes select received" on public.likes;
create policy "likes select received" on public.likes
  for select to authenticated
  using (to_user = auth.uid() and kind = 'like');

-- People who liked me and are still waiting for my answer.
create or replace function public.my_likes_received()
returns table (
  id uuid, name text, photo_url text, is_verified boolean, age int,
  city text, liked_at timestamptz
)
language sql stable security definer
set search_path = public
as $$
  select p.id, p.name, p.photo_url, p.is_verified, public.age_from_dob(p.dob),
         p.city, l.created_at
  from public.likes l
  join public.profiles p on p.id = l.from_user
  where l.to_user = auth.uid() and l.kind = 'like'
    and not p.is_blocked
    and not exists (select 1 from public.likes m
                    where m.from_user = auth.uid() and m.to_user = l.from_user
                      and m.kind in ('like', 'pass'))
  order by l.created_at desc;
$$;

-- People I liked who have not answered yet.
create or replace function public.my_likes_sent()
returns table (
  id uuid, name text, photo_url text, is_verified boolean, age int,
  city text, liked_at timestamptz
)
language sql stable security definer
set search_path = public
as $$
  select p.id, p.name, p.photo_url, p.is_verified, public.age_from_dob(p.dob),
         p.city, l.created_at
  from public.likes l
  join public.profiles p on p.id = l.to_user
  where l.from_user = auth.uid() and l.kind = 'like'
    and not p.is_blocked
    and not exists (select 1 from public.likes m
                    where m.from_user = l.to_user and m.to_user = auth.uid()
                      and m.kind = 'like')
  order by l.created_at desc;
$$;

revoke all on function public.my_likes_received() from public, anon;
revoke all on function public.my_likes_sent() from public, anon;
grant execute on function public.my_likes_received() to authenticated;
grant execute on function public.my_likes_sent() to authenticated;

do $$
begin
  begin alter publication supabase_realtime add table public.likes;
  exception when duplicate_object then null; end;
end $$;

-- =============================================================================
-- 6. TRIPS v2 — "Going to…" (destination + travel week, visible to other users)
--    Safe to re-run. Other people never read the trips table directly: they get
--    the privacy-safe rows from travelers_going_to() below.
-- =============================================================================
alter table public.trips add column if not exists lat        double precision;
alter table public.trips add column if not exists lng        double precision;
alter table public.trips add column if not exists start_date date;
alter table public.trips add column if not exists end_date   date;

-- "2nd Week" + "Oct" + "2026"  ->  8 Oct 2026 .. 14 Oct 2026  (4th week = day 22 .. month end)
create or replace function public.trip_window(p_week text, p_month text, p_year text)
returns table (start_date date, end_date date)
language plpgsql stable
as $$
declare
  n int := least(greatest(coalesce(nullif(substring(p_week from '\d'), '')::int, 1), 1), 4);
  first_day date := make_date(p_year::int, extract(month from to_date(p_month, 'Mon'))::int, 1);
begin
  start_date := first_day + 7 * (n - 1);
  end_date := case when n >= 4 then (first_day + interval '1 month - 1 day')::date
                   else start_date + 6 end;
  return next;
end;
$$;

-- Fill the new columns for trips saved by older app versions.
update public.trips t
   set start_date = (select w.start_date
                       from public.trip_window(t.travel_week, t.travel_month, t.travel_year) w),
       end_date   = (select w.end_date
                       from public.trip_window(t.travel_week, t.travel_month, t.travel_year) w)
 where t.start_date is null
   and t.travel_month ~* '^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)$'
   and t.travel_year ~ '^\d{4}$';

-- One row per (person, place, week): drop old duplicates, then enforce it.
delete from public.trips a
 using public.trips b
 where a.user_id = b.user_id
   and lower(a.destination) = lower(b.destination)
   and a.start_date is not distinct from b.start_date
   and a.id < b.id;
create unique index if not exists trips_user_dest_start_uq
  on public.trips (user_id, lower(destination), start_date);
create index if not exists trips_upcoming_idx on public.trips (end_date);

-- Keeps profiles.trip_destination / trip_dates pointing at my next upcoming
-- trip (that is what other users see on my card).
create or replace function public.sync_profile_trip(p_user uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.profiles p set
    trip_destination = (select t.destination from public.trips t
                        where t.user_id = p_user and t.end_date >= current_date
                        order by t.start_date limit 1),
    trip_dates = (select t.travel_week || ', ' || t.travel_month || ' ' || t.travel_year
                  from public.trips t
                  where t.user_id = p_user and t.end_date >= current_date
                  order by t.start_date limit 1)
  where p.id = p_user;
$$;
revoke all on function public.sync_profile_trip(uuid) from public, anon, authenticated;

-- Save (or update) one of my trips. Returns the trip id.
create or replace function public.save_trip(
  p_destination text,
  p_lat double precision,
  p_lng double precision,
  p_week text,
  p_month text,
  p_year text
) returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  w record;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if coalesce(trim(p_destination), '') = '' then raise exception 'destination required'; end if;

  select * into w from public.trip_window(p_week, p_month, p_year);
  if w.end_date < current_date then raise exception 'trip dates are in the past'; end if;

  insert into public.trips
    (user_id, destination, lat, lng, travel_week, travel_month, travel_year, start_date, end_date)
  values
    (auth.uid(), trim(p_destination), p_lat, p_lng, p_week, p_month, p_year, w.start_date, w.end_date)
  on conflict (user_id, lower(destination), start_date)
  do update set lat = excluded.lat, lng = excluded.lng,
                travel_week = excluded.travel_week, travel_month = excluded.travel_month,
                travel_year = excluded.travel_year, end_date = excluded.end_date
  returning id into v_id;

  perform public.sync_profile_trip(auth.uid());
  return v_id;
end;
$$;

create or replace function public.delete_trip(p_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.trips where id = p_id and user_id = auth.uid();
  perform public.sync_profile_trip(auth.uid());
end;
$$;

-- People going to the same place, best date match first:
--   'same'  = their week overlaps mine
--   'near'  = within 30 days of mine
--   'later' = any other upcoming trip to that place
-- "Same place" = within 75 km of the searched point (or, for trips saved without
-- coordinates, the same place name).
-- Then closest to me first. Excludes me, blocked/paused/incomplete profiles and
-- people I already liked / passed / saved.
create or replace function public.travelers_going_to(
  p_destination text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_week text default null,
  p_month text default null,
  p_year text default null,
  p_limit int default 60
)
returns table (
  id uuid, name text, gender text, age int, bio text, photo_url text,
  profile_photos text[], travel_interests text[], home_base text,
  is_verified boolean, city text, trip_destination text, trip_dates text,
  distance_km double precision, date_match text
)
language sql stable security definer
set search_path = public
as $$
  with me as (
    select lat, lng from public.profiles where id = auth.uid()
  ),
  win as (
    select * from public.trip_window(p_week, p_month, p_year)
  ),
  cand as (
    select distinct on (t.user_id)
           t.user_id, t.destination, t.travel_week, t.travel_month, t.travel_year,
           case
             when win.start_date is null then 2
             when t.start_date <= win.end_date and t.end_date >= win.start_date then 0
             when t.start_date <= win.end_date + 30 and t.end_date >= win.start_date - 30 then 1
             else 2
           end as rk,
           case when win.start_date is null then 0
                else greatest(t.start_date - win.end_date, win.start_date - t.end_date, 0)
           end as gap
    from public.trips t
    cross join win
    where t.end_date >= current_date
      and t.user_id <> auth.uid()
      and (
        (t.lat is not null and p_lat is not null
           and public.haversine_km(t.lat, t.lng, p_lat, p_lng) <= 75)
        or ((t.lat is null or p_lat is null)
            and lower(split_part(t.destination, ',', 1)) = lower(split_part(p_destination, ',', 1)))
      )
    order by t.user_id, rk, gap, t.start_date
  )
  select p.id, p.name, p.gender, public.age_from_dob(p.dob), p.bio, p.photo_url,
         p.profile_photos, p.travel_interests, p.home_base, p.is_verified, p.city,
         c.destination,
         c.travel_week || ', ' || c.travel_month || ' ' || c.travel_year,
         case when me.lat is not null and p.lat is not null and not p.ghost_mode
              then public.haversine_km(me.lat, me.lng, p.lat, p.lng) end,
         case c.rk when 0 then 'same' when 1 then 'near' else 'later' end
  from cand c
  join public.profiles p on p.id = c.user_id
  left join me on true
  where auth.uid() is not null
    and not p.is_blocked and not p.is_paused and p.profile_complete
    and not exists (select 1 from public.likes l
                    where l.from_user = auth.uid() and l.to_user = p.id)
  order by c.rk, c.gap, 14 asc nulls last, p.created_at desc
  limit greatest(p_limit, 1);
$$;

-- The discover feed / saved list now show each person's next *upcoming* trip
-- (trips whose week already passed disappear on their own).
create or replace function public.discover_travelers(
  p_destination text default null,
  p_limit int default 50
)
returns table (
  id uuid, name text, gender text, age int, bio text, photo_url text,
  profile_photos text[], travel_interests text[], home_base text,
  is_verified boolean, city text, trip_destination text, trip_dates text,
  distance_km double precision
)
language sql stable security definer
set search_path = public
as $$
  with me as (
    select lat, lng from public.profiles where id = auth.uid()
  )
  select p.id, p.name, p.gender, public.age_from_dob(p.dob), p.bio, p.photo_url,
         p.profile_photos, p.travel_interests, p.home_base,
         p.is_verified, p.city, nt.destination, nt.dates,
         case when me.lat is not null and p.lat is not null and not p.ghost_mode
              then public.haversine_km(me.lat, me.lng, p.lat, p.lng) end
  from public.profiles p
  left join me on true
  left join lateral (
    select t.destination,
           t.travel_week || ', ' || t.travel_month || ' ' || t.travel_year as dates
    from public.trips t
    where t.user_id = p.id and t.end_date >= current_date
    order by t.start_date limit 1
  ) nt on true
  where auth.uid() is not null
    and p.id <> auth.uid()
    and not p.is_blocked and not p.is_paused and p.profile_complete
    and not exists (select 1 from public.likes l
                    where l.from_user = auth.uid() and l.to_user = p.id)
    and (
      p_destination is null or p_destination = ''
      or nt.destination ilike '%' || p_destination || '%'
      or p.city         ilike '%' || p_destination || '%'
      or p.home_base    ilike '%' || p_destination || '%'
    )
  order by 14 asc nulls last, p.created_at desc
  limit greatest(p_limit, 1);
$$;

create or replace function public.my_saved_travelers()
returns table (
  id uuid, name text, gender text, age int, bio text, photo_url text,
  profile_photos text[], travel_interests text[], home_base text,
  is_verified boolean, city text, trip_destination text, trip_dates text
)
language sql stable security definer
set search_path = public
as $$
  select p.id, p.name, p.gender, public.age_from_dob(p.dob), p.bio, p.photo_url,
         p.profile_photos, p.travel_interests, p.home_base,
         p.is_verified, p.city, nt.destination, nt.dates
  from public.likes l
  join public.profiles p on p.id = l.to_user
  left join lateral (
    select t.destination,
           t.travel_week || ', ' || t.travel_month || ' ' || t.travel_year as dates
    from public.trips t
    where t.user_id = p.id and t.end_date >= current_date
    order by t.start_date limit 1
  ) nt on true
  where l.from_user = auth.uid() and l.kind = 'save' and not p.is_blocked
  order by l.created_at desc;
$$;

revoke all on function public.save_trip(text, double precision, double precision, text, text, text) from public, anon;
revoke all on function public.delete_trip(uuid) from public, anon;
revoke all on function public.travelers_going_to(text, double precision, double precision, text, text, text, int) from public, anon;
grant execute on function public.save_trip(text, double precision, double precision, text, text, text) to authenticated;
grant execute on function public.delete_trip(uuid) to authenticated;
grant execute on function public.travelers_going_to(text, double precision, double precision, text, text, text, int) to authenticated;
grant execute on function public.discover_travelers(text, int) to authenticated;
grant execute on function public.my_saved_travelers() to authenticated;

-- =============================================================================
-- OPTIONAL: nightly cleanup of past events (enable the pg_cron extension first:
-- Dashboard → Database → Extensions → pg_cron)
--
--   select cron.schedule('rovlo-clean-old-events', '0 3 * * *',
--     $$ delete from public.events
--        where source <> 'admin' and starts_at < now() - interval '2 days' $$);
-- =============================================================================

-- =============================================================================
-- 14. CHAT REQUESTS · END-TO-END ENCRYPTION · DELIVERY / READ RECEIPTS
--     Safe to re-run.
--
--   chat_requests  "may I chat with you?" — pending → accepted / declined
--   user_keys      each user's PUBLIC encryption key (the private key never
--                  leaves the phone). Messages are encrypted on the sender's
--                  device and can only be decrypted on the recipient's device.
--   messages       + is_encrypted / sender_pub / recipient_pub / delivered_at
--   chat-secure    private bucket for encrypted photos
-- =============================================================================

-- 14a. Public keys ------------------------------------------------------------
create table if not exists public.user_keys (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  public_key text not null check (length(public_key) between 40 and 64),
  updated_at timestamptz not null default now()
);
alter table public.user_keys enable row level security;

drop policy if exists "keys read" on public.user_keys;
create policy "keys read" on public.user_keys
  for select to authenticated using (true);
drop policy if exists "keys insert own" on public.user_keys;
create policy "keys insert own" on public.user_keys
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "keys update own" on public.user_keys;
create policy "keys update own" on public.user_keys
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 14b. Chat requests ----------------------------------------------------------
create table if not exists public.chat_requests (
  id           uuid primary key default gen_random_uuid(),
  from_user    uuid not null references auth.users (id) on delete cascade,
  to_user      uuid not null references auth.users (id) on delete cascade,
  status       text not null default 'pending'
               check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (from_user <> to_user)
);
-- One row per pair of people, whoever asked first.
create unique index if not exists chat_requests_pair_uq
  on public.chat_requests (least(from_user, to_user), greatest(from_user, to_user));
create index if not exists chat_requests_to_idx   on public.chat_requests (to_user, status);
create index if not exists chat_requests_from_idx on public.chat_requests (from_user, status);

alter table public.chat_requests enable row level security;
drop policy if exists "chat requests read own" on public.chat_requests;
create policy "chat requests read own" on public.chat_requests
  for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());
-- No insert / update / delete policies: everything goes through the RPCs below.

-- True when the two people may exchange messages (accepted chat request, or the
-- older mutual-like "match").
create or replace function public.can_chat(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
           select 1 from public.chat_requests r
           where r.status = 'accepted'
             and ((r.from_user = a and r.to_user = b) or (r.from_user = b and r.to_user = a))
         )
      or public.are_matched(a, b);
$$;

-- Ask somebody to chat. Returns 'pending' or 'accepted'.
--   * they already asked me  -> accepted straight away
--   * declined by them       -> can ask again after 24 hours
create or replace function public.send_chat_request(p_to uuid)
returns text
language plpgsql security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  r  public.chat_requests%rowtype;
  v_open int;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if p_to is null or p_to = me then raise exception 'invalid recipient'; end if;
  if exists (select 1 from public.profiles where id = me and is_blocked) then
    raise exception 'blocked';
  end if;
  if not exists (select 1 from public.profiles where id = p_to and not is_blocked) then
    raise exception 'user not found';
  end if;

  if public.can_chat(me, p_to) then return 'accepted'; end if;

  select * into r from public.chat_requests
   where least(from_user, to_user) = least(me, p_to)
     and greatest(from_user, to_user) = greatest(me, p_to);

  if found then
    if r.status = 'accepted' then return 'accepted'; end if;

    if r.status = 'pending' then
      if r.to_user = me then
        update public.chat_requests
           set status = 'accepted', responded_at = now() where id = r.id;
        return 'accepted';
      end if;
      return 'pending';
    end if;

    if r.status = 'declined' and r.from_user = me
       and r.responded_at > now() - interval '24 hours' then
      raise exception 'declined_recently';
    end if;

    -- declined long ago / cancelled: open it again (in my direction).
    update public.chat_requests
       set from_user = me, to_user = p_to, status = 'pending',
           created_at = now(), responded_at = null
     where id = r.id;
    return 'pending';
  end if;

  select count(*) into v_open from public.chat_requests
   where from_user = me and status = 'pending';
  if v_open >= 30 then raise exception 'too_many_pending'; end if;

  insert into public.chat_requests (from_user, to_user) values (me, p_to);
  return 'pending';
end;
$$;

-- Accept or decline a request somebody sent me.
create or replace function public.respond_chat_request(p_from uuid, p_accept boolean)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.chat_requests
     set status = case when p_accept then 'accepted' else 'declined' end,
         responded_at = now()
   where from_user = p_from and to_user = auth.uid() and status = 'pending';
  if not found then raise exception 'no pending request'; end if;
end;
$$;

-- Take back a request I sent (while it is still pending).
create or replace function public.cancel_chat_request(p_to uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.chat_requests
     set status = 'cancelled', responded_at = now()
   where from_user = auth.uid() and to_user = p_to and status = 'pending';
end;
$$;

-- Everything about my requests, with the other person's public card.
--   direction 'in'  = they asked me     'out' = I asked them
-- Declined requests are only returned to the person who asked.
create or replace function public.my_chat_requests()
returns table (
  id uuid, direction text, status text,
  peer_id uuid, name text, photo_url text, is_verified boolean, age int, city text,
  created_at timestamptz, responded_at timestamptz
)
language sql stable security definer
set search_path = public
as $$
  select r.id,
         case when r.to_user = auth.uid() then 'in' else 'out' end,
         r.status,
         p.id, p.name, p.photo_url, p.is_verified, public.age_from_dob(p.dob), p.city,
         r.created_at, r.responded_at
  from public.chat_requests r
  join public.profiles p
    on p.id = case when r.to_user = auth.uid() then r.from_user else r.to_user end
  where (r.from_user = auth.uid() or r.to_user = auth.uid())
    and not p.is_blocked
    and (r.status in ('pending', 'accepted')
         or (r.status = 'declined' and r.from_user = auth.uid()))
  order by r.created_at desc;
$$;

-- 14c. Messages: encryption + receipts ----------------------------------------
alter table public.messages add column if not exists is_encrypted boolean not null default false;
alter table public.messages add column if not exists sender_pub    text;
alter table public.messages add column if not exists recipient_pub text;
alter table public.messages add column if not exists delivered_at  timestamptz;

-- Ciphertext is longer than the text it hides (2000 Hindi characters ≈ 8 000
-- base64 characters), so replace the old 4000-character limit whatever it is called.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.messages'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%length(body)%'
  loop
    execute format('alter table public.messages drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.messages add constraint messages_body_check check (length(body) <= 12000);
alter table public.messages drop constraint if exists messages_enc_check;
alter table public.messages add constraint messages_enc_check
  check (not is_encrypted or (sender_pub is not null and recipient_pub is not null));

create index if not exists messages_image_idx on public.messages (image_url)
  where image_url is not null;

-- Only people who may chat can message, and EVERY new message must be
-- encrypted with the keys the two people have published (plaintext is refused
-- by the database itself, whatever the client does).
drop policy if exists "messages send to matches" on public.messages;
drop policy if exists "messages send encrypted" on public.messages;
create policy "messages send encrypted" on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.can_chat(sender_id, recipient_id)
    and not exists (select 1 from public.profiles where id = sender_id and is_blocked)
    and is_encrypted
    and sender_pub    = (select k.public_key from public.user_keys k where k.user_id = sender_id)
    and recipient_pub = (select k.public_key from public.user_keys k where k.user_id = recipient_id)
  );

-- Receiver opened the chat: everything from that person is delivered + read.
create or replace function public.mark_conversation_read(p_peer uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.messages
     set read_at = now(), delivered_at = coalesce(delivered_at, now())
   where recipient_id = auth.uid() and sender_id = p_peer and read_at is null;
$$;

-- Receiver's app got the message (not necessarily opened it yet).
-- p_peer = null marks everything addressed to me.
create or replace function public.mark_delivered(p_peer uuid default null)
returns void
language sql security definer
set search_path = public
as $$
  update public.messages
     set delivered_at = now()
   where recipient_id = auth.uid() and delivered_at is null
     and (p_peer is null or sender_id = p_peer);
$$;

-- Chat list: the newest message of every conversation (still encrypted — the
-- app decrypts it on the device, so it also returns the keys it was sealed with).
drop function if exists public.my_conversations();
create function public.my_conversations()
returns table (
  peer_id uuid, peer_name text, peer_photo text, peer_verified boolean,
  last_body text, last_image_url text, last_at timestamptz,
  last_sender uuid, unread_count int,
  last_is_encrypted boolean, last_sender_pub text, last_recipient_pub text
)
language sql stable security definer
set search_path = public
as $$
  with mine as (
    select case when m.sender_id = auth.uid() then m.recipient_id else m.sender_id end as peer,
           m.*
    from public.messages m
    where m.sender_id = auth.uid() or m.recipient_id = auth.uid()
  ),
  last_msg as (
    select distinct on (peer) peer, body, image_url, created_at, sender_id,
           is_encrypted, sender_pub, recipient_pub
    from mine order by peer, created_at desc
  ),
  unread as (
    select peer, count(*)::int as n from mine
    where recipient_id = auth.uid() and read_at is null group by peer
  )
  select p.id, p.name, p.photo_url, p.is_verified,
         l.body, l.image_url, l.created_at, l.sender_id, coalesce(u.n, 0),
         l.is_encrypted, l.sender_pub, l.recipient_pub
  from last_msg l
  join public.profiles p on p.id = l.peer
  left join unread u on u.peer = l.peer
  order by l.created_at desc;
$$;

-- 14d. (map pins: see nearby_travelers in section 3 — no time limit, Ghost Mode only)

-- 14e. Encrypted photos (private bucket; the files are ciphertext) ------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-secure', 'chat-secure', false, 10485760)
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = null;

drop policy if exists "rovlo secure insert own folder" on storage.objects;
create policy "rovlo secure insert own folder" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat-secure'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- The uploader, or somebody who is a party to a message that points at the file.
drop policy if exists "rovlo secure read" on storage.objects;
create policy "rovlo secure read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat-secure'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.messages m
                 where m.image_url = 'e2ee:' || storage.objects.name)
    )
  );

drop policy if exists "rovlo secure delete own folder" on storage.objects;
create policy "rovlo secure delete own folder" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'chat-secure'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 14f. Permissions + realtime -------------------------------------------------
revoke all on function public.send_chat_request(uuid)             from public, anon;
revoke all on function public.respond_chat_request(uuid, boolean) from public, anon;
revoke all on function public.cancel_chat_request(uuid)           from public, anon;
revoke all on function public.my_chat_requests()                  from public, anon;
revoke all on function public.mark_delivered(uuid)                from public, anon;
revoke all on function public.my_conversations()                  from public, anon;
revoke all on function public.can_chat(uuid, uuid)                from public, anon;

grant execute on function public.send_chat_request(uuid)             to authenticated;
grant execute on function public.respond_chat_request(uuid, boolean) to authenticated;
grant execute on function public.cancel_chat_request(uuid)           to authenticated;
grant execute on function public.my_chat_requests()                  to authenticated;
grant execute on function public.mark_delivered(uuid)                to authenticated;
grant execute on function public.my_conversations()                  to authenticated;
grant execute on function public.can_chat(uuid, uuid)                to authenticated;

do $$
begin
  begin alter publication supabase_realtime add table public.chat_requests;
  exception when duplicate_object then null; end;
end $$;

-- =============================================================================
-- 15. PROFILE VERIFICATION (photo verification, reviewed by an admin)
--     No ID document is collected (so no Aadhaar / ID-card rules apply): the
--     user sends a straight-on selfie and a selfie doing a RANDOM pose (proves a
--     live person, not a stolen photo); the admin compares them with the profile
--     photos. Column meaning: id_doc_path = straight selfie, selfie_path = pose.
--     Safe to re-run.
--
--   verification_requests  one row per person: pending -> approved / rejected
--   verification-docs      PRIVATE bucket: only the owner and admins can read
--   submit_verification    the user sends the two files
--   admin_verification_queue / admin_review_verification
--                          admins list pending requests and approve / reject.
--                          Approving is the ONLY way is_verified becomes true.
--   The files are deleted as soon as the request is reviewed.
-- =============================================================================

create table if not exists public.verification_requests (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  id_doc_path  text,
  selfie_path  text,
  status       text not null default 'pending'
               check (status in ('pending', 'approved', 'rejected')),
  note         text,
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  text
);
alter table public.verification_requests add column if not exists challenge text;
alter table public.verification_requests enable row level security;

drop policy if exists "verification read own or admin" on public.verification_requests;
create policy "verification read own or admin" on public.verification_requests
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
-- No insert / update / delete policies: everything goes through the RPCs below.

-- The user sends their two selfies (already uploaded to their own folder).
-- (signature changed -> drop the old one first so re-runs keep working)
drop function if exists public.submit_verification(text, text);
drop function if exists public.submit_verification(text, text, text);
create function public.submit_verification(
  p_front_path text, p_pose_path text, p_challenge text default null
)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_status text;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if split_part(p_front_path, '/', 1) <> me::text
     or split_part(p_pose_path, '/', 1) <> me::text then
    raise exception 'bad file path';
  end if;

  select status into v_status from public.verification_requests where user_id = me;
  if found then
    if v_status = 'pending'  then raise exception 'already_pending'; end if;
    if v_status = 'approved' then raise exception 'already_verified'; end if;
    update public.verification_requests
       set id_doc_path = p_front_path, selfie_path = p_pose_path,
           challenge = left(p_challenge, 120),
           status = 'pending', note = null, created_at = now(),
           reviewed_at = null, reviewed_by = null
     where user_id = me;
  else
    insert into public.verification_requests (user_id, id_doc_path, selfie_path, challenge)
    values (me, p_front_path, p_pose_path, left(p_challenge, 120));
  end if;
end;
$$;

-- Admin: everybody waiting for a decision, oldest first.
drop function if exists public.admin_verification_queue();
create function public.admin_verification_queue()
returns table (
  user_id uuid, name text, email text, photo_url text, profile_photos text[],
  front_path text, pose_path text, challenge text, created_at timestamptz
)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query
  select r.user_id, p.name, p.email, p.photo_url, p.profile_photos,
         r.id_doc_path, r.selfie_path, r.challenge, r.created_at
  from public.verification_requests r
  left join public.profiles p on p.id = r.user_id
  where r.status = 'pending'
  order by r.created_at asc;
end;
$$;

-- Admin: approve (gives the blue tick) or reject. Returns the two file paths so
-- the app can delete the files right away — they are never kept after review.
create or replace function public.admin_review_verification(
  p_user uuid, p_approve boolean, p_note text default null
)
returns table (doc_path text, face_path text)
language plpgsql security definer
set search_path = public
as $$
declare
  r public.verification_requests%rowtype;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;

  select * into r from public.verification_requests
   where user_id = p_user and status = 'pending' for update;
  if not found then raise exception 'no pending request'; end if;

  update public.verification_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         note = nullif(trim(coalesce(p_note, '')), ''),
         reviewed_at = now(),
         reviewed_by = auth.jwt() ->> 'email',
         id_doc_path = null, selfie_path = null
   where user_id = p_user;

  if p_approve then
    update public.profiles set is_verified = true where id = p_user;
  end if;

  return query select r.id_doc_path, r.selfie_path;
end;
$$;

-- Private bucket for the two photos.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-docs', 'verification-docs', false, 8388608,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "verification files insert own" on storage.objects;
create policy "verification files insert own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'verification-docs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "verification files read" on storage.objects;
create policy "verification files read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'verification-docs'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())
  );

drop policy if exists "verification files delete" on storage.objects;
create policy "verification files delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'verification-docs'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())
  );

revoke all on function public.submit_verification(text, text, text)         from public, anon;
revoke all on function public.admin_verification_queue()                    from public, anon;
revoke all on function public.admin_review_verification(uuid, boolean, text) from public, anon;
grant execute on function public.submit_verification(text, text, text)         to authenticated;
grant execute on function public.admin_verification_queue()                    to authenticated;
grant execute on function public.admin_review_verification(uuid, boolean, text) to authenticated;

-- The user's app is told live when a decision is made.
do $$
begin
  begin alter publication supabase_realtime add table public.verification_requests;
  exception when duplicate_object then null; end;
end $$;
