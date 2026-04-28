# ERPNext Single-Container Deployment

This repository packages ERPNext on the Frappe Framework into a single Docker container that is suitable for platforms such as Render where `docker-compose` is not available.

## Included Services

- ERPNext and Frappe Bench from the official `frappe/erpnext` base image
- MariaDB running inside the same container
- Redis running inside the same container
- Supervisor managing all long-running processes

## Repository Files

- `Dockerfile`
- `entrypoint.sh`
- `supervisord.conf`
- `render.yaml`
- `README.md`

## Behavior

- Initializes `frappe-bench` automatically if it is missing
- Creates `site1.local` automatically on first boot
- Sets the Administrator password to `admin`
- Installs the ERPNext app automatically
- Starts MariaDB, Redis, and the Frappe Bench process stack in one container
- Exposes the app on `http://localhost:8000`

## Deploy

### Docker

```bash
docker build -t erpnext-single .
docker run -p 8000:8000 erpnext-single
```

### Render

The repo includes `render.yaml` for a Docker web service deployment with a persistent disk mounted at:

```text
/home/frappe/frappe-bench/sites
```

## Demo Login

Use the following demo credentials after the site is ready:

- Email: `aryanbarde80@gmail.com`
- Password: `aryan@123`

## Default System Credentials

- Site name: `site1.local`
- Admin user: `Administrator`
- Admin password: `admin`

## Notes

- This setup is intended for demo, testing, and simplified single-container hosting.
- Persistent site data is stored under the `sites` directory so it can survive container restarts when a disk is attached.
