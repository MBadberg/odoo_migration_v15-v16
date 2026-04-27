#!/usr/bin/env bash
###############################################################################
# Odoo 15 -> 16 Migration Script (Community Edition) mit OCA OpenUpgrade
# Autor: erstellt für MBadberg
# Getestet auf: Ubuntu 20.04 / 22.04
#
# Vorgehen:
#  1) Voraussetzungen prüfen & Pakete installieren
#  2) Backup von DB + Filestore von Odoo 15
#  3) Odoo 16 Core + OpenUpgrade-Migrationsskripte klonen (zwei Repos!)
#  4) Python venv für Odoo 16 anlegen
#  5) DB-Klon "<dbname>_v16" erstellen, in dem migriert wird
#  6) Odoo16-Konfiguration mit upgrade_path schreiben
#  7) OpenUpgrade-Migration ausführen (--update all)
#  8) Optional: Odoo16 als systemd-Service einrichten
#
# WICHTIG:
#  - Vorher Variablen unten anpassen!
#  - Script NICHT aus /root/script ausführen (sonst sudo-postgres Warnungen).
#    Empfohlen: aus /tmp oder /home/<user> ausführen.
#  - Re-Run möglich: bestehendes Backup wiederverwenden mit
#      sudo SKIP_BACKUP=1 BACKUP_DIR=/var/backups/odoo-migration-... bash <script>
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# KONFIGURATION – BITTE ANPASSEN
# ─────────────────────────────────────────────────────────────────────────────
ODOO_USER=""
ODOO_DB=""                       # Name der zu migrierenden Datenbank
ODOO_DB_NEW="${ODOO_DB}_v16"           # Zieldatenbank (wird automatisch erstellt)
DB_HOST="localhost"
DB_PORT="5432"
DB_USER=""                       # PostgreSQL-User mit Rechten auf der DB
DB_PASSWORD=""                         # leer lassen, wenn peer-auth (Unix-Socket) genutzt wird

# Pfade
ODOO15_FILESTORE="/opt/odoo15/.local/share/Odoo/filestore/odoo15"
ODOO16_BASE="/opt/odoo16"
ODOO16_SRC="${ODOO16_BASE}/odoo"                # Odoo 16 Core (odoo/odoo @16.0)
ODOO16_OPENUPGRADE="${ODOO16_BASE}/OpenUpgrade" # OCA OpenUpgrade @16.0
ODOO16_VENV="${ODOO16_BASE}/venv"
ODOO16_CUSTOM="${ODOO16_BASE}/custom-addons"    # Eigene/portierte Module hier ablegen
ODOO16_CONF="/etc/odoo16.conf"
ODOO16_LOG="/var/log/odoo/odoo16-migrate.log"

# Erwartete Git-Remote-URLs (zur Validierung bestehender Clones)
ODOO16_SRC_REMOTE="https://github.com/odoo/odoo.git"
ODOO16_OPENUPGRADE_REMOTE="https://github.com/OCA/OpenUpgrade.git"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/odoo-migration-$(date +%F_%H%M)}"

# Falls du ein bestehendes Backup wiederverwenden willst, setze SKIP_BACKUP=1
# und BACKUP_DIR="<pfad zum bestehenden backup>"
SKIP_BACKUP="${SKIP_BACKUP:-0}"

# Odoo 15 Service-Name (zum Stoppen)
ODOO15_SERVICE="odoo15"

# ─────────────────────────────────────────────────────────────────────────────
# Hilfsfunktionen
# ──────────────────────────────────────────────────────────���──────────────────
log()  { echo -e "\e[1;32m[$(date +%H:%M:%S)]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || err "Bitte als root oder mit sudo ausführen."
}

confirm() {
  read -r -p "$1 [y/N] " ans
  [[ "${ans,,}" == "y" ]] || err "Abgebrochen durch User."
}

# Verhindere postgres-cwd-Warnung: in ein Verzeichnis wechseln, das jeder lesen darf
safe_cwd() {
  cd /tmp
}

