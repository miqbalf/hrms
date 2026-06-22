# Optimize Coolify Deployment for Low-Resource Setup (<10 Users)

This plan optimizes the `docker-compose.coolify.yml` deployment configuration. It addresses the **degraded container status** issue in Coolify (caused by one-shot setup containers exiting) and minimizes server resource consumption (CPU and RAM) to make it highly efficient for a small team of under 10 users.

## User Review Required

> [!IMPORTANT]
> The setup utilizes a single Redis instance instead of separate Cache and Queue containers. It also collapses the three background worker services (Short, Default, and Long) into a single worker process listening to all queues sequentially. This is highly recommended for under 10 users and reduces memory usage significantly, but execution of background jobs will be serialized.

## Proposed Changes

### Deployment Configuration

#### [MODIFY] [docker-compose.coolify.yml](file:///Volumes/DATA_SSD/Github/hrms/docker-compose.coolify.yml)

We will modify this file to:
1. **Remove one-shot services** (`configurator` and `create-site`).
2. **Consolidate configuration & setup logic** into the `backend` container's entrypoint. The setup will only run on the first startup or database migration, and then Gunicorn will start.
3. **Consolidate worker queues**: Replace `worker-default`, `worker-short`, and `worker-long` with a single `worker` container running `bench worker --queue short,default,long`.
4. **Reduce Gunicorn workers**: Configure Gunicorn with 1 worker to save RAM.
5. **Consolidate Redis**: Combine `redis-cache` and `redis-queue` into a single `redis` container.
6. **Add start synchronization**: Have the websocket, scheduler, and worker containers wait for the site config file to exist before starting up, ensuring zero startup crashes.

Here is the proposed configuration:

