# Sahafi Colony Portal

A transparent, mobile-first web app for the residents of Sahafi Colony (E-Block)
to manage the community welfare fund — replacing manual Excel-based
record-keeping. Every resident can see exactly how much money came in, how
much went out, and why, without depending on anyone's word.

**100% free to run.** No paid services anywhere in this stack — Supabase
(database), GitHub Pages (hosting) and the app itself are all on free tiers,
with no premium features, no payment processor, and no plan to add one. This
is a welfare project, not a product.

This repo covers **Phase 1 (MVP)** of the [full spec](./SPEC.md):
authentication, the member directory, collections (contributions), expenses,
and a dashboard with the live balance. Issue reporting, announcements, blood
group search, polls, and SMS notifications are Phase 2/3 — see the spec.

## Roles

| Role | Capabilities |
|---|---|
| **Super Admin** | Everything a Block Admin can do, plus: promote/demote other Block Admins, permanently delete a collection or expense record. |
| **Block Admin / Treasurer** | Approve or reject new member signups, record collections and expenses, reset a member's PIN. |
| **Member** | View the dashboard, directory, all collections/expenses data, edit their own profile and PIN. |
| **Pending** | Signed up, waiting on a Block Admin to approve. No access until approved. |

One account can hold both Admin and Member — the treasurer is also a
resident.

## How auth works (and what's deliberately not built yet)

Residents log in with **phone number + a 4-digit PIN**, not email — no
account setup friction for elderly or non-technical residents. Signup
requires name, phone, house number and a PIN; the account sits as `pending`
until a Block Admin approves it (cross-checked against the real resident),
same as the original spec's flow.

**No SMS/OTP verification in Phase 1.** Sending SMS costs money per message
(Twilio, or any local Pakistani gateway) — there's no free way to do it, and
since this must stay free, it's left out for now. The spec itself puts "SMS
notifications" in Phase 3, so this isn't a regression, just building things
in the order the spec already implies. In its place: the admin-approval step
*is* the identity check (an admin who knows the residents confirms the
signup matches a real house), and a PIN is never emailed or texted anywhere.
If a free/sponsored SMS option becomes available later, OTP signup
verification and self-service "forgot PIN" can be added without changing the
rest of the schema.

Until then, a locked-out resident gets their PIN reset by a Block Admin in
person (Admin panel → Members → Reset PIN) — the spec's own fallback path.
Login is rate-limited: 5 failed attempts on a phone number locks that number
out for 15 minutes.

## The one open decision from the spec, resolved

The spec asked: *should individual contribution amounts be visible to all
members, or just a paid/unpaid status with only aggregate totals shown
publicly?* Confirmed with the project owner — this repo implements the
spec's own recommended default:

- **Aggregate totals** (this month / this year / all-time) — visible to every member.
- **Paid/unpaid status per house**, for a chosen month — visible to every member, no amounts shown.
- **Individual amounts** — visible only to the member who paid them, and to admins (who need the real numbers to do their job).

If your committee later wants full amount transparency instead, that's a
schema change (`list_payment_status` → return `amount` instead of a
boolean) — say the word and it can be flipped.

## Other committee decisions (resolved)

The spec's section 9 asked three more questions before/during the Phase 1
build. All three are now resolved with the project owner:

- **Super Admin: one person**, not a group. Only one account needs the
  one-time SQL bootstrap in step 2 below. If that ever changes, the sole
  Super Admin can promote a second one directly — `set_admin_role` handles
  Block Admins, but making someone else Super Admin is still a manual SQL
  step (`update public.users set is_super_admin = true where phone = '...'`)
  since it's rare and deliberately not exposed as a button.
- **Past Excel records: migrate them**, don't start fresh. This needs the
  actual Excel file before it can happen — once it's shared, a one-time
  import script can backfill `collections` and `expenses` from it directly
  into Supabase (matching each row to a `member_id`/house number, or
  flagging rows that don't match an existing resident for manual review).
  Not built yet — pending the file.
- **Phase 3 SMS gateway: a local Pakistani provider**, not Twilio, for
  better in-country deliverability and cost. Noted for when Phase 3 is
  actually built — no action needed now, since Phase 1 has no SMS at all.

## Get it live

### 1. Create the database (Supabase, free)

1. Create a free project at [supabase.com](https://supabase.com).
2. Open its **SQL Editor** and run `schema.sql` from this repo against that
   project. It creates every table, the session/PIN auth functions, and the
   admin/member/collections/expenses functions the app calls. Idempotent —
   safe to re-run after pulling schema changes.
3. In **Project Settings → API**, copy the **Project URL** and the **anon
   public** key (never the `service_role` key).
4. Copy `config.example.js` to `config.js` and paste them in. The anon key
   is *meant* to be public — Row Level Security in `schema.sql` is what
   actually controls access, which is nothing directly: every table denies
   anon/authenticated access outright, and every read or write goes through
   a function that checks a session token or admin status first.

### 2. Create the first Super Admin

The app has no bootstrap flow for the very first admin — someone has to be
promoted by hand once. Sign up as yourself through the app first (you'll sit
as `pending`), then in the Supabase SQL editor:

```sql
update public.users
set status = 'approved', is_admin = true, is_super_admin = true
where phone = '+92XXXXXXXXXX';
```

From then on, that account's Admin panel can approve everyone else and
promote additional Block Admins.

### 3. Turn on GitHub Pages

**Settings → Pages → Build and deployment → Source: "GitHub Actions"**. The
included workflow (`.github/workflows/deploy.yml`) builds and publishes on
every push to `main`. The first push (or the next one after enabling Pages)
finishes with the live URL shown in the Actions run and under **Settings →
Pages**.

## Local development

Static site, no build step — open `index.html` directly, or serve the
folder with anything (`python3 -m http.server`, `npx serve`, ...).

## Accessibility & language

- Large text, high-contrast colors, minimal steps per action, icon **and**
  text labels throughout (never icon-only) — built for elderly, non-technical
  residents from the start, not retrofitted.
- Full English/Urdu toggle (top-right, every screen), including right-to-left
  layout for Urdu. Translations are hand-written for every Phase 1 screen,
  not machine-translated.
- Installable as a home-screen app (PWA). The app shell (HTML/CSS/JS/icons)
  is cached for instant, offline-capable loading; financial data itself
  always comes live from Supabase and is never cached, so an offline visitor
  never sees stale numbers presented as current.

## Data model

See `schema.sql` for the full definitions. Summary: `users` (profile +
`pin_hash` + approval status + role flags), `sessions` (token-based, since
there's no Supabase Auth here), `login_attempts` (rate limiting),
`collections` (fund contributions), `expenses`.

## What's next (Phase 2 / Phase 3)

Not built here on purpose — see the spec for the full plan:

- **Phase 2:** issue/complaint reporting and status tracking, announcements, blood-group emergency search.
- **Phase 3:** committee polls/voting, SMS notifications (once a free/sponsored gateway exists), receipt-photo upload polish (currently a plain URL field — real upload needs a Supabase Storage bucket, still free tier but a separate setup step), CSV/PDF export.