# Klont (oder aktualisiert) ein Repo. Prüft die Remote-URL und wirft das
# Verzeichnis weg, falls dort ein anderes Repo liegt.
#   $1 = Zielverzeichnis
#   $2 = erwartete Remote-URL
#   $3 = Branch
clone_or_update() {
  local dir="$1" remote="$2" branch="$3"

  if [[ -d "${dir}/.git" ]]; then
    local current_remote
    current_remote=$(git -C "${dir}" config --get remote.origin.url || echo "")
    if [[ "${current_remote}" != "${remote}" ]]; then
      warn "${dir} enthält ein anderes Repo (${current_remote}) – wird gelöscht und neu geklont."
      rm -rf "${dir}"
    else
      log "Aktualisiere ${dir} (Branch ${branch})..."
      git -C "${dir}" fetch --depth=1 origin "${branch}"
      git -C "${dir}" reset --hard "origin/${branch}"
      return 0
    fi
  fi

  log "Klone ${remote} (Branch ${branch}) -> ${dir}"
  rm -rf "${dir}"
  git clone --depth=1 -b "${branch}" "${remote}" "${dir}"
}

# Prüft, ob die DB-Verbindung als ODOO_USER funktioniert.
# Bei leerem Passwort wird über Unix-Socket (peer-auth) verbunden.
check_db_connection() {
  log "Prüfe PostgreSQL-Verbindung als '${ODOO_USER}'..."
  if [[ -z "${DB_PASSWORD}" ]]; then
    if sudo -u "${ODOO_USER}" psql -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
      log "  ✓ Peer-auth funktioniert (Unix-Socket, kein Passwort)."
      return 0
    fi
    warn "Peer-auth fehlgeschlagen für User '${ODOO_USER}'."
    warn "Optionen:"
    warn "  a) PostgreSQL-User anlegen/anpassen:"
    warn "       sudo -u postgres createuser -s ${ODOO_USER}"
    warn "  b) Passwort setzen + DB_PASSWORD im Script eintragen:"
    warn "       sudo -u postgres psql -c \"ALTER USER ${ODOO_USER} WITH PASSWORD 'GeheimesPasswort';\""
    err  "DB-Verbindung nicht möglich – Abbruch."
  else
    if PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
      log "  ✓ TCP-Verbindung mit Passwort funktioniert."
      return 0
    fi
    err "TCP-Verbindung zu ${DB_HOST}:${DB_PORT} als ${DB_USER} schlug fehl. Passwort/Host prüfen!"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 1) Voraussetzungen
# ─────────────────────────────────────────────────────────────────────────────
step_prereqs() {
  log "Schritt 1/8: System-Pakete installieren..."
  apt-get update -y
  apt-get install -y \
    git build-essential wget curl \
    python3 python3-pip python3-dev python3-venv python3-wheel \
    libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libtiff5-dev libjpeg-dev libopenjp2-7-dev zlib1g-dev \
    libfreetype6-dev liblcms2-dev libwebp-dev libharfbuzz-dev \
    libfribidi-dev libxcb1-dev libpq-dev \
    node-less npm postgresql-client \
    fontconfig libfontconfig1 xfonts-75dpi xfonts-base

  # wkhtmltopdf 0.12.6 (für korrekte PDF-Erzeugung in Odoo 16)
  if ! command -v wkhtmltopdf >/dev/null 2>&1; then
    log "Installiere wkhtmltopdf 0.12.6..."
    local deb="/tmp/wkhtmltox.deb"
    wget -qO "$deb" \
      "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb" \
      || wget -qO "$deb" \
      "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.focal_amd64.deb"
    apt-get install -y "$deb" || apt-get -f install -y
    rm -f "$deb"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 2) Backup
