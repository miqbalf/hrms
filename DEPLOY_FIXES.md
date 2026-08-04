# HRMS Deployment Fixes — Summary

**Target**: `hr.treeo.id` on Coolify v4.1.2 (server: `root@167.233.97.207`)
**Stack**: Frappe Framework v15.112.0, ERPNext v15.112.0, Frappe HR upstream version-15
**Base Image**: `frappe/erpnext:v15` (does NOT include hrms pre-installed)

---

## Problems Encountered & Fixes Applied

### 1. `apply_branding` not found on startup
- **Symptom**: `AttributeError: module 'hrms.utils' has no attribute 'apply_branding'`
- **Root cause**: Python shadowing — `hrms/utils.py` (module file) and `hrms/utils/__init__.py` (package init) both exist; Python loads the package, which didn't have `apply_branding`.
- **Fix**: Added `apply_branding()` function definition into `hrms/utils/__init__.py` (committed to fork).

### 2. HRMS app remote URL pointed to wrong fork/branch
- **Original**: `bench get-app hrms https://github.com/miqbalf/hrms.git --branch version-15`
- **Problem**: `miqbalf/hrms` does NOT have a `version-15` branch. Only `main` and `develop`.
- **Fix attempt 1**: Changed to `--branch main` → installed v17 code → broke People workspace and caused v16/v17 DB migration issues.
- **Final fix**: Switched to upstream `frappe/hrms` (not our fork): `bench get-app hrms https://github.com/frappe/hrms.git --branch version-15`. This is the original v15 code with the People workspace intact.

### 3. Bash syntax error causing infinite restart loop
- **Symptom**: Extra `fi` at line 73 of docker-compose startup script.
- **Fix**: Removed the extra `fi`.

### 4. Missing Docker network after container cleanup
- **Symptom**: `Error: network i3p27fxovl8lexv26fdq477z declared as external, but could not be found`
- **Fix**: Manually created the network: `docker network create i3p27fxovl8lexv26fdq477z`

### 5. `is_half_holiday` import error from erpnext
- **Symptom**: `ImportError: cannot import name 'is_half_holiday' from 'erpnext.setup.doctype.holiday_list.holiday_list'`
- **Root cause**: The `is_half_holiday` function was added to erpnext in a later version but base image has v15 which lacks it.
- **Fix**: Implemented `is_half_holiday()` locally in `hrms/utils/__init__.py` and changed import in `shift_type.py` from erpnext to our local function.

### 6. Static assets (JS/CSS bundles, logos) not served by nginx
- **Symptom**: 404 for frappe/erpnext/hrms bundles and logo images
- **Root cause**: `bench build` replaces `sites/assets/` with a symlink to `/home/frappe/frappe-bench/assets/`. The frontend nginx container shares the `sites` volume but can't follow the symlink because the target path is in per-container image layers.
- **Fix**: After `bench build`, copy dereferenced assets from the symlink target to the shared volume:
  ```bash
  rm -rf sites/assets
  bench build || true
  cp -rL sites/assets/ /tmp/assets-content
  rm -rf sites/assets
  mv /tmp/assets-content sites/assets
  ```
  This puts real files on the shared `sites` volume, accessible to both backend and nginx.

### 7. `assets.json` hash mismatches
- **Symptom**: Bundles exist but `assets.json` references wrong hashes → desk JS/CSS 404s
- **Root cause**: `bench build --app hrms` only rebuilds hrms bundles; frappe/erpnext entries in `assets.json` were stale from previous deploy.
- **Fix**: Run full `bench build` (no `--app` flag) to regenerate complete `assets.json` with correct hashes.

### 8. Cloudflare cache of 404 responses
- **Symptom**: Fixed assets returned 404 due to Cloudflare caching old responses.
- **Fix**: Cache expired naturally (max-age: 14400). Cloudflare API token not available for manual purge.

