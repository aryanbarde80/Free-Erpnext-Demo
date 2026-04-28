FROM frappe/erpnext:v15

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV FRAPPE_BENCH=/home/frappe/frappe-bench
ENV PORT=8000
ENV SITE_NAME=site1.local
ENV ADMIN_PASSWORD=admin
ENV DB_ROOT_PASSWORD=admin
ENV FRAPPE_DB_NAME=site1_local
ENV FRAPPE_DB_USER=frappe
ENV FRAPPE_DB_PASSWORD=frappe

RUN apt-get update \
    && apt-get install -y --no-install-recommends mariadb-server redis-server supervisor \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/supervisor /var/run/mysqld /run/redis /etc/supervisor/conf.d \
    && chown -R mysql:mysql /var/lib/mysql /var/run/mysqld \
    && chown -R redis:redis /var/lib/redis /run/redis \
    && chown -R frappe:frappe /home/frappe

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY README.md /workspace/README.md

RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /home/frappe

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
