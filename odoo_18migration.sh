#!/usr/bin/env bash
###############################################################################
# Odoo 17 -> 18 Migration Script (Community Edition) mit OCA OpenUpgrade
#
# Ablauf:
#  1) Voraussetzungen installieren
#  2) PostgreSQL-Verbindung prüfen
#  3) Backup von DB + Filestore
#  4) Odoo 18 + OpenUpgrade 18.0 klonen
#  5) Python venv anlegen
#  6) DB-Klon "<dbname>_v18" erstellen
#  7) Odoo18-Konfiguration schreiben
#  8) OpenUpgrade-Migration ausführen
#  9) Optional: systemd-Service odoo18 anlegen
#
# Hinweise:
#  - OpenUpgrade für 14.0+ nutzt Odoo-Core + Module openupgrade_framework /
#    openupgrade_scripts im addons_path und scripts/ als upgrade_path.
#  - Immer zuerst auf Staging/Test ausführen.
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

# ──────────────────────────────────────────────────────────────────
# KONFIGURATION – ANPASSEN
# ──────────────────────────────────────────────────────────────────
ODOO_USER="odoo15"
ODOO17_DB="odoo15_v16_v17"
ODOO18_DB="${ODOO17_DB}_v18"

# Wenn DB_PASSWORD leer ist, nutzt das Script peer-auth / Unix socket.
DB_HOST="localhost"
DB_PORT="5432"
DB_USER="${ODOO_USER}"
DB_PASSWORD=""

ODOO17_SERVICE="odoo17"
ODOO17_FILESTORE="/var/lib/${ODOO_USER}/.local/share/Odoo/filestore/${ODOO17_DB}"

ODOO18_BASE="/opt/odoo18"
ODOO18_SRC="${ODOO18_BASE}/odoo"
ODOO18_OPENUPGRADE="${ODOO18_BASE}/OpenUpgrade"
ODOO18_VENV="${ODOO18_BASE}/venv"
ODOO18_CUSTOM="${ODOO18_BASE}/custom-addons"
ODOO18_CONF="/etc/odoo18.conf"
ODOO18_LOG="/var/log/odoo/odoo18-migrate.log"

ODOO18_SRC_REMOTE="https://github.com/odoo/odoo.git"
ODOO18_OPENUPGRADE_REMOTE="https://github.com/OCA/OpenUpgrade.git"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/odoo17-to-18-$(date +%F_%H%M)}"
SKIP_BACKUP="${SKIP_BACKUP:-0}"

# Optional: Ziel-Port für Odoo 18
ODOO18_HTTP_PORT="8071"

# Optional: Admin-Master-Passwort für Odoo 18
ODOO18_ADMIN_PASSWD="CHANGE_ME_STRONG_PASSWORD"

# ──────────────────────────────────────────────────────────────────
# Hilfsfunktionen
# ──────────────────────────────────────────────────────────────────
log()  { echo -e "\e[1;32m[$(date +%H:%M:%S)]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || err "Bitte als root oder mit sudo ausführen."
}

confirm() {
  read -r -p "$1 [y/N] " ans
  [[ "${ans,,}" == "y" ]] || err "Abgebrochen."
}

safe_cwd() {
  cd /tmp
}

clone_or_update() {
  local dir="$1" remote="$2" branch="$3"

  if [[ -d "${dir}/.git" ]]; then
    local current_remote
    current_remote=$(git -C "${dir}" config --get remote.origin.url || echo "")
    if [[ "${current_remote}" != "${remote}" ]]; then
      warn "${dir} enthält ein anderes Repo (${current_remote}) – lösche und klone neu."
      rm -rf "${dir}"
    else
      log "Aktualisiere ${dir} (${branch})..."
      git -C "${dir}" fetch --depth=1 origin "${branch}"
      git -C "${dir}" reset --hard "origin/${branch}"
      return 0
    fi
  fi

  log "Klone ${remote} (${branch}) nach ${dir}..."
  rm -rf "${dir}"
  git clone --depth=1 -b "${branch}" "${remote}" "${dir}"
}