# ─────────────────────────────────────────────────────────────────────────────
step_backup() {
  if [[ "$SKIP_BACKUP" == "1" ]]; then
    log "Schritt 2/8: Backup übersprungen (SKIP_BACKUP=1). Nutze: ${BACKUP_DIR}"
    [[ -f "${BACKUP_DIR}/${ODOO_DB}.dump" ]] || err "Backup-Datei nicht gefunden: ${BACKUP_DIR}/${ODOO_DB}.dump"
    return 0
  fi

  log "Schritt 2/8: Backup von DB und Filestore nach ${BACKUP_DIR}..."
  mkdir -p "${BACKUP_DIR}"

  log "Stoppe Odoo 15 (Service: ${ODOO15_SERVICE})..."
  systemctl stop "${ODOO15_SERVICE}" || warn "Konnte Service nicht stoppen (evtl. nicht vorhanden)."

  log "Dump der Datenbank ${ODOO_DB}..."
  safe_cwd
  sudo -u postgres pg_dump -Fc "${ODOO_DB}" > "${BACKUP_DIR}/${ODOO_DB}.dump"

  if [[ -d "${ODOO15_FILESTORE}" ]]; then
    log "Sichere Filestore..."
    cp -a "${ODOO15_FILESTORE}" "${BACKUP_DIR}/filestore_${ODOO_DB}"
  else
    warn "Filestore-Pfad ${ODOO15_FILESTORE} nicht gefunden – bitte manuell prüfen!"
  fi

  log "Backup abgeschlossen: ${BACKUP_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3) Odoo 16 Core + OpenUpgrade klonen
# ─────────────────────────────────────────────────────────────────────────────
step_clone() {
  log "Schritt 3/8: Odoo 16 Core + OpenUpgrade (Branch 16.0) klonen..."
  mkdir -p "${ODOO16_BASE}" "${ODOO16_CUSTOM}"

  # Git-Sicherheitscheck (CVE-2022-24765) umgehen
  git config --global --add safe.directory "${ODOO16_SRC}" || true
  git config --global --add safe.directory "${ODOO16_OPENUPGRADE}" || true
  git config --global --add safe.directory '*' || true

  # a) Odoo 16 Core (enthält odoo-bin)
  clone_or_update "${ODOO16_SRC}"        "${ODOO16_SRC_REMOTE}"        "16.0"

  # b) OpenUpgrade (Module + Migrationsskripte)
  clone_or_update "${ODOO16_OPENUPGRADE}" "${ODOO16_OPENUPGRADE_REMOTE}" "16.0"

  # Sanity-Checks
  [[ -f "${ODOO16_SRC}/odoo-bin" ]] \
    || err "odoo-bin nicht gefunden unter ${ODOO16_SRC}/odoo-bin – Klon fehlgeschlagen!"
  [[ -d "${ODOO16_OPENUPGRADE}/openupgrade_framework" ]] \
    || err "openupgrade_framework fehlt in ${ODOO16_OPENUPGRADE} – Klon fehlgeschlagen!"
  [[ -d "${ODOO16_OPENUPGRADE}/openupgrade_scripts" ]] \
    || err "openupgrade_scripts fehlt in ${ODOO16_OPENUPGRADE} – Klon fehlgeschlagen!"

  chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO16_BASE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4) Python-venv für Odoo 16
# ─────────────────────────────────────────────────────────────────────────────
step_venv() {
  log "Schritt 4/8: Python-venv anlegen + Requirements installieren..."
  if [[ ! -d "${ODOO16_VENV}" ]]; then
    python3 -m venv "${ODOO16_VENV}"
  fi
  # shellcheck disable=SC1091
  source "${ODOO16_VENV}/bin/activate"
  pip install --upgrade pip wheel setuptools

  log "Installiere Odoo 16 Requirements..."
  pip install -r "${ODOO16_SRC}/requirements.txt"

  if [[ -f "${ODOO16_OPENUPGRADE}/requirements.txt" ]]; then
    log "Installiere OpenUpgrade Requirements..."
    pip install -r "${ODOO16_OPENUPGRADE}/requirements.txt" || true
  fi
  pip install openupgradelib

  deactivate
  chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO16_VENV}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5) Datenbank klonen + Filestore kopieren
