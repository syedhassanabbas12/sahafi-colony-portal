# E-Block Welfare Portal — Product & Technical Spec

## 1. Overview

A web application (PWA) for the residents of E-Block in a housing scheme in Lahore, Pakistan. It replaces manual Excel-based record-keeping for community welfare fund management with a transparent, mobile-first system that all residents — including elderly, non-technical members — can use.

**Core principle:** Every member can see exactly how much money came in, how much went out, and why, without depending on anyone's word.

## 2. Users & Roles

| Role | Capabilities |
|---|---|
| **Super Admin** | Full control. Manages Block Admins. Sole ability to permanently delete records. |
| **Block Admin / Treasurer** | Approves new member signups. Records collections & expenses. Posts announcements. Manages issue status. |
| **Member** | Views all financial data, directory, announcements. Edits own profile. Reports issues. |
| **Pending** | Signed up, awaiting admin approval. No access to member data until approved. |

A user can hold both Admin and Member roles simultaneously (e.g., the treasurer is also a resident).

## 3. Authentication

- **Login:** Phone number + 4-digit PIN (no email, no complex password).
- **Signup flow:**
  1. User enters phone number, name, house number.
  2. User sets a 4-digit PIN.
  3. Account created in `pending` status.
  4. Admin reviews and approves/rejects (cross-checked against known house number/resident).
  5. On approval, user gets SMS notification and full access.
- **PIN reset:**
  - Self-service via OTP SMS to registered phone.
  - Fallback: Admin can manually reset a member's PIN in person (for members who can't manage OTP flow).
- **Security safeguards** (to offset PIN weakness vs. a full password):
  - Rate-limit login attempts (e.g., lock for 15 min after 5 failed attempts).
  - Phone number verified via OTP at signup — acts as a second factor.
  - Session tokens with reasonable expiry; no "remember PIN" auto-fill anywhere.

## 4. Feature Modules

### 4.1 Dashboard (Landing Page)
- Current fund balance (total collected − total spent), shown large and first.
- Recent activity feed: last 5 collections + last 5 expenses.
- Quick links to all modules.

### 4.2 Member Directory
- Fields: Name, house/block number, phone, occupation, blood group, photo (optional).
- Searchable and filterable (especially by blood group, for emergencies).
- Members can edit their own profile; admins can edit any profile.

### 4.3 Collections (Fund Contributions)
- Log entry: member, amount, date, month/period it covers, recorded-by admin.
- Public aggregate view: total collected this month / this year / all-time.
- Per-member view: a member sees their own contribution history.
- **Open decision for committee to settle before build:** should individual contribution amounts be visible to all members, or just a "paid / unpaid" status per member with only aggregate totals shown publicly? Recommend defaulting to status-only + aggregate totals unless the committee explicitly wants full visibility.

### 4.4 Expenses
- Log entry: description, category (e.g., streetlights, transformer, security, misc.), amount, date, approved-by, optional receipt/work photo.
- Filterable by category and date range.
- Running total shown alongside collections to compute the live balance.

### 4.5 Issue / Complaint Reporting
- Any member can report an issue (e.g., "light out near House 12").
- Status pipeline: Reported → In Progress → Resolved.
- Optional photo attachment.
- Visible to all members as a public log (builds trust that issues aren't ignored).

### 4.6 Announcements
- Admin-posted notices (meetings, urgent updates, collection reminders).
- Pinned/most-recent-first list on a dedicated page and/or dashboard banner.

### 4.7 Admin Approval Queue
- List of pending signups with submitted details.
- Approve / reject actions, with optional rejection reason.

## 5. Non-Functional Requirements

- **Accessibility for elderly users:** large fonts, high-contrast text, minimal steps per action, icon + text labels (not icon-only).
- **Bilingual:** English and Urdu toggle. Urdu should be a first-class translation, not machine-translated afterthought, since older residents will lean on it.
- **PWA / installable:** works like an app from the home screen without an app store, minimal data usage.
- **Mobile-first:** most residents will use this on a phone, not a desktop.
- **Offline tolerance:** graceful handling of poor connectivity (common in Pakistan) — show cached data, queue actions if offline where feasible.

## 6. Suggested Tech Stack

- **Frontend:** Next.js (React) as a PWA
- **Backend:** Node.js + PostgreSQL
- **Auth:** Custom phone+PIN auth with OTP via SMS gateway (Twilio or a local Pakistani SMS provider for better in-country delivery)
- **Hosting:** Vercel (frontend) + Railway or Render (backend/DB)
- **File storage:** For receipt/issue photos — S3-compatible storage (e.g., Cloudflare R2 or AWS S3)

## 7. Data Model (Draft)

```
User
  id, phone, pin_hash, name, house_number, occupation,
  blood_group, photo_url, role [pending|member|admin|super_admin],
  created_at, approved_at, approved_by

Collection
  id, user_id, amount, period_month, period_year, recorded_by, created_at

Expense
  id, description, category, amount, date, receipt_photo_url,
  approved_by, created_at

Issue
  id, reported_by, description, photo_url, status [reported|in_progress|resolved],
  status_updated_by, created_at, updated_at

Announcement
  id, title, body, posted_by, created_at
```

## 8. Phased Build Plan

**Phase 1 — MVP**
- Auth (signup, PIN login, admin approval queue)
- Member directory
- Collections log + aggregate totals
- Expenses log
- Dashboard with live balance

**Phase 2**
- Issue/complaint tracking
- Announcements
- Blood group emergency search/filter

**Phase 3**
- Polls/voting for committee decisions
- SMS notifications (new announcement, payment recorded, issue resolved)
- Receipt photo uploads polish, export to PDF/Excel for offline records

## 9. Open Questions for the Committee (resolve before/during Phase 1 build)

1. Should individual contribution *amounts* be visible to all members, or just paid/unpaid status?
2. Who counts as Super Admin vs. Block Admin initially — is this one person or a small group?
3. Should past Excel records be migrated/imported, or does the ledger start fresh at launch?
4. Is a local Pakistani SMS gateway preferred over Twilio for cost/deliverability?
