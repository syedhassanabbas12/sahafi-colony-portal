-- Sahafi Colony Portal — database schema (Supabase / Postgres)
--
-- Run this in your Supabase project's SQL Editor. Idempotent — safe to
-- re-run after pulling schema changes from this repo, including on a
-- project that already has an earlier version of this file applied (see
-- the "Migrations" block after each table for how existing installations
-- get upgraded in place).
--
-- Security model: there is no Supabase Auth here (residents log in with
-- phone + 4-digit PIN, not email). The anon key is the only key the app
-- ever uses, and by itself it can do nothing: every table has Row Level
-- Security enabled with no policies granted to anon/authenticated, so
-- direct table access is a dead end. All reads and writes go through the
-- SECURITY DEFINER functions below, which check a session token (or admin
-- status) before doing anything. Functions named with a leading underscore
-- are internal helpers and have their EXECUTE grant explicitly revoked from
-- anon/authenticated so they can only be called from other functions here.
--
-- House model: collections and expenses are anchored to a (block,
-- house_number) pair, not to an app account. Real contribution history
-- (from the community's old Excel ledger) predates any app signup, and a
-- house's dues aren't really "owned" by whichever resident happens to have
-- an account — they're owned by the house. `residents` is the directory
-- seed/cross-check table (imported once, editable by admins afterward);
-- `users` is purely app accounts (phone+PIN login). The two are merged at
-- read time (list_houses, list_payment_status) so the directory and the
-- payment-status board show every known house, signed up or not.

create extension if not exists pgcrypto;

-- ============================================================================
-- Tables
-- ============================================================================

create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,
  pin_hash text not null,
  name text not null,
  block text not null default 'E',
  house_number text not null,
  occupation text,
  blood_group text check (blood_group is null or blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  photo_url text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  is_admin boolean not null default false,
  is_super_admin boolean not null default false,
  rejected_reason text,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  approved_by uuid references public.users(id)
);

-- Migration: upgrade an installation from before `block` existed.
alter table public.users add column if not exists block text not null default 'E';

create index if not exists users_status_idx on public.users(status);
create index if not exists users_blood_group_idx on public.users(blood_group);
create index if not exists users_block_house_idx on public.users(block, house_number);

-- Directory seed/cross-check data: every known house in the block, whether
-- or not its resident has signed up. Imported once from the community's
-- Excel records, editable by admins afterward (list_residents /
-- admin_upsert_resident / admin_delete_resident below).
create table if not exists public.residents (
  id uuid primary key default gen_random_uuid(),
  block text not null default 'E',
  house_number text not null,
  name text,
  occupation text,
  blood_group text check (blood_group is null or blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  is_vacant boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (block, house_number)
);

create index if not exists residents_block_house_idx on public.residents(block, house_number);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  token text not null unique,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists sessions_token_idx on public.sessions(token);

-- Failed/succeeded login attempts, keyed to the phone number that was tried
-- (not an IP — there's no IP-based abuse vector worth tracking here, since
-- a login only ever affects the account whose phone number was entered).
create table if not exists public.login_attempts (
  id bigint generated always as identity primary key,
  phone text not null,
  succeeded boolean not null,
  attempted_at timestamptz not null default now()
);

create index if not exists login_attempts_phone_time_idx on public.login_attempts(phone, attempted_at);

create table if not exists public.collections (
  id uuid primary key default gen_random_uuid(),
  block text not null default 'E',
  house_number text not null,
  amount numeric(12,2) not null check (amount > 0),
  period_month smallint not null check (period_month between 1 and 12),
  period_year smallint not null check (period_year between 2000 and 2100),
  note text,
  recorded_by uuid references public.users(id),
  created_at timestamptz not null default now()
);

-- Migration: collections used to be keyed to member_id (an app account).
-- Real contribution history predates any app account, so collections are
-- keyed to the house itself instead; recorded_by is nullable because
-- imported historical rows have no specific admin who "recorded" them.
alter table public.collections add column if not exists block text not null default 'E';
alter table public.collections add column if not exists house_number text not null default '';
alter table public.collections drop column if exists member_id;
alter table public.collections alter column recorded_by drop not null;

create index if not exists collections_house_idx on public.collections(block, house_number);
create index if not exists collections_period_idx on public.collections(period_year, period_month);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  description text not null,
  category text not null default 'misc',
  amount numeric(12,2) not null check (amount > 0),
  expense_date date not null default current_date,
  receipt_photo_url text,
  note text,
  recorded_by uuid references public.users(id),
  created_at timestamptz not null default now()
);

-- Migration: note (e.g. "paid by") added, recorded_by nullable for imports.
alter table public.expenses add column if not exists note text;
alter table public.expenses alter column recorded_by drop not null;

create index if not exists expenses_date_idx on public.expenses(expense_date);
create index if not exists expenses_category_idx on public.expenses(category);

alter table public.users enable row level security;
alter table public.residents enable row level security;
alter table public.sessions enable row level security;
alter table public.login_attempts enable row level security;
alter table public.collections enable row level security;
alter table public.expenses enable row level security;

-- ============================================================================
-- Internal helpers (not exposed to anon/authenticated directly)
-- ============================================================================

create or replace function public._current_user(p_token text)
returns public.users
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  select u.* into v_user
  from public.sessions s
  join public.users u on u.id = s.user_id
  where s.token = p_token
    and s.expires_at > now();

  if v_user.id is null then
    raise exception 'invalid_session';
  end if;

  update public.sessions set last_seen_at = now() where token = p_token;
  return v_user;
end;
$$;

-- House numbers are free text ("7", "90(A)", ...), so a plain text ORDER BY
-- sorts "E-100" before "E-2". This pulls out the leading digit run to sort
-- on numerically, falling back to the full string for houses sharing a
-- number (e.g. "90" before "90(A)").
create or replace function public._house_num_key(p_house_number text)
returns int
language sql
immutable
set search_path = public, extensions
as $$
  select nullif(regexp_replace(p_house_number, '\D.*$', ''), '')::int
$$;

-- "+923001234567", "0092 300 1234567" and "03001234567" are the same real
-- number typed three different ways — without this, each variant creates a
-- separate account for the same house. Canonical form is local Pakistani
-- mobile: 0 + 10 digits.
create or replace function public._normalize_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
  digits text;
begin
  digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if digits ~ '^0092\d{10}$' or digits ~ '^92\d{10}$' then
    return '0' || right(digits, 10);
  end if;
  return digits;
end;
$$;

create or replace function public._require_admin(p_token text)
returns public.users
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  if not (v_user.is_admin or v_user.is_super_admin) then
    raise exception 'Admin access required';
  end if;
  return v_user;
end;
$$;

-- ============================================================================
-- Auth: signup, login, session, profile
-- ============================================================================

drop function if exists public.signup(text, text, text, text, text, text);

create or replace function public.signup(
  p_phone text,
  p_name text,
  p_house_number text,
  p_pin text,
  p_block text default 'E',
  p_occupation text default null,
  p_blood_group text default null
) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;
  if public._normalize_phone(p_phone) !~ '^0[0-9]{10}$' then
    raise exception 'Enter a valid Pakistani mobile number (e.g. 03001234567)';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 or length(trim(coalesce(p_house_number, ''))) = 0 then
    raise exception 'Name and house number are required';
  end if;

  insert into public.users (phone, pin_hash, name, block, house_number, occupation, blood_group)
  values (
    public._normalize_phone(p_phone), crypt(p_pin, gen_salt('bf')), trim(p_name),
    coalesce(nullif(trim(p_block), ''), 'E'), trim(p_house_number),
    nullif(trim(coalesce(p_occupation, '')), ''), nullif(p_blood_group, '')
  )
  returning id into v_id;

  return json_build_object('id', v_id, 'status', 'pending');
exception
  when unique_violation then
    raise exception 'That phone number is already registered';
end;
$$;

create or replace function public.login(p_phone text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
  v_recent_failures int;
  v_token text;
begin
  select count(*) into v_recent_failures
  from public.login_attempts
  where phone = public._normalize_phone(p_phone)
    and succeeded = false
    and attempted_at > now() - interval '15 minutes';

  if v_recent_failures >= 5 then
    raise exception 'Too many failed attempts. Try again in 15 minutes.';
  end if;

  select * into v_user from public.users where phone = public._normalize_phone(p_phone);

  if v_user.id is null or v_user.pin_hash <> crypt(p_pin, v_user.pin_hash) then
    insert into public.login_attempts (phone, succeeded) values (public._normalize_phone(p_phone), false);
    raise exception 'Incorrect phone number or PIN';
  end if;

  if v_user.status = 'pending' then
    raise exception 'Your account is awaiting admin approval';
  end if;
  if v_user.status = 'rejected' then
    raise exception 'This account was not approved. Contact your block admin.';
  end if;

  insert into public.login_attempts (phone, succeeded) values (public._normalize_phone(p_phone), true);

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into public.sessions (user_id, token, expires_at)
  values (v_user.id, v_token, now() + interval '30 days');

  return json_build_object(
    'token', v_token,
    'user', json_build_object(
      'id', v_user.id, 'name', v_user.name, 'block', v_user.block, 'house_number', v_user.house_number,
      'is_admin', v_user.is_admin, 'is_super_admin', v_user.is_super_admin
    )
  );
end;
$$;

create or replace function public.logout(p_token text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  delete from public.sessions where token = p_token;
$$;

create or replace function public.get_current_user(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  return json_build_object(
    'id', v_user.id, 'name', v_user.name, 'phone', v_user.phone,
    'block', v_user.block, 'house_number', v_user.house_number, 'occupation', v_user.occupation,
    'blood_group', v_user.blood_group, 'photo_url', v_user.photo_url,
    'is_admin', v_user.is_admin, 'is_super_admin', v_user.is_super_admin
  );
exception
  when others then
    return null;
end;
$$;

create or replace function public.change_own_pin(p_token text, p_old_pin text, p_new_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  if p_new_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;
  if v_user.pin_hash <> crypt(p_old_pin, v_user.pin_hash) then
    raise exception 'Current PIN is incorrect';
  end if;
  update public.users set pin_hash = crypt(p_new_pin, gen_salt('bf')) where id = v_user.id;
end;
$$;

drop function if exists public.update_own_profile(text, text, text, text, text, text);

create or replace function public.update_own_profile(
  p_token text, p_name text, p_house_number text, p_block text, p_occupation text,
  p_blood_group text, p_photo_url text
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  update public.users set
    name = coalesce(nullif(trim(p_name), ''), name),
    house_number = coalesce(nullif(trim(p_house_number), ''), house_number),
    block = coalesce(nullif(trim(p_block), ''), block),
    occupation = nullif(trim(coalesce(p_occupation, '')), ''),
    blood_group = nullif(p_blood_group, ''),
    photo_url = nullif(p_photo_url, '')
  where id = v_user.id;
end;
$$;

-- ============================================================================
-- Admin: signup approval queue, member management
-- ============================================================================

create or replace function public.list_pending_signups(p_token text)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  return query
    select json_build_object(
      'id', id, 'phone', phone, 'name', name, 'block', block, 'house_number', house_number,
      'occupation', occupation, 'blood_group', blood_group, 'created_at', created_at
    )
    from public.users
    where status = 'pending'
    order by created_at asc;
end;
$$;

create or replace function public.approve_signup(p_token text, p_target_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_admin public.users;
begin
  v_admin := public._require_admin(p_token);
  update public.users
    set status = 'approved', approved_at = now(), approved_by = v_admin.id
    where id = p_target_id and status = 'pending';
  if not found then
    raise exception 'Signup not found or already processed';
  end if;
end;
$$;

create or replace function public.reject_signup(p_token text, p_target_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  update public.users
    set status = 'rejected', rejected_reason = nullif(trim(coalesce(p_reason, '')), '')
    where id = p_target_id and status = 'pending';
  if not found then
    raise exception 'Signup not found or already processed';
  end if;
end;
$$;

create or replace function public.admin_reset_pin(p_token text, p_target_id uuid, p_new_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  if p_new_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;
  update public.users set pin_hash = crypt(p_new_pin, gen_salt('bf')) where id = p_target_id;
  if not found then
    raise exception 'Member not found';
  end if;
end;
$$;

drop function if exists public.admin_update_member(text, uuid, text, text, text, text, text);

create or replace function public.admin_update_member(
  p_token text, p_target_id uuid, p_name text, p_house_number text, p_block text,
  p_occupation text, p_blood_group text, p_photo_url text
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  update public.users set
    name = coalesce(nullif(trim(p_name), ''), name),
    house_number = coalesce(nullif(trim(p_house_number), ''), house_number),
    block = coalesce(nullif(trim(p_block), ''), block),
    occupation = nullif(trim(coalesce(p_occupation, '')), ''),
    blood_group = nullif(p_blood_group, ''),
    photo_url = nullif(p_photo_url, '')
  where id = p_target_id;
  if not found then
    raise exception 'Member not found';
  end if;
end;
$$;

-- Approved accounts with their real user id, for the admin Members panel
-- (reset PIN / promote-demote) — distinct from list_houses, the public
-- merged directory, which has no single row id since a house's members can
-- come from residents, users, or both.
create or replace function public.admin_list_accounts(p_token text)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  return query
    select json_build_object(
      'id', id, 'name', name, 'phone', phone, 'block', block, 'house_number', house_number,
      'occupation', occupation, 'blood_group', blood_group, 'is_admin', is_admin
    )
    from public.users
    where status = 'approved'
    order by block, public._house_num_key(house_number), house_number;
end;
$$;

-- Only the super admin manages who else is a block admin.
create or replace function public.set_admin_role(p_token text, p_target_id uuid, p_is_admin boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  if not v_user.is_super_admin then
    raise exception 'Only the super admin can manage block admins';
  end if;
  update public.users set is_admin = p_is_admin where id = p_target_id and status = 'approved';
  if not found then
    raise exception 'Member not found';
  end if;
end;
$$;

-- ============================================================================
-- Resident directory (admin-managed seed data)
-- ============================================================================

-- Only residents entries with no matching approved app account — once
-- someone signs up for a house, that house's entry is managed through
-- admin_update_member instead, so there's exactly one editable record per
-- house at any time.
create or replace function public.list_residents(p_token text)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  return query
    select json_build_object(
      'block', r.block, 'house_number', r.house_number, 'name', r.name,
      'occupation', r.occupation, 'blood_group', r.blood_group, 'is_vacant', r.is_vacant
    )
    from public.residents r
    where not exists (
      select 1 from public.users u
      where u.status = 'approved' and u.block = r.block and u.house_number = r.house_number
    )
    order by r.block, public._house_num_key(r.house_number), r.house_number;
end;
$$;

create or replace function public.admin_upsert_resident(
  p_token text, p_block text, p_house_number text, p_name text,
  p_occupation text, p_blood_group text, p_is_vacant boolean default false
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  if length(trim(coalesce(p_house_number, ''))) = 0 then
    raise exception 'House number is required';
  end if;
  insert into public.residents (block, house_number, name, occupation, blood_group, is_vacant, updated_at)
  values (
    coalesce(nullif(trim(p_block), ''), 'E'), trim(p_house_number),
    nullif(trim(coalesce(p_name, '')), ''), nullif(trim(coalesce(p_occupation, '')), ''),
    nullif(p_blood_group, ''), coalesce(p_is_vacant, false), now()
  )
  on conflict (block, house_number) do update set
    name = excluded.name, occupation = excluded.occupation,
    blood_group = excluded.blood_group, is_vacant = excluded.is_vacant, updated_at = now();
end;
$$;

create or replace function public.admin_delete_resident(p_token text, p_block text, p_house_number text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  delete from public.residents where block = p_block and house_number = p_house_number;
  if not found then
    raise exception 'Resident entry not found';
  end if;
end;
$$;

-- ============================================================================
-- Member directory — merges signed-up accounts with imported resident data,
-- so every known house shows up whether or not it has an app account yet.
-- ============================================================================

drop function if exists public.list_members(text, text, text);

-- One row per house, not per account — a house with two residents who each
-- signed up separately used to show as two directory rows ("135 houses"
-- for 130 real ones). Each house's `members` array lists everyone at that
-- house individually (still searchable/filterable by name or blood group
-- per person), but the house itself is the unit of the result.
create or replace function public.list_houses(p_token text, p_search text default null, p_blood_group text default null)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._current_user(p_token);
  return query
    with house_people as (
      -- signed-up accounts for a house always take precedence
      select block, house_number, name, phone, occupation, blood_group, is_admin, true as has_account
      from public.users where status = 'approved'
      union all
      -- the imported directory entry, only for houses nobody has signed up for yet
      select r.block, r.house_number, r.name, null::text, r.occupation, r.blood_group, false, false
      from public.residents r
      where not r.is_vacant
        and not exists (
          select 1 from public.users u where u.status = 'approved' and u.block = r.block and u.house_number = r.house_number
        )
    ),
    vacant_houses as (
      select r.block, r.house_number
      from public.residents r
      where r.is_vacant
        and not exists (
          select 1 from public.users u where u.status = 'approved' and u.block = r.block and u.house_number = r.house_number
        )
    ),
    matching_houses as (
      select distinct block, house_number from house_people
      where (p_blood_group is null or p_blood_group = '' or blood_group = p_blood_group)
        and (p_search is null or p_search = '' or house_number ilike '%' || p_search || '%' or name ilike '%' || p_search || '%')
    ),
    occupied as (
      select hp.block, hp.house_number,
        json_build_object(
          'block', hp.block, 'house_number', hp.house_number, 'is_vacant', false,
          'members', json_agg(
            json_build_object(
              'name', hp.name, 'phone', hp.phone, 'occupation', hp.occupation,
              'blood_group', hp.blood_group, 'is_admin', hp.is_admin, 'has_account', hp.has_account
            ) order by hp.name
          )
        ) as row_json
      from house_people hp
      join matching_houses mh on mh.block = hp.block and mh.house_number = hp.house_number
      group by hp.block, hp.house_number
    ),
    vacant as (
      select v.block, v.house_number,
        json_build_object('block', v.block, 'house_number', v.house_number, 'is_vacant', true, 'members', '[]'::json) as row_json
      from vacant_houses v
      where (p_blood_group is null or p_blood_group = '')
        and (p_search is null or p_search = '' or v.house_number ilike '%' || p_search || '%')
    ),
    combined as (
      select * from occupied
      union all
      select * from vacant
    )
    select row_json
    from combined
    order by block, public._house_num_key(house_number), house_number;
end;
$$;

-- ============================================================================
-- Collections (fund contributions) — keyed to (block, house_number)
-- ============================================================================

drop function if exists public.record_collection(text, uuid, numeric, int, int, text);

create or replace function public.record_collection(
  p_token text, p_block text, p_house_number text, p_amount numeric,
  p_period_month int, p_period_year int, p_note text default null
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_admin public.users;
begin
  v_admin := public._require_admin(p_token);
  if length(trim(coalesce(p_house_number, ''))) = 0 then
    raise exception 'House number is required';
  end if;
  insert into public.collections (block, house_number, amount, period_month, period_year, note, recorded_by)
  values (
    coalesce(nullif(trim(p_block), ''), 'E'), trim(p_house_number), p_amount,
    p_period_month, p_period_year, nullif(trim(coalesce(p_note, '')), ''), v_admin.id
  );
end;
$$;

-- Aggregate totals only — individual amounts are private (see list_my_collections
-- for a member's own history and list_collections_admin for the admin view).
create or replace function public.get_collection_totals(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_this_month numeric;
  v_this_year numeric;
  v_all_time numeric;
begin
  perform public._current_user(p_token);

  select coalesce(sum(amount), 0) into v_this_month from public.collections
    where period_month = extract(month from current_date) and period_year = extract(year from current_date);
  select coalesce(sum(amount), 0) into v_this_year from public.collections
    where period_year = extract(year from current_date);
  select coalesce(sum(amount), 0) into v_all_time from public.collections;

  return json_build_object('this_month', v_this_month, 'this_year', v_this_year, 'all_time', v_all_time);
end;
$$;

-- Paid/unpaid status for every known house for a given period — visible to
-- all members, but with no amounts, per the spec's default recommendation.
-- Covers every house from the merged directory, including vacant plots and
-- houses with no app account yet.
create or replace function public.list_payment_status(p_token text, p_period_month int, p_period_year int)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._current_user(p_token);
  return query
    with u as (
      -- one row per house even when it has multiple accounts (e.g. two
      -- residents who each signed up separately) — combine their names
      -- rather than producing a duplicate row per account.
      select block, house_number, string_agg(name, ', ' order by name) as name
      from public.users where status = 'approved'
      group by block, house_number
    ),
    r as (
      select block, house_number, name, is_vacant from public.residents
    )
    select json_build_object(
      'block', coalesce(u.block, r.block),
      'house_number', coalesce(u.house_number, r.house_number),
      'name', coalesce(u.name, r.name),
      'is_vacant', coalesce(r.is_vacant, false),
      'paid', exists(
        select 1 from public.collections c
        where c.block = coalesce(u.block, r.block) and c.house_number = coalesce(u.house_number, r.house_number)
          and c.period_month = p_period_month and c.period_year = p_period_year
      )
    )
    from u
    full outer join r on r.block = u.block and r.house_number = u.house_number
    order by coalesce(u.block, r.block), public._house_num_key(coalesce(u.house_number, r.house_number)), coalesce(u.house_number, r.house_number);
end;
$$;

create or replace function public.list_my_collections(p_token text)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  return query
    select json_build_object(
      'id', id, 'amount', amount, 'period_month', period_month,
      'period_year', period_year, 'note', note, 'created_at', created_at
    )
    from public.collections
    where block = v_user.block and house_number = v_user.house_number
    order by period_year desc, period_month desc;
end;
$$;

create or replace function public.list_collections_admin(p_token text, p_period_month int default null, p_period_year int default null)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token);
  return query
    select json_build_object(
      'id', c.id, 'block', c.block, 'house_number', c.house_number,
      'amount', c.amount, 'period_month', c.period_month, 'period_year', c.period_year,
      'note', c.note, 'created_at', c.created_at
    )
    from public.collections c
    where (p_period_month is null or c.period_month = p_period_month)
      and (p_period_year is null or c.period_year = p_period_year)
    order by c.created_at desc;
end;
$$;

create or replace function public.super_admin_delete_collection(p_token text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  if not v_user.is_super_admin then
    raise exception 'Only the super admin can delete records';
  end if;
  delete from public.collections where id = p_id;
  if not found then
    raise exception 'Record not found';
  end if;
end;
$$;

-- ============================================================================
-- Expenses
-- ============================================================================

drop function if exists public.record_expense(text, text, text, numeric, date, text);

create or replace function public.record_expense(
  p_token text, p_description text, p_category text, p_amount numeric,
  p_date date default current_date, p_receipt_photo_url text default null, p_note text default null
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_admin public.users;
begin
  v_admin := public._require_admin(p_token);
  if length(trim(coalesce(p_description, ''))) = 0 then
    raise exception 'Description is required';
  end if;
  insert into public.expenses (description, category, amount, expense_date, receipt_photo_url, note, recorded_by)
  values (
    trim(p_description), coalesce(nullif(trim(p_category), ''), 'misc'), p_amount, p_date,
    nullif(p_receipt_photo_url, ''), nullif(trim(coalesce(p_note, '')), ''), v_admin.id
  );
end;
$$;

create or replace function public.list_expenses(p_token text, p_category text default null, p_from date default null, p_to date default null)
returns setof json
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._current_user(p_token);
  return query
    select json_build_object(
      'id', id, 'description', description, 'category', category, 'amount', amount,
      'date', expense_date, 'receipt_photo_url', receipt_photo_url, 'note', note, 'created_at', created_at
    )
    from public.expenses
    where (p_category is null or p_category = '' or category = p_category)
      and (p_from is null or expense_date >= p_from)
      and (p_to is null or expense_date <= p_to)
    order by expense_date desc, created_at desc;
end;
$$;

create or replace function public.super_admin_delete_expense(p_token text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user public.users;
begin
  v_user := public._current_user(p_token);
  if not v_user.is_super_admin then
    raise exception 'Only the super admin can delete records';
  end if;
  delete from public.expenses where id = p_id;
  if not found then
    raise exception 'Record not found';
  end if;
end;
$$;

-- ============================================================================
-- Dashboard
-- ============================================================================

create or replace function public.get_dashboard(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_total_collections numeric;
  v_total_expenses numeric;
  v_recent_collections json;
  v_recent_expenses json;
begin
  perform public._current_user(p_token);

  select coalesce(sum(amount), 0) into v_total_collections from public.collections;
  select coalesce(sum(amount), 0) into v_total_expenses from public.expenses;

  select coalesce(json_agg(t), '[]'::json) into v_recent_collections from (
    select block, house_number, period_month, period_year, created_at
    from public.collections
    order by created_at desc
    limit 5
  ) t;

  select coalesce(json_agg(t), '[]'::json) into v_recent_expenses from (
    select description, category, amount, expense_date as date, created_at
    from public.expenses
    order by created_at desc
    limit 5
  ) t;

  return json_build_object(
    'balance', v_total_collections - v_total_expenses,
    'total_collections', v_total_collections,
    'total_expenses', v_total_expenses,
    'recent_collections', v_recent_collections,
    'recent_expenses', v_recent_expenses
  );
end;
$$;

-- ============================================================================
-- Grants — deny direct table access, allow calling the functions above
-- ============================================================================

revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

grant execute on function
  public.signup(text, text, text, text, text, text, text),
  public.login(text, text),
  public.logout(text),
  public.get_current_user(text),
  public.change_own_pin(text, text, text),
  public.update_own_profile(text, text, text, text, text, text, text),
  public.list_pending_signups(text),
  public.approve_signup(text, uuid),
  public.reject_signup(text, uuid, text),
  public.admin_reset_pin(text, uuid, text),
  public.admin_update_member(text, uuid, text, text, text, text, text, text),
  public.set_admin_role(text, uuid, boolean),
  public.admin_list_accounts(text),
  public.list_residents(text),
  public.admin_upsert_resident(text, text, text, text, text, text, boolean),
  public.admin_delete_resident(text, text, text),
  public.list_houses(text, text, text),
  public.record_collection(text, text, text, numeric, int, int, text),
  public.get_collection_totals(text),
  public.list_payment_status(text, int, int),
  public.list_my_collections(text),
  public.list_collections_admin(text, int, int),
  public.super_admin_delete_collection(text, uuid),
  public.record_expense(text, text, text, numeric, date, text, text),
  public.list_expenses(text, text, date, date),
  public.super_admin_delete_expense(text, uuid),
  public.get_dashboard(text)
to anon, authenticated;