### 9. `readlink -f` returning `/` on Alpine Linux
- **Symptom**: `cp -r` copied the entire root filesystem into `sites/assets/` because `readlink -f` incorrectly resolved a relative symlink to `/`.
- **Fix**: Removed `readlink -f` usage entirely. Use `cp -rL sites/assets/` directly (cp resolves symlinks relative to the symlink's directory, not current working directory).

### 10. v16 migration patches crashing on v15 DB
- **Symptom**: `pymysql.err.OperationalError: (1054, "Unknown column 'payment_entry' in 'WHERE'")`
- **Root cause**: The fork's `main` branch is v17 dev code with v16/v17 migration patches referencing columns that don't exist in v15 ERPNext.
- **Patches needed guarding**:
  - `set_reference_fields_in_expense_claim_advance` — `payment_entry` column
  - `set_base_paid_amount_in_employee_advance` — `base_paid_amount` column  
  - `set_currency_and_base_fields_in_expense_claim` — 14 `base_*` columns
  - `make_people_workspace_sidebar_standard` — `standard` column
- **Fix**: Added `frappe.db.has_column()` guards so patches skip silently on v15. **Note**: After switching to upstream v15 hrms, these patches no longer exist in the codebase — they're v17-specific.

### 11. People workspace missing (`/desk/people` 404)
- **Symptom**: Clicking FrappeHR app → "Page not found" at `/app/people`
- **Root cause**: Switched to `miqbalf/hrms` main branch (v17 code) which removed the People workspace (split into module workspaces: recruitment, leaves, etc.).
- **Fix**: Reverted to upstream `frappe/hrms` version-15 which has the original People workspace.

### 12. Expense Claim submit crash (fieldtype error)
- **Symptom**: `AttributeError: 'NoneType' object has no attribute 'fieldtype'` when submitting Expense Claim.
- **Root cause**: The v17 expense_claim.py uses:
  - `doc.set("base_" + f, val)` — sets v16-only `base_*` fields not in v15 DB.
  - `[{"SUM": "allocated_amount"}]` — v16 Frappe query syntax not supported in v15.
- **Fix**: After reverting to upstream v15 hrms, these issues no longer exist (upstream v15 code is v15-compatible).

### 13. `custom-assets/` bind mount files not deployed
- **Symptom**: `cp: cannot stat '/home/frappe/custom-assets/treeo_logo.png'`, files missing from Docker bind mount.
- **Root cause**: Coolify does not copy `docker/assets/` directory contents during deployment (directory exists but empty on server).
- **Manual fix**: Uploaded files via `ssh_upload` to `/data/coolify/applications/i3p27fxovl8lexv26fdq477z/docker/assets/`.
- **Compose fix**: All `cp` operations from `custom-assets/` now have `2>/dev/null || true` — non-fatal.

### 14. YAML heredoc broke docker-compose parsing
- **Symptom**: Deploy failed with "no service selected" — YAML scanner error.
- **Root cause**: Embedding Python code (with tabs) inside a YAML `|` block scalar caused parsing failure. Tabs in YAML literal blocks cause issues.
- **Fix**: Instead of embedding full Python code → use separate `treeo_branding.py` module file:
  - Copy `docker/assets/treeo_branding.py` to `apps/hrms/hrms/utils/treeo_branding.py`
  - Append import line to `__init__.py`: `from hrms.utils.treeo_branding import apply_branding, is_half_holiday`

### 15. `frappe-hr-logo.svg` / TREEO icon
- **Symptom**: "WARNING: frappe-hr-logo.svg not found" on startup.
- **Fix**: Copy from `custom-assets/` bind mount (non-fatal with `|| true`). SVG serves from `sites/assets/hrms/images/` on shared volume.

---

## Current Architecture (Production-Ready)

### Docker Compose: `docker-compose.coolify.yml`

**Services**: db (mariadb:10.6), redis (6.2-alpine), backend, frontend (nginx), websocket, scheduler, worker

**Backend startup flow** (on every deploy/restart):

```bash
# Phase 1: Install/Update
cd /home/frappe/frappe-bench
rm -rf apps/hrms                              # Always clean install from upstream v15
bench get-app hrms https://github.com/frappe/hrms.git --branch version-15

# Inject TREEO branding module
mkdir -p apps/hrms/hrms/utils
cp /home/frappe/custom-assets/treeo_branding.py apps/hrms/hrms/utils/treeo_branding.py  # if bind mount has it
echo "from hrms.utils.treeo_branding import apply_branding, is_half_holiday" >> apps/hrms/hrms/utils/__init__.py

# Build assets
rm -rf sites/assets
bench build || true
cp -rL sites/assets/ /tmp/assets-content       # Dereference symlinks to real files
rm -rf sites/assets
mv /tmp/assets-content sites/assets            # Put on shared volume
cp frappe-hr-logo.svg ... 2>/dev/null || true  # Non-fatal

# Phase 2: Wait for services
wait-for-it db:3306 && wait-for-it redis:6379

# Phase 3: Migrate or create site
bench --site hr.treeo.id migrate               # (or new-site on first deploy)
cp treeo_logo.png ... 2>/dev/null || true      # Branding images (non-fatal)
cp favicon.png ... 2>/dev/null || true
bench --site hr.treeo.id execute hrms.utils.apply_branding || true  # DB branding (non-fatal)

# Phase 4: Start
exec gunicorn frappe.app:application
```

**Volumes**:
| Volume | Path | Shared? | Purpose |
|--------|------|---------|---------|
| `sites` | `/home/frappe/frappe-bench/sites` | backend + frontend | Static assets, site config |
| `apps` | `/home/frappe/frappe-bench/apps` | backend only | App source code |
| `env` | `/home/frappe/frappe-bench/env` | backend only | Python virtualenv |
| `logs` | `/home/frappe/frappe-bench/logs` | backend + frontend | Logs |
| bind | `/data/coolify/.../docker/assets` → `/home/frappe/custom-assets` | backend only | TREEO branding files |

**Key decisions**:
- **Use upstream `frappe/hrms` version-15** (not our fork) — guaranteed v15 compatibility, has People workspace
- **`rm -rf apps/hrms` on every deploy** — clean slate avoids stale fork code
- **All branding operations non-fatal** (`|| true`) — deploy succeeds even without custom assets
- **Assets dereferenced to real files on shared volume** — nginx can serve them without following symlinks
- **Custom `apply_branding` via separate `treeo_branding.py` module** — injected via import, not file replacement

---

## Files That Need Manual Upload to Server

These files are in the git repo under `docker/assets/` but Coolify's bind mount may not deploy them:

| File | Purpose | Size |
|------|---------|------|
| `treeo_branding.py` | `apply_branding` + `is_half_holiday` functions | 1KB |
| `treeo_logo.png` | App logo (desk/login header) | 103KB |
| `favicon.png` | Browser favicon | 2KB |
| `frappe-hr-logo.svg` | FrappeHR app icon in desk sidebar | 37KB |
| `treeo-icon.png` | Extra icon | 27KB |

**Upload path**: `/data/coolify/applications/i3p27fxovl8lexv26fdq477z/docker/assets/`

The compose file already handles missing files gracefully (all `cp` operations have `|| true`), but branding won't apply without `treeo_branding.py` in the bind mount.

---

### 16. Traefik 503 — `${SITE_NAME}` not substituted in labels by Coolify
- **Symptom**: Site returns 503 immediately after deployment. All containers healthy. Nginx returns 200 when accessed directly.
- **Root cause**: Coolify does NOT perform Docker Compose variable substitution inside the `labels:` block. The label `Host(\`${SITE_NAME:-hr.treeo.id}\`)` was stored literally on the container; Traefik rejected it as an invalid hostname (`"${site_name:-hr.treeo.id}" is not a valid hostname`) and created no HTTPS route.
- **Evidence**: `docker logs coolify-proxy | grep "Error while adding route"` shows the exact error.
- **Fix**: Hardcode the hostname in the Traefik router rule — no variable substitution needed: `Host(\`hr.treeo.id\`)`.
- **Long-term rule**: Never use `${VAR}` in `labels:` in Coolify-managed compose files. Use literals or set the value directly in Coolify's environment variables UI so it's substituted at the shell level.

### 17. Google Calendar leave sync silently disappeared after redeploy
- **Symptom**: Approved leave applications stopped appearing on employees' Google Calendars. `google_calendar_synced = 0`, `google_calendar_event_id = NULL`, and **zero Error Log rows** — the hook was never firing at all.
- **Root cause**: The calendar sync feature lives only in this fork (`hrms/hr/doctype/leave_application/leave_calendar_sync.py` + the `Leave Application` entry in `doc_events`). Production does `rm -rf apps/hrms && bench get-app hrms https://github.com/frappe/hrms.git` on every deploy, so **fork code is never present at runtime**. The feature only ever worked because the file had been hand-copied into the live container; the 2026-07-16 redeploy re-cloned upstream and wiped it. The branding and Email Queue customizations survived because the compose file explicitly re-injects them — calendar sync had no such injection step.
- **Why it looked like a config problem**: the custom fields (`google_calendar_synced`, `google_calendar_event_id`, `enable_google_calendar_sync`) live in the **database**, which persists across redeploys. So the fields and the enabled checkbox all looked correct while the code implementing them was absent.
- **Fix**:
  - `docker/assets/leave_calendar_sync.py` — the module, shipped via the `custom-assets` bind mount.
  - `docker/assets/inject_calendar_sync.sh` — copies it into the freshly cloned app and appends the `doc_events` + `scheduler_events` registration to the end of `hooks.py` (append-only, so it never has to match upstream's dict formatting). Idempotent via a `grep -q leave_calendar_sync` guard.
  - `docker-compose.coolify.yml` — calls the injection script in Phase 1, and runs `leave_calendar_sync.ensure_custom_fields` after migrate so a rebuilt site recreates the custom fields (fork `hrms/patches/` never runs in production either, for the same reason).
  - Added `sync_pending_leaves` on the **hourly** scheduler as a safety net: any approved, submitted, not-yet-synced leave whose `to_date >= today` gets retried. This self-heals transient Google API failures and missed hooks. Scoped to current/future leaves so it can't spin forever on old rows that can never succeed.
- **Lesson — the general rule**: any change to hrms Python source must ship as a `docker/assets/` file **plus** an injection step in the compose Phase 1. A change committed only to the fork's `hrms/` tree is dead code in production. Same goes for anything in `hrms/patches/` — write it as an idempotent function and call it from the deploy script instead.
- **After changing hooks, running processes must be refreshed** — `hooks.py` is cached in `sys.modules` per process, so `bench clear-cache` is *not* enough:
  - **`doc_events`** (real-time sync on submit) are read per request by the gunicorn **workers**. Send `SIGHUP` to the gunicorn master (`docker kill -s HUP <backend>`) — workers re-fork and import the new file. Do *not* `docker restart` the backend: its entrypoint re-runs Phase 1 (re-clone + `bench build`), which is minutes of downtime. SIGHUP is safe even with `--preload`, because hooks are imported lazily per request (after the fork), so the stale module lives in the worker, not the master.
  - **`scheduler_events`** are *not* read from hooks at run time. v15 syncs them into `Scheduled Job Type` records via `sync_jobs()` (which `bench migrate` calls), and the scheduler enqueues from that table. So a new scheduled job needs `bench --site <site> execute frappe.core.doctype.scheduled_job_type.scheduled_job_type.sync_jobs` — restarting the scheduler container does nothing on its own.
  - A newly created job's first run is based on its `creation` timestamp, not `last_execution` — an `Hourly` job created at 19:40 first fires at 20:00, not immediately. Force one with `frappe.get_doc("Scheduled Job Type", name).enqueue(force=True)` to verify the chain.

---

## Known Remaining Issues

1. **`cp: cannot stat treeo_logo.png / favicon.png`** — non-fatal, branding images missing but site still runs.
2. **`Assets for Release /bin/sh: Syntax error`** — harmless bench build warning, can be ignored.
3. **npm peer dependency warnings** — Vite packages complaining about missing peers, harmless.
4. **Bind mount files may not survive Coolify redeploys** — if Coolify cleans the application directory, re-upload files.

---

## Git Branches

- `develop` — latest fixes applied
- `main` — synced with develop (Coolify deploys from main)
- Both point to `miqbalf/hrms` fork, but only `docker-compose.coolify.yml` and `docker/assets/` are relevant. The hrms source in the fork is NOT used at runtime (we use upstream `frappe/hrms`).
