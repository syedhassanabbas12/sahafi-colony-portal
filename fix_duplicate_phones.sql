-- Sahafi Colony Portal — one-time cleanup for duplicate accounts caused by
-- inconsistent phone formats ("+923001234567" vs "03001234567" vs
-- "0092 300 1234567" — all the same real number). Run this AFTER schema.sql
-- (needs the _normalize_phone function it defines).
--
-- Run the SELECT below first and read its output — it shows exactly which
-- accounts will be merged and into which one, before anything changes.
--
-- Default merge rule when a phone number has duplicate accounts: keep the
-- account that is Super Admin > Admin > Approved > oldest (in that priority
-- order). To keep a *different* account instead for a specific number, add
-- a row to _phone_keep_overrides below using the phone exactly as it was
-- entered on the account you want kept (as shown in the preview's "phone as
-- entered" text) — the loop checks this list before falling back to the
-- default rule. Either way, every other duplicate's admin flags, approval
-- status, and any profile field the keeper is missing (occupation/blood
-- group/photo) get folded into the survivor, anything that pointed at a
-- deleted duplicate as its approver gets reassigned, and the rest are
-- deleted. Financial records (collections/expenses) are untouched either
-- way — they're keyed to the house, not the account.

create temporary table _phone_keep_overrides (phone_as_entered text);
insert into _phone_keep_overrides (phone_as_entered) values
  ('03009497186');
  -- add more rows here, one per line, for any other group where you want a
  -- specific account kept instead of the default pick

-- ============================================================================
-- STEP 1 — preview: which accounts are duplicates, and which one wins
-- ============================================================================
with normalized as (
  select id, phone, public._normalize_phone(phone) as norm_phone, name, block, house_number,
         status, is_admin, is_super_admin, created_at
  from public.users
),
ranked as (
  select *,
    row_number() over (
      partition by norm_phone
      order by (phone in (select phone_as_entered from _phone_keep_overrides)) desc,
               is_super_admin desc, is_admin desc, (status = 'approved') desc, created_at asc
    ) as rnk
  from normalized
)
select
  norm_phone as normalized_phone,
  count(*) as duplicate_accounts,
  string_agg(
    name || ' (' || block || '-' || house_number || ', ' || status || ', phone as entered: ' || phone || ')'
    || case when rnk = 1 then ' <- KEEPS THIS ONE' else ' <- will be deleted, merged into the kept one' end,
    E'\n' order by rnk
  ) as accounts
from ranked
group by norm_phone
having count(*) > 1;

-- ============================================================================
-- STEP 2 — the actual cleanup. Only run this after checking Step 1's output.
-- ============================================================================
do $$
declare
  grp record;
  keeper uuid;
begin
  for grp in
    select public._normalize_phone(phone) as norm_phone
    from public.users
    group by public._normalize_phone(phone)
    having count(*) > 1
  loop
    -- manual override first, if one was given for this group
    select id into keeper
    from public.users
    where public._normalize_phone(phone) = grp.norm_phone
      and phone in (select phone_as_entered from _phone_keep_overrides)
    limit 1;

    -- otherwise the default rule
    if keeper is null then
      select id into keeper
      from public.users
      where public._normalize_phone(phone) = grp.norm_phone
      order by is_super_admin desc, is_admin desc, (status = 'approved') desc, created_at asc
      limit 1;
    end if;

    update public.users k set
      is_admin = k.is_admin or exists(
        select 1 from public.users u2 where public._normalize_phone(u2.phone) = grp.norm_phone and u2.is_admin
      ),
      is_super_admin = k.is_super_admin or exists(
        select 1 from public.users u2 where public._normalize_phone(u2.phone) = grp.norm_phone and u2.is_super_admin
      ),
      status = case
        when k.status <> 'approved'
          and exists(select 1 from public.users u2 where public._normalize_phone(u2.phone) = grp.norm_phone and u2.status = 'approved')
        then 'approved' else k.status
      end,
      occupation = coalesce(k.occupation, (
        select occupation from public.users u2
        where public._normalize_phone(u2.phone) = grp.norm_phone and u2.occupation is not null limit 1
      )),
      blood_group = coalesce(k.blood_group, (
        select blood_group from public.users u2
        where public._normalize_phone(u2.phone) = grp.norm_phone and u2.blood_group is not null limit 1
      )),
      photo_url = coalesce(k.photo_url, (
        select photo_url from public.users u2
        where public._normalize_phone(u2.phone) = grp.norm_phone and u2.photo_url is not null limit 1
      ))
    where k.id = keeper;

    -- don't let a deleted duplicate's id linger as someone's "approved_by"
    update public.users set approved_by = keeper
    where approved_by in (
      select id from public.users where public._normalize_phone(phone) = grp.norm_phone and id <> keeper
    );

    -- delete the duplicates BEFORE renaming the keeper's phone below — while
    -- a loser still holds the exact normalized value, updating the keeper to
    -- that same value would trip the unique constraint.
    delete from public.users
    where public._normalize_phone(phone) = grp.norm_phone and id <> keeper;
  end loop;

  -- normalize every remaining phone number (duplicates now removed, so this
  -- can't collide with anything).
  update public.users set phone = public._normalize_phone(phone) where phone <> public._normalize_phone(phone);
end $$;

-- ============================================================================
-- STEP 3 — confirm: this should now return zero rows
-- ============================================================================
select public._normalize_phone(phone) as normalized_phone, count(*)
from public.users
group by public._normalize_phone(phone)
having count(*) > 1;