check_db_connection() {
  log "Prüfe PostgreSQL-Verbindung..."

  if [[ -z "${DB_PASSWORD}" ]]; then
    if sudo -u "${ODOO_USER}" psql -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
      log "  ✓ Peer-auth funktioniert."
      return 0
    fi
    warn "Peer-auth fehlgeschlagen."
    warn "Optional Passwort setzen:"
    warn "  sudo -u postgres psql -c \"ALTER USER ${DB_USER} WITH PASSWORD 'GeheimesPasswort';\""
    err "Keine funktionierende DB-Verbindung."
  else
    if PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -tAc "SELECT 1;" >/dev/null 2>&1; then
      log "  ✓ TCP-Verbindung mit Passwort funktioniert."
      return 0
    fi
    err "TCP-Verbindung zu PostgreSQL fehlgeschlagen."
  fi
}

# ──────────────────────────────────────────────────────────────────
# 1) Voraussetzungen
# ──────────────────────────────────────────────────────────────────
step_prereqs() {
  log "Schritt 1/9: Installiere Voraussetzungen..."
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

  if ! command -v wkhtmltopdf >/dev/null 2>&1; then
    warn "wkhtmltopdf ist nicht installiert. Odoo 18 läuft grundsätzlich auch ohne PDF-Features sauber an,"
    warn "aber Reports können betroffen sein. Bei Bedarf später passend nachinstallieren."
  fi
}

# ──────────────────────────────────────────────────────────────────
# 2) Backup
# ──────────────────────────────────────────────────────────────────
step_backup() {
  if [[ "${SKIP_BACKUP}" == "1" ]]; then
    log "Schritt 2/9: Backup übersprungen (SKIP_BACKUP=1), nutze ${BACKUP_DIR}"
    [[ -f "${BACKUP_DIR}/${ODOO17_DB}.dump" ]] || err "Backup-Datei fehlt: ${BACKUP_DIR}/${ODOO17_DB}.dump"
    return 0
  fi

  log "Schritt 2/9: Erstelle Backup unter ${BACKUP_DIR}..."
  mkdir -p "${BACKUP_DIR}"

  log "Stoppe Odoo 17 (${ODOO17_SERVICE})..."
  systemctl stop "${ODOO17_SERVICE}" || warn "Konnte ${ODOO17_SERVICE} nicht stoppen."

  log "Dump der DB ${ODOO17_DB}..."
  safe_cwd
  sudo -u postgres pg_dump -Fc "${ODOO17_DB}" > "${BACKUP_DIR}/${ODOO17_DB}.dump"

  if [[ -d "${ODOO17_FILESTORE}" ]]; then
    log "Sichere Filestore..."
    cp -a "${ODOO17_FILESTORE}" "${BACKUP_DIR}/filestore_${ODOO17_DB}"
  else
    warn "Filestore nicht gefunden: ${ODOO17_FILESTORE}"
  fi

  log "Backup abgeschlossen."
}

# ──────────────────────────────────────────────────────────────────
# 3) Code klonen
# ──────────────────────────────────────────────────────────────────
step_clone() {
  log "Schritt 3/9: Klone Odoo 18 + OpenUpgrade 18.0..."
  mkdir -p "${ODOO18_BASE}" "${ODOO18_CUSTOM}"

  git config --global --add safe.directory "${ODOO18_SRC}" || true
  git config --global --add safe.directory "${ODOO18_OPENUPGRADE}" || true
  git config --global --add safe.directory '*' || true

  clone_or_update "${ODOO18_SRC}" "${ODOO18_SRC_REMOTE}" "18.0"
  clone_or_update "${ODOO18_OPENUPGRADE}" "${ODOO18_OPENUPGRADE_REMOTE}" "18.0"

  [[ -f "${ODOO18_SRC}/odoo-bin" ]] || err "odoo-bin fehlt unter ${ODOO18_SRC}"
  [[ -d "${ODOO18_OPENUPGRADE}/openupgrade_framework" ]] || err "openupgrade_framework fehlt"
  [[ -d "${ODOO18_OPENUPGRADE}/openupgrade_scripts" ]] || err "openupgrade_scripts fehlt"

  chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO18_BASE}"
}