```yaml
version: "3.8"

services:
  # Database Service — Production MariaDB
  db:
    image: "${MARIADB_IMAGE:-mariadb:10.6}"
    restart: unless-stopped
    command:
      - "--character-set-server=utf8mb4"
      - "--collation-server=utf8mb4_unicode_ci"
      - "--skip-character-set-client-handshake"
      - "--skip-innodb-read-only-compressed"
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
      MARIADB_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
    volumes:
      - db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "--password=${DB_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 20

  # Combined Redis Cache & Queue Service
  redis:
    image: "${REDIS_IMAGE:-redis:6.2-alpine}"
    restart: unless-stopped
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  # Python backend (Gunicorn) service + Configurator & Site Setup
  backend:
    image: "${FRAPPE_IMAGE:-frappe/erpnext}:${FRAPPE_VERSION:-v15}"
    restart: unless-stopped
    entrypoint: ["bash", "-c"]
    command:
      - |
        echo "=== Phase 1: Bench configuration ==="
        bench get-app hrms --branch version-15 || true
        ls -1 apps > sites/apps.txt
        bench set-config -g db_host $$DB_HOST
        bench set-config -gp db_port $$DB_PORT
        bench set-config -g redis_cache "redis://$$REDIS_CACHE"
        bench set-config -g redis_queue "redis://$$REDIS_QUEUE"
        bench set-config -g redis_socketio "redis://$$REDIS_QUEUE"
        bench set-config -gp socketio_port $$SOCKETIO_PORT

        echo "=== Phase 2: Service availability checks ==="
        wait-for-it -t 120 db:3306
        wait-for-it -t 120 redis:6379

        echo "=== Phase 3: Site creation or migration ==="
        if [ ! -d "sites/$$SITE_NAME" ]; then
          echo "Creating new site $$SITE_NAME..."
          bench new-site $$SITE_NAME \
            --no-mariadb-socket \
            --admin-password "$$ADMIN_PASSWORD" \
            --db-root-username root \
            --db-root-password "$$DB_ROOT_PASSWORD" \
            --mariadb-user-host-login-scope '%' \
            --install-app erpnext \
            --set-default

          echo "Installing hrms app on $$SITE_NAME..."
          bench --site $$SITE_NAME install-app hrms

          echo "Applying TREEO branding & taglines..."
          bench --site $$SITE_NAME set-config app_title "TREEO HR system"
          bench --site $$SITE_NAME set-config app_description "TREEO HR system - Empowering People, Restoring Nature"
          bench --site $$SITE_NAME enable-scheduler

          bench --site $$SITE_NAME execute "frappe.db.set_single_value('Navbar Settings', 'app_logo', '/files/treeo_logo.png')"
          bench --site $$SITE_NAME execute "frappe.db.set_single_value('Website Settings', 'app_logo', '/files/treeo_logo.png')"
          bench --site $$SITE_NAME execute "frappe.db.set_single_value('Website Settings', 'favicon', '/files/treeo_logo.png')"
          bench --site $$SITE_NAME execute "frappe.db.set_single_value('Website Settings', 'brand_html', '<span class=\"brand-label\">TREEO HR system</span>')"
          bench --site $$SITE_NAME execute "frappe.db.set_single_value('Website Settings', 'tagline', 'TREEO HR system')"
          bench --site $$SITE_NAME execute "frappe.db.commit()"
          echo "Site $$SITE_NAME initialized successfully!"
        else
          echo "Site $$SITE_NAME already exists. Running migration..."
          bench --site $$SITE_NAME migrate
        fi

        echo "=== Phase 4: Start Gunicorn backend ==="
        exec /home/frappe/frappe-bench/env/bin/gunicorn \
          --chdir=/home/frappe/frappe-bench/sites \
          --bind=0.0.0.0:8000 \
          --threads=4 \
          --workers=1 \
          --worker-class=gthread \
          --worker-tmp-dir=/dev/shm \
          --timeout=120 \
          --preload \
          frappe.app:application
    environment:
      FRAPPE_SITE_NAME_HEADER: "${SITE_NAME:-hr.treeo.id}"
      DB_HOST: db
      DB_PORT: "3306"
      REDIS_CACHE: redis:6379
      REDIS_QUEUE: redis:6379
      SOCKETIO_PORT: "9000"
      SITE_NAME: "${SITE_NAME:-hr.treeo.id}"
      DB_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
      ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  # Real-time websocket notifications
  websocket:
    image: "${FRAPPE_IMAGE:-frappe/erpnext}:${FRAPPE_VERSION:-v15}"
    restart: unless-stopped
    entrypoint: ["bash", "-c"]
    command:
      - |
        echo "Waiting for site config..."
        until [ -f sites/common_site_config.json ]; do sleep 2; done
        echo "Site config ready! Starting websocket server..."
        exec node /home/frappe/frappe-bench/apps/frappe/socketio.js
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    depends_on:
      backend:
        condition: service_started

  # Frontend Nginx proxy serving static assets
  frontend:
    image: "${FRAPPE_IMAGE:-frappe/erpnext}:${FRAPPE_VERSION:-v15}"
    restart: unless-stopped
    command:
      - nginx-entrypoint.sh
    environment:
      BACKEND: backend:8000
      SOCKETIO: websocket:9000
      UPSTREAM_REAL_IP_ADDRESS: 127.0.0.1
      UPSTREAM_REAL_IP_HEADER: X-Forwarded-For
      UPSTREAM_REAL_IP_RECURSIVE: "off"
      PROXY_READ_TIMEOUT: 300
      CLIENT_MAX_BODY_SIZE: 50m
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    depends_on:
      backend:
        condition: service_started
      websocket:
        condition: service_started
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.frappe-hr-router.rule=Host(`${SITE_NAME:-hr.treeo.id}`)"
      - "traefik.http.routers.frappe-hr-router.entryPoints=https"
      - "traefik.http.routers.frappe-hr-router.tls=true"
      - "traefik.http.routers.frappe-hr-router.tls.certresolver=letsencrypt"
      - "traefik.http.services.frontend.loadbalancer.server.port=8080"

  # Scheduler for background crons
  scheduler:
    image: "${FRAPPE_IMAGE:-frappe/erpnext}:${FRAPPE_VERSION:-v15}"
    restart: unless-stopped
    entrypoint: ["bash", "-c"]
    command:
      - |
        echo "Waiting for site config..."
        until [ -f "sites/$$SITE_NAME/site_config.json" ]; do sleep 5; done
        echo "Site ready! Starting scheduler..."
        exec bench schedule
    environment:
      SITE_NAME: "${SITE_NAME:-hr.treeo.id}"
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    depends_on:
      backend:
        condition: service_started

  # Single Combined Queue Worker (Default, Short, Long)
  worker:
    image: "${FRAPPE_IMAGE:-frappe/erpnext}:${FRAPPE_VERSION:-v15}"
    restart: unless-stopped
    entrypoint: ["bash", "-c"]
    command:
      - |
        echo "Waiting for site config..."
        until [ -f "sites/$$SITE_NAME/site_config.json" ]; do sleep 5; done
        echo "Site ready! Starting worker..."
        exec bench worker --queue short,default,long
    environment:
      SITE_NAME: "${SITE_NAME:-hr.treeo.id}"
    volumes:
      - sites:/home/frappe/frappe-bench/sites
      - logs:/home/frappe/frappe-bench/logs
    depends_on:
      backend:
        condition: service_started

volumes:
  db-data:
  redis-data:
  sites:
  logs:
```

## Verification Plan

### Manual Verification
- Deploy the updated `docker-compose.coolify.yml` to the Coolify server.
- Verify in Coolify that all containers are labeled as Green (Running/Healthy) and there are no degraded ones.
- Check backend logs to verify that database configuration and site setup/migration ran successfully.
- Verify that the frontend is accessible and background workers run correctly.
