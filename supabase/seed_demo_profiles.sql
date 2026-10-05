-- =============================================================================
--  ROVLO — 4 DEMO PROFILES (for testing the Discover feed, the map and chat)
--
--  HOW TO RUN
--    Supabase Dashboard → SQL Editor → New query → paste this whole file → Run.
--    Safe to run again: it refreshes the demo people (and their "last seen"
--    time, so they keep showing on the map).
--
--  These are clearly fake accounts (email ...@demo.rovlo.app) that nobody can
--  sign in to. They only exist so the app has people to show while you test.
--
--  REMOVE THEM LATER
--    delete from auth.users where email like '%@demo.rovlo.app';
--    (everything belonging to them is deleted automatically)
-- =============================================================================

-- 1. Accounts (the database trigger creates the matching profile rows)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000001',
   'authenticated', 'authenticated', 'aarav@demo.rovlo.app', '', now(),
   '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{"full_name":"Aarav Sen"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000002',
   'authenticated', 'authenticated', 'meera@demo.rovlo.app', '', now(),
   '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{"full_name":"Meera Iyer"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000003',
   'authenticated', 'authenticated', 'rohan@demo.rovlo.app', '', now(),
   '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{"full_name":"Rohan Das"}', now(), now())
on conflict (id) do nothing;

-- 2. Fill in the profiles
update public.profiles set
  name = 'Aarav Sen',
  gender = 'Male',
  dob = '1998-05-14T00:00:00.000',
  bio = 'Photographer from Kolkata chasing sunsets and street food. Heading to Goa this October — always up for a beach shack dinner or a scooter ride to hidden coves. Say hi!',
  photo_url = 'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?auto=format&fit=crop&w=900&q=80',
  profile_photos = array[
    'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?auto=format&fit=crop&w=900&q=80',
    'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?auto=format&fit=crop&w=900&q=80',
    'https://images.unsplash.com/photo-1492562080023-ab3db95bfbce?auto=format&fit=crop&w=900&q=80'],
  travel_interests = array['Photography', 'Backpacking', 'Food & wine'],
  home_base = 'Kolkata, India',
  city = 'Kolkata',
  trip_destination = 'Goa, India',
  trip_dates = '3rd Week, Oct 2026',
  is_verified = true,
  profile_complete = true, is_paused = false, is_blocked = false, ghost_mode = false,
  lat = 22.5850, lng = 88.3468, location_updated_at = now()
where id = 'd0000000-0000-4000-8000-000000000001';

update public.profiles set
  name = 'Meera Iyer',
  gender = 'Female',
  dob = '2000-09-03T00:00:00.000',
  bio = 'UX designer working remotely, currently plotting a month in Bali. Coffee shops, coworking spaces, rice-terrace sunrises and good conversation. Let''s swap travel tips!',
  photo_url = 'https://images.unsplash.com/photo-1494790108377-be9c29b29330?auto=format&fit=crop&w=900&q=80',
  profile_photos = array[
    'https://images.unsplash.com/photo-1494790108377-be9c29b29330?auto=format&fit=crop&w=900&q=80',
    'https://images.unsplash.com/photo-1534528741775-53994a69daeb?auto=format&fit=crop&w=900&q=80',
    'https://images.unsplash.com/photo-1517841905240-472988babdf9?auto=format&fit=crop&w=900&q=80'],
  travel_interests = array['Culture & history', 'Wellness & spa', 'Solo travel'],
  home_base = 'Kolkata, India',
  city = 'Kolkata',
  trip_destination = 'Bali, Indonesia',
  trip_dates = '2nd Week, Nov 2026',
  is_verified = true,
  profile_complete = true, is_paused = false, is_blocked = false, ghost_mode = false,
  lat = 22.5448, lng = 88.3426, location_updated_at = now()
where id = 'd0000000-0000-4000-8000-000000000002';

update public.profiles set
  name = 'Rohan Das',
  gender = 'Male',
  dob = '1995-12-21T00:00:00.000',
  bio = 'Weekend trekker and amateur ramen critic. Off to Kyoto for the autumn leaves — looking for company for temple walks, matcha stops and a Fushimi Inari sunrise.',
  photo_url = 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?auto=format&fit=crop&w=900&q=80',
  profile_photos = array[
    'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?auto=format&fit=crop&w=900&q=80',
    'https://images.unsplash.com/photo-1472099645785-5658abf4ff4e?auto=format&fit=crop&w=900&q=80'],
  travel_interests = array['Mountains', 'Adventure sports', 'Wildlife & nature'],
  home_base = 'Kolkata, India',
  city = 'Kolkata',
  trip_destination = 'Kyoto, Japan',
  trip_dates = '4th Week, Nov 2026',
  is_verified = false,
  profile_complete = true, is_paused = false, is_blocked = false, ghost_mode = false,
  lat = 22.6000, lng = 88.4000, location_updated_at = now()