# ──────────────────────────────────────────────────────────────────
# 4) Venv
# ──────────────────────────────────────────────────────────────────
step_venv() {
  log "Schritt 4/9: Erzeuge Python-venv..."
  if [[ ! -d "${ODOO18_VENV}" ]]; then
    python3 -m venv "${ODOO18_VENV}"
  fi

  # shellcheck disable=SC1091
  source "${ODOO18_VENV}/bin/activate"
  pip install --upgrade pip wheel setuptools

  log "Installiere Odoo 18 Requirements..."
  pip install -r "${ODOO18_SRC}/requirements.txt"

  if [[ -f "${ODOO18_OPENUPGRADE}/requirements.txt" ]]; then
    log "Installiere OpenUpgrade Requirements..."
    pip install -r "${ODOO18_OPENUPGRADE}/requirements.txt" || true
  fi

  log "Installiere aktuelle openupgradelib..."
  pip install "git+https://github.com/OCA/openupgradelib.git@master#egg=openupgradelib"

  deactivate
  chown -R "${ODOO_USER}:${ODOO_USER}" "${ODOO18_VENV}"
}

# ──────────────────────────────────────────────────────────────────
# 5) DB klonen
# ──────────────────────────────────────────────────────────────────
step_clone_db() {
  log "Schritt 5/9: Klone Datenbank ${ODOO17_DB} -> ${ODOO18_DB}..."
  safe_cwd

  if sudo -u postgres psql -lqt | cut -d '|' -f1 | grep -qw "${ODOO18_DB}"; then
    warn "Datenbank ${ODOO18_DB} existiert bereits."
    confirm "Soll sie gelöscht und neu erstellt werden?"
    sudo -u postgres dropdb "${ODOO18_DB}"
  fi

  sudo -u postgres createdb -O "${DB_USER}" "${ODOO18_DB}"
  sudo -u postgres pg_restore -d "${ODOO18_DB}" "${BACKUP_DIR}/${ODOO17_DB}.dump"

  local new_filestore="/var/lib/${ODOO_USER}/.local/share/Odoo/filestore/${ODOO18_DB}"
  mkdir -p "$(dirname "${new_filestore}")"

  if [[ -d "${BACKUP_DIR}/filestore_${ODOO17_DB}" ]]; then
    [[ -d "${new_filestore}" ]] && rm -rf "${new_filestore}"
    cp -a "${BACKUP_DIR}/filestore_${ODOO17_DB}" "${new_filestore}"
    chown -R "${ODOO_USER}:${ODOO_USER}" "${new_filestore}"
  else
    warn "Filestore-Backup fehlt."
  fi
}

# ──────────────────────────────────────────────────────────────────
# 6) Config schreiben
# ──────────────────────────────────────────────────────────────────
step_config() {
  log "Schritt 6/9: Schreibe ${ODOO18_CONF}..."
  mkdir -p "$(dirname "${ODOO18_LOG}")"
  touch "${ODOO18_LOG}"
  chown -R "${ODOO_USER}:${ODOO_USER}" "$(dirname "${ODOO18_LOG}")"

  local data_dir="/var/lib/${ODOO_USER}/.local/share/Odoo"
  mkdir -p "${data_dir}"
  chown -R "${ODOO_USER}:${ODOO_USER}" "/var/lib/${ODOO_USER}"

  local cfg_db_host cfg_db_port cfg_db_password
  if [[ -z "${DB_PASSWORD}" ]]; then
    cfg_db_host="False"
    cfg_db_port="False"
    cfg_db_password="False"
  else
    cfg_db_host="${DB_HOST}"
    cfg_db_port="${DB_PORT}"
    cfg_db_password="${DB_PASSWORD}"
  fi

  cat > "${ODOO18_CONF}" <<EOF
[options]
admin_passwd = ${ODOO18_ADMIN_PASSWD}
db_host = ${cfg_db_host}
db_port = ${cfg_db_port}
db_user = ${DB_USER}
db_password = ${cfg_db_password}
addons_path = ${ODOO18_SRC}/addons,${ODOO18_SRC}/odoo/addons,${ODOO18_OPENUPGRADE},${ODOO18_CUSTOM}
upgrade_path = ${ODOO18_OPENUPGRADE}/openupgrade_scripts/scripts
data_dir = ${data_dir}
logfile = ${ODOO18_LOG}
log_level = info
http_port = ${ODOO18_HTTP_PORT}
proxy_mode = True
without_demo = all
server_wide_modules = base,web,openupgrade_framework
EOF

  chown "${ODOO_USER}:${ODOO_USER}" "${ODOO18_CONF}"
  chmod 640 "${ODOO18_CONF}"
}

