-- Copy this file to seed_admins.sql (git-ignored), put your real emails in, and
-- run it once in the Supabase SQL editor. Safe to run again.

-- People who get the Admin Dashboard (all users, block/delete, push broadcasts):
insert into public.admin_emails (email) values
  ('admin1@example.com'),
  ('admin2@example.com')
on conflict do nothing;

-- People who answer the in-app Support chat (extra "Support" tab):
insert into public.support_agents (email) values
  ('support@example.com')
on conflict do nothing;
