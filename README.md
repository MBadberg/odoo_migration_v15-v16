# Odoo Migration v15 → v16

A Bash script that automates migrating an Odoo 15 Community Edition instance to Odoo 16 using the [OCA OpenUpgrade](https://github.com/OCA/OpenUpgrade) framework.

## Prerequisites

- Ubuntu 20.04 or 22.04
- Root / `sudo` access
- A running Odoo 15 installation with a PostgreSQL database
- Internet access (to clone repositories and download packages)

## Configuration

Before running the script, edit the variables at the top of `migration_v15-v16.sh`:

| Variable | Description |
|---|---|
| `ODOO_USER` | System user that runs Odoo (e.g. `odoo`) |
| `ODOO_DB` | Name of the Odoo 15 database to migrate |
| `DB_USER` | PostgreSQL user with access to the database |
| `DB_PASSWORD` | PostgreSQL password — leave empty to use peer authentication (Unix socket) |
| `ODOO15_FILESTORE` | Path to the Odoo 15 filestore directory |
| `ODOO16_BASE` | Base directory for the new Odoo 16 installation (default: `/opt/odoo16`) |
| `ODOO15_SERVICE` | systemd service name of the Odoo 15 instance (default: `odoo15`) |

## Usage

```bash
sudo bash migration_v15-v16.sh
```

### Re-running with an existing backup

If you already have a backup and want to skip the backup step:

```bash
sudo SKIP_BACKUP=1 BACKUP_DIR=/var/backups/odoo-migration-<date> bash migration_v15-v16.sh
```

## What the script does

The script runs eight steps in sequence:

1. **Prerequisites** — installs required system packages and `wkhtmltopdf 0.12.6`.
2. **Backup** — stops the Odoo 15 service, dumps the database with `pg_dump`, and copies the filestore to a timestamped backup directory under `/var/backups/`.
3. **Clone repositories** — clones (or updates) two Git repositories at branch `16.0`:
   - `odoo/odoo` — Odoo 16 core
   - `OCA/OpenUpgrade` — migration modules and scripts
4. **Python virtual environment** — creates a venv under `ODOO16_BASE/venv` and installs all Python requirements including `openupgradelib`.
5. **Database clone** — restores the backup into a new database named `<ODOO_DB>_v16` and copies the filestore for the new database.
6. **Configuration** — writes `/etc/odoo16.conf` with the correct `addons_path`, `upgrade_path`, and database settings.
7. **Migration** — runs `odoo-bin --update all --stop-after-init` via the OpenUpgrade framework. Output is shown live and saved to `/var/log/odoo/odoo16-migrate.log`. A sanity check verifies that the `base` module is now at version 16.x.
8. **systemd service** — creates and enables `/etc/systemd/system/odoo16.service` so Odoo 16 starts automatically.

## After the migration

1. Review the migration log:
   ```bash
   less /var/log/odoo/odoo16-migrate.log
   ```
2. Start Odoo 16:
   ```bash
   systemctl start odoo16
   ```
3. Open `http://<server>:8069` in a browser and select the `<ODOO_DB>_v16` database.
4. Port any custom modules to Odoo 16, place them in `ODOO16_BASE/custom-addons`, then update them:
   ```bash
   sudo -u <ODOO_USER> /opt/odoo16/venv/bin/python3 /opt/odoo16/odoo/odoo-bin \
     -c /etc/odoo16.conf -d <ODOO_DB>_v16 -u <module> --stop-after-init
   ```

## Notes

- The original Odoo 15 database is **never modified** — migration runs on the cloned `<ODOO_DB>_v16` database.
- Run the script from a user home directory or `/tmp`, not from `/root/script`, to avoid PostgreSQL working-directory warnings.
- The migration can take a long time (potentially hours) depending on database size.