where id = 'd0000000-0000-4000-8000-000000000003';

-- 2b. MAP + CHAT TEST USER — "Kabir Test".
--     * Shows on the map within ~1 km of the most recently active real user
--       (so you see him right next to you); falls back to central Kolkata.
--     * Location is "live" (location_updated_at = now()).
--     * Accepts every chat request instantly (needs the latest schema.sql, which
--       adds is_demo_user + the auto-accept in send_chat_request).
--     * Has a chat key, so you can send him encrypted messages.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-000000000004',
   'authenticated', 'authenticated', 'kabir@demo.rovlo.app', '', now(),
   '', '', '', '',
   '{"provider":"email","providers":["email"]}', '{"full_name":"Kabir Test"}', now(), now())
on conflict (id) do nothing;

update public.profiles set
  name = 'Kabir Test',
  gender = 'Male',
  dob = '1997-03-08T00:00:00.000',
  bio = 'Demo traveller for testing the map and chat. Message me — I accept every request instantly!',
  photo_url = 'https://images.unsplash.com/photo-1519085360753-af0119f7cbe7?auto=format&fit=crop&w=900&q=80',
  profile_photos = array[
    'https://images.unsplash.com/photo-1519085360753-af0119f7cbe7?auto=format&fit=crop&w=900&q=80'],
  travel_interests = array['Backpacking', 'Food & wine', 'Photography'],
  home_base = 'Kolkata, India',
  city = 'Kolkata',
  trip_destination = 'Manali, India',
  trip_dates = '1st Week, Dec 2026',
  is_verified = true,
  profile_complete = true, is_paused = false, is_blocked = false, ghost_mode = false,
  lat = coalesce((select r.lat + 0.006 from public.profiles r
                  where r.email not like '%@demo.rovlo.app' and r.lat is not null
                  order by r.location_updated_at desc nulls last limit 1), 22.5726),
  lng = coalesce((select r.lng + 0.006 from public.profiles r
                  where r.email not like '%@demo.rovlo.app' and r.lat is not null
                  order by r.location_updated_at desc nulls last limit 1), 88.3639),
  location_updated_at = now()
where id = 'd0000000-0000-4000-8000-000000000004';

-- A placeholder public chat key (32 bytes, base64) so messages to him work.
insert into public.user_keys (user_id, public_key)
values ('d0000000-0000-4000-8000-000000000004', 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=')
on conflict (user_id) do nothing;

-- 2c. TRIPS — what makes "Going to…" and the Discover cards work.
--     The app reads destinations from the trips table (not profiles), so each
--     demo person gets a real upcoming trip with coordinates. Dates are
--     relative to today, so re-running this later keeps them in the future.
--     Search e.g. "Goa" / "Bali" / "Kyoto" / "Manali" for the week shown on the
--     cards (or the weeks around it) and they appear, best date match first.
delete from public.trips where user_id in (
  select id from public.profiles where email like '%@demo.rovlo.app');

insert into public.trips
  (user_id, destination, lat, lng, travel_week, travel_month, travel_year, start_date, end_date)
select v.uid, v.dest, v.lat, v.lng,
       (array['1st Week','2nd Week','3rd Week','4th Week'])[least(((extract(day from d.dt)::int - 1) / 7) + 1, 4)],
       to_char(d.dt, 'Mon'), to_char(d.dt, 'YYYY'), w.start_date, w.end_date
from (values
  ('d0000000-0000-4000-8000-000000000001'::uuid, 'Goa, India',        15.2993, 74.1240, 14),
  ('d0000000-0000-4000-8000-000000000002'::uuid, 'Bali, Indonesia',   -8.4095, 115.1889, 35),
  ('d0000000-0000-4000-8000-000000000003'::uuid, 'Kyoto, Japan',      35.0116, 135.7681, 56),
  ('d0000000-0000-4000-8000-000000000004'::uuid, 'Manali, India',     32.2432, 77.1892, 7)
) as v(uid, dest, lat, lng, days_ahead)
cross join lateral (select (current_date + v.days_ahead) as dt) d
cross join lateral public.trip_window(
  (array['1st Week','2nd Week','3rd Week','4th Week'])[least(((extract(day from d.dt)::int - 1) / 7) + 1, 4)],
  to_char(d.dt, 'Mon'), to_char(d.dt, 'YYYY')) w;

select public.sync_profile_trip(id) from public.profiles where email like '%@demo.rovlo.app';

-- 3. OPTIONAL — to test matches + chat, make the demo people "like" YOU.
--    Put your own Google email below, remove the leading "--" on each line, run.
--    Then like them back in the Discover feed and it becomes a match.
--
-- insert into public.likes (from_user, to_user, kind)
-- select p.id, u.id, 'like'
-- from public.profiles p, auth.users u
-- where p.email like '%@demo.rovlo.app' and u.email = 'YOUR_EMAIL@gmail.com'
-- on conflict do nothing;