# ──────────────────────────────────────────────────────────────────
# 7) Migration
# ──────────────────────────────────────────────────────────────────
step_migrate() {
  log "Schritt 7/9: Starte OpenUpgrade-Migration auf ${ODOO18_DB}..."
  log "Output erscheint live im Terminal und in ${ODOO18_LOG}"
  confirm "Migration jetzt starten?"

  [[ -f "${ODOO18_SRC}/odoo-bin" ]] || err "odoo-bin fehlt"
  [[ -d "${ODOO18_OPENUPGRADE}/openupgrade_framework" ]] || err "openupgrade_framework fehlt"

  : > "${ODOO18_LOG}"
  chown "${ODOO_USER}:${ODOO_USER}" "${ODOO18_LOG}"

  local rc=0
  set +e
  sudo -u "${ODOO_USER}" bash -c "
    source '${ODOO18_VENV}/bin/activate'
    export OPENUPGRADE_TARGET_VERSION=18.0
    cd '${ODOO18_SRC}'
    python3 -u '${ODOO18_SRC}/odoo-bin' \
      -c '${ODOO18_CONF}' \
      -d '${ODOO18_DB}' \
      --update all \
      --stop-after-init \
      --load=base,web,openupgrade_framework \
      --logfile=/dev/stdout 2>&1
  " | tee -a "${ODOO18_LOG}"
  rc=${PIPESTATUS[0]}
  set -e

  [[ ${rc} -eq 0 ]] || err "Migration fehlgeschlagen (Exit-Code ${rc})."

  local base_ver
  base_ver=$(sudo -u postgres psql -d "${ODOO18_DB}" -tAc \
    "SELECT latest_version FROM ir_module_module WHERE name='base';" 2>/dev/null | xargs || true)
  if [[ -n "${base_ver}" ]]; then
    log "Modul 'base' nach Migration: ${base_ver}"
    [[ "${base_ver}" == 18.* ]] || warn "Erwartet war 18.x – bitte Log prüfen."
  fi
}

# ──────────────────────────────────────────────────────────────────
# 8) systemd
# ──────────────────────────────────────────────────────────────────
step_systemd() {
  log "Schritt 8/9: Erzeuge odoo18.service..."
  cat > /etc/systemd/system/odoo18.service <<EOF
[Unit]
Description=Odoo 18
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo18
PermissionsStartOnly=true
User=${ODOO_USER}
Group=${ODOO_USER}
ExecStart=${ODOO18_VENV}/bin/python3 ${ODOO18_SRC}/odoo-bin -c ${ODOO18_CONF}
StandardOutput=journal+console
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable odoo18.service
  log "odoo18.service wurde registriert."
}

# ──────────────────────────────────────────────────────────────────
# 9) Abschluss
# ──────────────────────────────────────────────────────────────────
step_finish() {
  log "Schritt 9/9: Fertig."
  log "Nächste Schritte:"
  log "  1) Log prüfen: less ${ODOO18_LOG}"
  log "  2) Odoo 18 starten: systemctl start odoo18"
  log "  3) Im Browser testen: http://<server>:${ODOO18_HTTP_PORT}"
  log "  4) Falls 500er / kaputte Website / skipped modules: Cleanup-Script nutzen"
  log "  5) Danach Custom-Module für 18.0 portieren und testen"
}

main() {
  require_root
  safe_cwd

  log "=== Odoo 17 -> 18 Migration startet ==="
  log "Quell-DB:   ${ODOO17_DB}"
  log "Ziel-DB:    ${ODOO18_DB}"
  log "Backup-Dir: ${BACKUP_DIR} (SKIP_BACKUP=${SKIP_BACKUP})"

  if [[ -z "${DB_PASSWORD}" ]]; then
    log "DB-Auth:    peer / Unix-Socket"
  else
    log "DB-Auth:    TCP ${DB_HOST}:${DB_PORT}"
  fi

  confirm "Fortfahren?"

  step_prereqs
  check_db_connection
  step_backup
  step_clone
  step_venv
  step_clone_db
  step_config
  step_migrate
  step_systemd
  step_finish
}

main "$@"
