#!/usr/bin/env bash
set -euo pipefail

export FRAPPE_BENCH="${FRAPPE_BENCH:-/home/frappe/frappe-bench}"
export PORT="${PORT:-8000}"
export SITE_NAME="${SITE_NAME:-site1.local}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
export DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-admin}"
export FRAPPE_DB_NAME="${FRAPPE_DB_NAME:-site1_local}"
export FRAPPE_DB_USER="${FRAPPE_DB_USER:-frappe}"
export FRAPPE_DB_PASSWORD="${FRAPPE_DB_PASSWORD:-frappe}"
export DEMO_EMAIL="${DEMO_EMAIL:-aryanbarde80@gmail.com}"
export DEMO_PASSWORD="${DEMO_PASSWORD:-aryan@123}"

log() {
  echo "[bootstrap] $1"
}

BOOTSTRAP_WEBROOT="/tmp/erpnext-bootstrap"
mkdir -p "${BOOTSTRAP_WEBROOT}"
cat >"${BOOTSTRAP_WEBROOT}/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>ERPNext is starting</title>
    <style>
      body { font-family: Arial, sans-serif; background: #f5f7fb; color: #1f2937; display: grid; place-items: center; min-height: 100vh; margin: 0; }
      main { background: white; padding: 32px; border-radius: 16px; box-shadow: 0 10px 30px rgba(0,0,0,.08); max-width: 560px; }
      h1 { margin-top: 0; font-size: 28px; }
      p { line-height: 1.6; }
      code { background: #eef2ff; padding: 2px 6px; border-radius: 6px; }
    </style>
  </head>
  <body>
    <main>
      <h1>ERPNext is starting</h1>
      <p>The container is initializing MariaDB, Redis, and the Frappe site.</p>
      <p>If this page stays visible for more than a few minutes, check the Render logs for the next startup error.</p>
      <p>Expected site: <code>${SITE_NAME}</code></p>
    </main>
  </body>
</html>
EOF

python3 -m http.server "${PORT}" --bind 0.0.0.0 --directory "${BOOTSTRAP_WEBROOT}" >/tmp/render-port-probe.log 2>&1 &
PORT_PROBE_PID=$!

cleanup_port_probe() {
  if [ -n "${PORT_PROBE_PID:-}" ] && kill -0 "${PORT_PROBE_PID}" >/dev/null 2>&1; then
    kill "${PORT_PROBE_PID}" >/dev/null 2>&1 || true
    wait "${PORT_PROBE_PID}" >/dev/null 2>&1 || true
  fi
}

trap cleanup_port_probe EXIT

log "Bootstrap started for site ${SITE_NAME} on port ${PORT}"

mkdir -p /var/run/mysqld /run/redis "$FRAPPE_BENCH/sites"
chown -R mysql:mysql /var/lib/mysql /var/run/mysqld
chown -R redis:redis /var/lib/redis /run/redis
chown -R frappe:frappe /home/frappe

if [ ! -d /var/lib/mysql/mysql ]; then
  log "Initializing MariaDB data directory"
  mysql_install_db --user=mysql --ldata=/var/lib/mysql >/dev/null
fi

cat >/etc/mysql/mariadb.conf.d/99-erpnext.cnf <<EOF
[mysqld]
bind-address = 127.0.0.1
port = 3306
user = mysql
datadir = /var/lib/mysql
socket = /run/mysqld/mysqld.sock
pid-file = /run/mysqld/mysqld.pid
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-host-cache
skip-name-resolve
performance_schema = OFF
innodb-file-format = barracuda
innodb-file-per-table = 1
innodb-large-prefix = 1
EOF

cat >/etc/redis/redis.conf <<EOF
bind 127.0.0.1
port 6379
protected-mode no
daemonize no
supervised no
dir /var/lib/redis
pidfile /run/redis/redis-server.pid
logfile ""
save ""
appendonly no
EOF

log "Starting MariaDB and Redis for bootstrap"
mysqld_safe --datadir=/var/lib/mysql >/tmp/mariadb-bootstrap.log 2>&1 &
redis-server /etc/redis/redis.conf >/tmp/redis-bootstrap.log 2>&1 &

for _ in $(seq 1 60); do
  if mysqladmin ping --socket=/run/mysqld/mysqld.sock --silent >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! mysqladmin ping --socket=/run/mysqld/mysqld.sock --silent >/dev/null 2>&1; then
  echo "MariaDB failed to start during bootstrap." >&2
  exit 1
fi

log "MariaDB is ready"

for _ in $(seq 1 30); do
  if redis-cli ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! redis-cli ping >/dev/null 2>&1; then
  echo "Redis failed to start during bootstrap." >&2
  exit 1
fi

log "Redis is ready"
log "Configuring MariaDB users and database"

mysql --socket=/run/mysqld/mysqld.sock -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${FRAPPE_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${FRAPPE_DB_USER}'@'localhost' IDENTIFIED BY '${FRAPPE_DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${FRAPPE_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${FRAPPE_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${FRAPPE_DB_NAME}\`.* TO '${FRAPPE_DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${FRAPPE_DB_NAME}\`.* TO '${FRAPPE_DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON *.* TO '${FRAPPE_DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON *.* TO '${FRAPPE_DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

if [ ! -d "$FRAPPE_BENCH/apps/frappe" ] || [ ! -d "$FRAPPE_BENCH/apps/erpnext" ]; then
  echo "The base image does not contain a ready frappe bench with erpnext installed at ${FRAPPE_BENCH}." >&2
  exit 1
fi

log "Configuring bench"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g db_host localhost"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g redis_cache redis://127.0.0.1:6379"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g redis_queue redis://127.0.0.1:6379"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g redis_socketio redis://127.0.0.1:6379"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -gp webserver_port ${PORT}"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g socketio_port 9000"

if [ -f "$FRAPPE_BENCH/Procfile" ]; then
  sed -i "s|^web: .*|web: bench serve --host 0.0.0.0 --port ${PORT}|" "$FRAPPE_BENCH/Procfile"
fi

if [ ! -f "$FRAPPE_BENCH/sites/$SITE_NAME/site_config.json" ]; then
  log "Creating site ${SITE_NAME}"
  su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench new-site '$SITE_NAME' --mariadb-root-password '$DB_ROOT_PASSWORD' --db-name '$FRAPPE_DB_NAME' --db-password '$FRAPPE_DB_PASSWORD' --admin-password '$ADMIN_PASSWORD' --install-app erpnext --set-default"
fi

if ! su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench --site '$SITE_NAME' list-apps" | grep -qx "erpnext"; then
  log "Installing ERPNext on ${SITE_NAME}"
  su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench --site '$SITE_NAME' install-app erpnext"
fi

log "Ensuring demo login user exists"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && . env/bin/activate && python - <<'PY'
import frappe
from frappe.utils.password import update_password

site = '${SITE_NAME}'
email = '${DEMO_EMAIL}'
password = '${DEMO_PASSWORD}'

frappe.init(site=site, sites_path='sites')
frappe.connect()

if frappe.db.exists('User', email):
    user = frappe.get_doc('User', email)
else:
    user = frappe.get_doc({
        'doctype': 'User',
        'email': email,
        'first_name': 'Aryan',
        'last_name': 'Demo',
        'enabled': 1,
        'send_welcome_email': 0,
        'user_type': 'System User',
        'roles': [{'role': 'System Manager'}],
    })
    user.insert(ignore_permissions=True)

user.enabled = 1
user.user_type = 'System User'
user.save(ignore_permissions=True)
update_password(email, password)
frappe.db.commit()
frappe.destroy()
PY"

su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench --site '$SITE_NAME' set-config host_name http://localhost:${PORT}"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench use '$SITE_NAME'"

log "Bootstrap complete, handing over to supervisord"

mysqladmin --socket=/run/mysqld/mysqld.sock -uroot -p"${DB_ROOT_PASSWORD}" shutdown >/dev/null 2>&1 || true
pkill -f "redis-server /etc/redis/redis.conf" >/dev/null 2>&1 || true

cleanup_port_probe
trap - EXIT

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
