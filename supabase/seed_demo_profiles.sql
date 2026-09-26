-- =============================================================================
--  ROVLO — 3 DEMO PROFILES (for testing the Discover feed and the map)
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

-- 3. OPTIONAL — to test matches + chat, make the demo people "like" YOU.
--    Put your own Google email below, remove the leading "--" on each line, run.
--    Then like them back in the Discover feed and it becomes a match.
--
-- insert into public.likes (from_user, to_user, kind)
-- select p.id, u.id, 'like'
-- from public.profiles p, auth.users u
-- where p.email like '%@demo.rovlo.app' and u.email = 'YOUR_EMAIL@gmail.com'
-- on conflict do nothing;
