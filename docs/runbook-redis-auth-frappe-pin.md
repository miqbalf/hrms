# Runbook: Redis password + frappe/erpnext pin (branch `fix/redis-auth-frappe-pin`)

Target: `hr.treeo.id` (Coolify, deploys `main` of `docker-compose.coolify.yml`).
Background: DEPLOY_FIXES.md #21.

## What changes

1. **Redis requires a password.** `redis` runs `redis-server --requirepass ${REDIS_PASSWORD}`,
   the healthcheck authenticates (`REDISCLI_AUTH`), and backend writes
   `redis://:<pw>@redis:6379` into `common_site_config.json` (`redis_cache`, `redis_queue`,
   `redis_socketio`) first thing on every start, before `bench get-app`/`bench build`
   (both talk to redis). Log line: `Redis URLs (with password) written to common_site_config.json`. Image pinned to `redis:6.2.24-alpine` (was moving `6.2-alpine`).
   The compose refuses to start without `REDIS_PASSWORD` (`${REDIS_PASSWORD:?}`), and backend
   refuses a value that is not URL-safe.
2. **Frappe/ERPNext pinned and actually updated.** `FRAPPE_VERSION` default is `v15.124.5`
   (same digest as `v15` on 2026-11-06: frappe 15.126.0 / erpnext 15.124.5). A new one-shot
   service `code-sync` copies `apps/frappe`, `apps/erpnext` and `env` from the image into the
   shared `apps`/`env` volumes before backend starts. Before this, the volumes kept the code
   of the first deploy (15.112.0) forever. Backend still re-clones hrms (`bench get-app`
   re-installs it into `env`) and runs `bench migrate`. `sites` stays persistent.
3. websocket, scheduler and worker wait for `backend:8000` (gunicorn binds only after
   config, hrms install and migrate), so they never start on the old redis URL or old code.

## Owner steps

### 0. Merge order

Merge `fix/fork-pin-fail-closed` and this branch into `main` in either order (checked with
`git merge-tree`: no conflicts). Do **not** merge to `main` until steps 1-2 are done, because
the `main` push redeploys automatically.

### 1. Back up the database (on the Coolify host)

```bash
B=$(docker ps --format '{{.Names}}' | grep -E 'backend' | grep i3p27fxovl8lexv26fdq477z)
docker exec "$B" bench --site hr.treeo.id backup --with-files
docker exec "$B" ls -lt sites/hr.treeo.id/private/backups | head -5
# copy the newest *-database.sql.gz (and files tarballs) off the container/host:
docker cp "$B":/home/frappe/frappe-bench/sites/hr.treeo.id/private/backups ./hrms-backup-$(date +%F)
```

Also note the current versions for the record:
`docker exec "$B" bench version` (expect frappe 15.112.0, erpnext 15.112.0, hrms 15.64.8).

### 2. Set the new env var in Coolify (names only, never commit values)

| Name | Value |
|---|---|
| `REDIS_PASSWORD` | new random value, URL-safe; generate with `openssl rand -hex 32` |

Leave `FRAPPE_VERSION` unset (the compose default `v15.124.5` applies) unless you pin a
different reviewed tag. If Coolify already has `FRAPPE_VERSION=v15` set, delete it or set
it to `v15.124.5`. Optional: `REDIS_IMAGE` (default `redis:6.2.24-alpine`).

### 3. Deploy

1. Merge the branch into `main` and push (Coolify redeploys), or press Redeploy in Coolify.
2. Order Coolify/compose runs: `redis` (with password) + `db` healthy, `code-sync` copies
   the new frappe/erpnext/env and exits 0, then `backend` (set redis URLs, re-clone hrms,
   injector, build, `bench migrate`, gunicorn), then websocket/scheduler/worker once
   `backend:8000` answers. Expect about 4-5 minutes of downtime (rehearsal: code-sync ~25 s, backend ready after 246 s including build and the 15.112 -> 15.126 migrate).
3. `code-sync` shows as exited (0) afterwards. That is expected (`exclude_from_hc: true`).

### 4. Health checks

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://hr.treeo.id/login        # 200
B=$(docker ps --format '{{.Names}}' | grep backend | grep i3p27fxovl8lexv26fdq477z)
R=$(docker ps --format '{{.Names}}' | grep -E '^redis' | grep i3p27fxovl8lexv26fdq477z)
docker exec "$B" bench version          # frappe 15.126.0, erpnext 15.124.5, hrms 15.64.8
docker logs "$B" 2>&1 | grep 'Security patches:'   # "21 applied, ... 0 skipped."
docker logs "$B" 2>&1 | grep -E 'FATAL|SECURITY WARNING|NOAUTH'   # nothing
docker exec "$R" sh -c 'unset REDISCLI_AUTH; redis-cli ping'   # NOAUTH Authentication required.
docker exec "$R" redis-cli ping         # PONG (uses REDISCLI_AUTH from the container env)
docker logs $(docker ps -a --format '{{.Names}}' | grep code-sync | grep i3p27fxovl8lexv26fdq477z) | tail -2
```

- Log in to https://hr.treeo.id as a normal user and open the People workspace and a Leave Application.
- Worker and scheduler logs show no `NOAUTH`/`AuthenticationError`:
  `docker logs <worker> 2>&1 | grep -i auth`.
- Realtime: the desk shows no "socket disconnected" banner; `docker logs <websocket>` has no NOAUTH.

### 5. Rollback

Code and DB move together, because `bench migrate` changes the schema for the new frappe.

1. In Coolify set `FRAPPE_VERSION=v15.112.0` (the previous code; the image tag exists on Docker Hub).
   `code-sync` then copies the old frappe/erpnext back into the volumes.
2. Restore the step-1 backup before backend starts serving users:
   ```bash
   docker cp ./hrms-backup-<date>/<file>-database.sql.gz "$B":/tmp/db.sql.gz
   docker exec "$B" bench --site hr.treeo.id restore /tmp/db.sql.gz \
     --db-root-username root --db-root-password "$DB_ROOT_PASSWORD"
   docker restart "$B"
   ```
3. To roll back the Redis password too, revert this branch's merge on `main` and push.
   Keeping the password with the old frappe is fine: the redis URLs are written at start
   regardless of the frappe version.

Redis holds only cache and the job queue. Queued jobs from before the switch survive the
restart (same `redis-data` volume, same 6.2 RDB format).

## Risks

- Downtime of about 4-5 minutes on deploy (rehearsal: 246 s until backend served).
- frappe 15.112 -> 15.126 and erpnext 15.112 -> 15.124.5 run real migrations; the backup is the safety net.
- If `REDIS_PASSWORD` is missing, Coolify fails the deploy at compose parse time and the old
  containers keep running.
- `code-sync` relies on `depends_on: condition: service_completed_successfully` (Compose v2).