# ─────────────────────────────────────────────────────────────────────────────
step_clone_db() {
  log "Schritt 5/8: Datenbank ${ODOO_DB} -> ${ODOO_DB_NEW} klonen..."
  safe_cwd

  if sudo -u postgres psql -lqt | cut -d '|' -f1 | grep -qw "${ODOO_DB_NEW}"; then
    warn "Datenbank ${ODOO_DB_NEW} existiert bereits."
    confirm "Soll sie GELÖSCHT und neu angelegt werden?"
    sudo -u postgres dropdb "${ODOO_DB_NEW}"
  fi
  sudo -u postgres createdb -O "${DB_USER}" "${ODOO_DB_NEW}"
  sudo -u postgres pg_restore -d "${ODOO_DB_NEW}" "${BACKUP_DIR}/${ODOO_DB}.dump"

  # Filestore für die neue DB anlegen
  local new_filestore="/var/lib/${ODOO_USER}/.local/share/Odoo/filestore/${ODOO_DB_NEW}"
  mkdir -p "$(dirname "$new_filestore")"
  if [[ -d "${BACKUP_DIR}/filestore_${ODOO_DB}" ]]; then
    if [[ -d "$new_filestore" ]]; then
      warn "Filestore-Ziel existiert schon: $new_filestore – wird überschrieben."
      rm -rf "$new_filestore"
    fi
    cp -a "${BACKUP_DIR}/filestore_${ODOO_DB}" "${new_filestore}"
    chown -R "${ODOO_USER}:${ODOO_USER}" "${new_filestore}"
  else
    warn "Kein Filestore-Backup unter ${BACKUP_DIR}/filestore_${ODOO_DB} – Anhänge fehlen!"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 6) Odoo16-Konfigurationsdatei erzeugen
