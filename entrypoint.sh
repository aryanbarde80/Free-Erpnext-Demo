#!/usr/bin/env bash
set -euo pipefail

export FRAPPE_BENCH="${FRAPPE_BENCH:-/home/frappe/frappe-bench}"
export SITE_NAME="${SITE_NAME:-site1.local}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
export DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-admin}"
export FRAPPE_DB_NAME="${FRAPPE_DB_NAME:-site1_local}"
export FRAPPE_DB_USER="${FRAPPE_DB_USER:-frappe}"
export FRAPPE_DB_PASSWORD="${FRAPPE_DB_PASSWORD:-frappe}"

mkdir -p /var/run/mysqld /run/redis "$FRAPPE_BENCH/sites"
chown -R mysql:mysql /var/lib/mysql /var/run/mysqld
chown -R redis:redis /var/lib/redis /run/redis
chown -R frappe:frappe /home/frappe

if [ ! -d /var/lib/mysql/mysql ]; then
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

mysql --socket=/run/mysqld/mysqld.sock -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${FRAPPE_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${FRAPPE_DB_USER}'@'localhost' IDENTIFIED BY '${FRAPPE_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${FRAPPE_DB_NAME}\`.* TO '${FRAPPE_DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON *.* TO '${FRAPPE_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

if [ ! -d "$FRAPPE_BENCH/apps/frappe" ]; then
  su -s /bin/bash frappe -c "bench init --skip-assets --frappe-branch version-15 frappe-bench"
fi

if [ -d /home/frappe/bench/apps ] && [ ! -d "$FRAPPE_BENCH/apps/erpnext" ]; then
  cp -a /home/frappe/bench/apps/. "$FRAPPE_BENCH/apps/"
  chown -R frappe:frappe "$FRAPPE_BENCH/apps"
fi

if [ -d /workspace/apps ] && [ ! -d "$FRAPPE_BENCH/apps/erpnext" ]; then
  cp -a /workspace/apps/. "$FRAPPE_BENCH/apps/"
  chown -R frappe:frappe "$FRAPPE_BENCH/apps"
fi

su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g db_host 127.0.0.1"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g redis_cache redis://127.0.0.1:6379"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g redis_queue redis://127.0.0.1:6379"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g redis_socketio redis://127.0.0.1:6379"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -gp webserver_port 8000"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench set-config -g socketio_port 9000"

if [ ! -f "$FRAPPE_BENCH/sites/$SITE_NAME/site_config.json" ]; then
  su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench new-site '$SITE_NAME' --mariadb-root-password '$DB_ROOT_PASSWORD' --db-name '$FRAPPE_DB_NAME' --db-password '$FRAPPE_DB_PASSWORD' --admin-password '$ADMIN_PASSWORD' --install-app erpnext --set-default"
fi

if ! su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench --site '$SITE_NAME' list-apps" | grep -qx "erpnext"; then
  su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench --site '$SITE_NAME' install-app erpnext"
fi

su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench --site '$SITE_NAME' set-config host_name http://localhost:8000"
su -s /bin/bash frappe -c "cd '$FRAPPE_BENCH' && bench use '$SITE_NAME'"

mysqladmin --socket=/run/mysqld/mysqld.sock -uroot -p"${DB_ROOT_PASSWORD}" shutdown >/dev/null 2>&1 || true
pkill -f "redis-server /etc/redis/redis.conf" >/dev/null 2>&1 || true

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