# ─────────────────────────────────────────────────────────────────────────────
step_config() {
  log "Schritt 6/8: ${ODOO16_CONF} erzeugen..."
  mkdir -p "$(dirname "${ODOO16_LOG}")"
  touch "${ODOO16_LOG}"
  chown -R "${ODOO_USER}:${ODOO_USER}" "$(dirname "${ODOO16_LOG}")"

  # Datadir sicherstellen
  local data_dir="/var/lib/${ODOO_USER}/.local/share/Odoo"
  mkdir -p "${data_dir}"
  chown -R "${ODOO_USER}:${ODOO_USER}" "/var/lib/${ODOO_USER}"

  # DB-Verbindung: bei leerem Passwort -> Unix-Socket (peer-auth)
  local cfg_db_host cfg_db_port cfg_db_password
  if [[ -z "${DB_PASSWORD}" ]]; then
    log "  Kein DB_PASSWORD gesetzt -> Unix-Socket / peer-auth (db_host = False)."
    cfg_db_host="False"
    cfg_db_port="False"
    cfg_db_password="False"
  else
    cfg_db_host="${DB_HOST}"
    cfg_db_port="${DB_PORT}"
    cfg_db_password="${DB_PASSWORD}"
  fi

  # WICHTIG: addons_path muss das OpenUpgrade-Wurzelverzeichnis enthalten,
  # damit die Module 'openupgrade_framework' und 'openupgrade_scripts' gefunden werden.
  # upgrade_path zeigt auf die Migrations-Skripte (Unterordner "scripts").
  cat > "${ODOO16_CONF}" <<EOF
[options]
admin_passwd = CHANGE_ME_STRONG_PASSWORD
db_host = ${cfg_db_host}
db_port = ${cfg_db_port}
db_user = ${DB_USER}
db_password = ${cfg_db_password}
addons_path = ${ODOO16_SRC}/addons,${ODOO16_SRC}/odoo/addons,${ODOO16_OPENUPGRADE},${ODOO16_CUSTOM}
upgrade_path = ${ODOO16_OPENUPGRADE}/openupgrade_scripts/scripts
data_dir = ${data_dir}
logfile = ${ODOO16_LOG}
log_level = info
http_port = 8069
proxy_mode = True
without_demo = all
server_wide_modules = base,web,openupgrade_framework
EOF
  chown "${ODOO_USER}:${ODOO_USER}" "${ODOO16_CONF}"
  chmod 640 "${ODOO16_CONF}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7) Migration ausführen
# ─────────────────────────────────────────────────────────────────────────────
step_migrate() {
  log "Schritt 7/8: OpenUpgrade-Migration auf ${ODOO_DB_NEW} starten..."
  log "Dies kann je nach Datenbankgröße SEHR lange dauern (Stunden möglich)."
  log "Output erscheint LIVE im Terminal UND wird nach ${ODOO16_LOG} geschrieben."
  confirm "Migration jetzt starten?"

  # Sicherheitsnetz, falls Step 3 übersprungen wurde
  [[ -f "${ODOO16_SRC}/odoo-bin" ]] || err "odoo-bin fehlt unter ${ODOO16_SRC} – bitte step_clone erneut laufen lassen."
  [[ -d "${ODOO16_OPENUPGRADE}/openupgrade_framework" ]] || err "openupgrade_framework-Modul fehlt – bitte step_clone erneut laufen lassen."

  safe_cwd

  # Logfile leeren, damit man die aktuelle Migration sauber sehen kann
  : > "${ODOO16_LOG}"
  chown "${ODOO_USER}:${ODOO_USER}" "${ODOO16_LOG}"

  local rc=0
  # WICHTIG:
  #  - --logfile=/dev/stdout überschreibt logfile aus der Config -> wir sehen alles im Terminal
  #  - tee schreibt parallel in die Logdatei
  #  - PIPESTATUS[0] = Exit-Code von odoo-bin (nicht von tee)
  set +e
  sudo -u "${ODOO_USER}" bash -c "
    source '${ODOO16_VENV}/bin/activate'
    cd '${ODOO16_SRC}'
    python3 -u '${ODOO16_SRC}/odoo-bin' \
      -c '${ODOO16_CONF}' \
      -d '${ODOO_DB_NEW}' \
      --update all \
      --stop-after-init \
      --load=base,web,openupgrade_framework \
      --logfile=/dev/stdout 2>&1
  " | tee -a "${ODOO16_LOG}"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ ${rc} -ne 0 ]]; then
    err "Migration FEHLGESCHLAGEN (Exit-Code ${rc}). Siehe Output oben bzw. ${ODOO16_LOG}."
  fi

  log "Migration erfolgreich beendet. Logfile: ${ODOO16_LOG}"

  # Quick-Sanity: Version von 'base' nach der Migration
  local base_ver
  base_ver=$(sudo -u postgres psql -d "${ODOO_DB_NEW}" -tAc \
    "SELECT latest_version FROM ir_module_module WHERE name='base';" 2>/dev/null | xargs || true)
  if [[ -n "${base_ver}" ]]; then
    log "  Modul 'base' ist jetzt auf Version: ${base_ver}"
    if [[ "${base_ver}" != 16.* ]]; then
      warn "  Erwartet wurde 16.x – bitte Logfile genau prüfen!"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 8) Optional: systemd-Service
# ─────────────────────────────────────────────────────────────────────────────
step_systemd() {
  log "Schritt 8/8: systemd-Service odoo16.service anlegen..."
  cat > /etc/systemd/system/odoo16.service <<EOF
[Unit]
Description=Odoo 16
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo16
PermissionsStartOnly=true
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO16_VENV}/bin/python3 ${ODOO16_SRC}/odoo-bin -c ${ODOO16_CONF}
StandardOutput=journal+console
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable odoo16.service
  log "Service registriert. Start mit: systemctl start odoo16"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
  require_root
  safe_cwd
  log "=== Odoo 15 -> 16 Migration startet ==="
  log "Quell-DB:   ${ODOO_DB}"
  log "Ziel-DB:    ${ODOO_DB_NEW}"
  log "Backup-Dir: ${BACKUP_DIR}  (SKIP_BACKUP=${SKIP_BACKUP})"
  if [[ -z "${DB_PASSWORD}" ]]; then
    log "DB-Auth:    peer (Unix-Socket, ohne Passwort)"
  else
    log "DB-Auth:    TCP ${DB_HOST}:${DB_PORT} mit Passwort"
  fi
  confirm "Bist du dir sicher, dass du fortfahren willst?"

  step_prereqs
  check_db_connection
  step_backup
  step_clone
  step_venv
  step_clone_db
  step_config
  step_migrate
  step_systemd

  log "=== FERTIG ==="
  log "Nächste Schritte:"
  log " 1) Logfile prüfen:        less ${ODOO16_LOG}"
  log " 2) Odoo 16 starten:       systemctl start odoo16"
  log " 3) Im Browser testen:     http://<server>:8069 (DB: ${ODOO_DB_NEW})"
  log " 4) Custom-Module portieren und in ${ODOO16_CUSTOM} ablegen, dann:"
  log "    sudo -u ${ODOO_USER} ${ODOO16_VENV}/bin/python3 ${ODOO16_SRC}/odoo-bin -c ${ODOO16_CONF} -d ${ODOO_DB_NEW} -u <modul> --stop-after-init"
}

main "$@"
