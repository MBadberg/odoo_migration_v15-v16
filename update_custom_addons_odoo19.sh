#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Odoo 19 - Custom Addons Sync + App-Listen-Aktualisierung
#
# Dieses Skript:
#  1) prüft /etc/odoo19.conf auf ein korrekt gesetztes custom-addons-Verzeichnis
#  2) synchronisiert bekannte Custom-Addons aus passenden Odoo-19-GitHub-Repositories
#  3) belässt unbekannte lokale Module zusätzlich im custom-addons-Verzeichnis
#  4) aktualisiert die App-Liste in der Ziel-Datenbank
#
# Ziel: Odoo 19-Umgebung unter /opt/odoo19 sauber mit Custom Addons befüllen.

ODOO_USER="${ODOO_USER:-odoo15}"
ODOO_CONF="${ODOO_CONF:-/etc/odoo19.conf}"
ODOO_BIN="${ODOO_BIN:-/opt/odoo19/odoo/odoo-bin}"
ODOO_VENV="${ODOO_VENV:-/opt/odoo19/venv}"
SRC_CUSTOM="${SRC_CUSTOM:-/opt/odoo15/odoo-custom-addons}"
DST_CUSTOM="${DST_CUSTOM:-/opt/odoo19/custom-addons}"
WORKDIR="${WORKDIR:-/tmp/odoo19-custom-addon-sync}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/odoo19-custom-addon-sync-$(date +%F_%H%M%S)}"
DB_NAME="${DB_NAME:-}"

THEMES_REPO="${THEMES_REPO:-https://github.com/odoo/design-themes.git}"
OCA_WEBSITE_REPO="${OCA_WEBSITE_REPO:-https://github.com/OCA/website.git}"
OCA_MAIL_REPO="${OCA_MAIL_REPO:-https://github.com/OCA/mail.git}"

THEMES_DIR="${WORKDIR}/design-themes"
OCA_WEBSITE_DIR="${WORKDIR}/oca-website"
OCA_MAIL_DIR="${WORKDIR}/oca-mail"

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

clone_or_update() {
  local dir="$1" remote="$2" branch="$3"

  if [[ -d "${dir}/.git" ]]; then
    local current_remote
    current_remote=$(git -C "${dir}" config --get remote.origin.url || echo "")
    if [[ "${current_remote}" == "${remote}" ]]; then
      log "Aktualisiere ${dir} (${branch})..."
      git -C "${dir}" fetch origin "${branch}" --depth=1
      git -C "${dir}" reset --hard "origin/${branch}"
      return 0
    fi
    rm -rf "${dir}"
  fi

  log "Klone ${remote} (${branch})..."
  rm -rf "${dir}"
  git clone --depth=1 -b "${branch}" "${remote}" "${dir}"
}

copy_module() {
  local src="$1" dst="$2"
  [[ -d "${src}" ]] || return 1
  rm -rf "${dst}"
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
}

module_exists() {
  local base="$1" module="$2"
  [[ -d "${base}/${module}" && -f "${base}/${module}/__manifest__.py" ]]
}

extract_addons_path() {
  awk -F'=' '
    /^[[:space:]]*addons_path[[:space:]]*=/ {
      $1="";
      sub(/^=/, "");
      gsub(/^[[:space:]]+|[[:space:]]+$/, "");
      print;
    }
  ' "${ODOO_CONF}" | tail -n 1
}

ensure_custom_addons_in_conf() {
  [[ -f "${ODOO_CONF}" ]] || err "Config nicht gefunden: ${ODOO_CONF}"

  local addons_line
  addons_line="$(extract_addons_path)"
  [[ -n "${addons_line}" ]] || err "addons_path in ${ODOO_CONF} nicht gefunden"

  if grep -Fq "${DST_CUSTOM}" <<<"${addons_line}"; then
    log "custom-addons ist bereits in addons_path eingetragen: ${DST_CUSTOM}"
    return 0
  fi

  warn "${DST_CUSTOM} fehlt in addons_path"
  confirm "Soll ${ODOO_CONF} automatisch angepasst werden?"

  cp "${ODOO_CONF}" "${BACKUP_DIR}/$(basename "${ODOO_CONF}").bak"

  python3 - <<PY
from pathlib import Path
conf = Path(${ODOO_CONF@Q})
text = conf.read_text()
lines = text.splitlines()
out = []
done = False
for line in lines:
    if line.lstrip().startswith('addons_path') and '=' in line and not done:
        left, right = line.split('=', 1)
        value = right.strip()
        parts = [p.strip() for p in value.split(',') if p.strip()]
        if ${DST_CUSTOM@Q} not in parts:
            parts.append(${DST_CUSTOM@Q})
        line = f"{left.strip()} = {','.join(parts)}"
        done = True
    out.append(line)
conf.write_text('\n'.join(out) + '\n')
PY

  log "addons_path wurde ergänzt."
}

sync_known_modules() {
  mkdir -p "${DST_CUSTOM}"

  clone_or_update "${THEMES_DIR}" "${THEMES_REPO}" "19.0"
  clone_or_update "${OCA_WEBSITE_DIR}" "${OCA_WEBSITE_REPO}" "19.0"
  clone_or_update "${OCA_MAIL_DIR}" "${OCA_MAIL_REPO}" "19.0"

  # design-themes
  if module_exists "${THEMES_DIR}" "theme_common"; then
    log "Übernehme theme_common aus odoo/design-themes (19.0)"
    copy_module "${THEMES_DIR}/theme_common" "${DST_CUSTOM}/theme_common"
  else
    warn "theme_common nicht in design-themes 19.0 gefunden"
  fi

  if module_exists "${THEMES_DIR}" "theme_kea"; then
    log "Übernehme theme_kea aus odoo/design-themes (19.0)"
    copy_module "${THEMES_DIR}/theme_kea" "${DST_CUSTOM}/theme_kea"
  else
    warn "theme_kea nicht in design-themes 19.0 gefunden"
  fi

  # OCA website
  if module_exists "${OCA_WEBSITE_DIR}" "website_odoo_debranding"; then
    log "Übernehme website_odoo_debranding aus OCA/website (19.0)"
    copy_module "${OCA_WEBSITE_DIR}/website_odoo_debranding" "${DST_CUSTOM}/website_odoo_debranding"
  else
    warn "website_odoo_debranding nicht in OCA/website 19.0 gefunden"
  fi

  # OCA mail
  if module_exists "${OCA_MAIL_DIR}" "mail_attach_existing_attachment"; then
    log "Übernehme mail_attach_existing_attachment aus OCA/mail (19.0)"
    copy_module "${OCA_MAIL_DIR}/mail_attach_existing_attachment" "${DST_CUSTOM}/mail_attach_existing_attachment"
  else
    warn "mail_attach_existing_attachment nicht in OCA/mail 19.0 gefunden"
  fi

  if module_exists "${OCA_MAIL_DIR}" "mail_debrand"; then
    log "Übernehme mail_debrand aus OCA/mail (19.0)"
    copy_module "${OCA_MAIL_DIR}/mail_debrand" "${DST_CUSTOM}/mail_debrand"
  else
    warn "mail_debrand nicht in OCA/mail 19.0 gefunden"
  fi
}

copy_remaining_local_modules() {
  [[ -d "${SRC_CUSTOM}" ]] || {
    warn "Quellverzeichnis nicht gefunden: ${SRC_CUSTOM}"
    return 0
  }

  while IFS= read -r manifest; do
    local module
    module="$(basename "$(dirname "${manifest}")")"
    if [[ -d "${DST_CUSTOM}/${module}" ]]; then
      log "Überspringe lokales Modul ${module}, da bereits aus Upstream synchronisiert"
      continue
    fi
    log "Übernehme lokales Modul: ${module}"
    copy_module "$(dirname "${manifest}")" "${DST_CUSTOM}/${module}"
  done < <(find "${SRC_CUSTOM}" -mindepth 2 -maxdepth 2 -name '__manifest__.py' | sort)
}

refresh_apps_list() {
  local db="${DB_NAME}"
  if [[ -z "${db}" ]]; then
    db=$(awk -F'=' '
      /^[[:space:]]*db_name[[:space:]]*=/ {
        $1="";
        sub(/^=/, "");
        gsub(/^[[:space:]]+|[[:space:]]+$/, "");
        print;
      }
    ' "${ODOO_CONF}" | tail -n 1)
  fi

  [[ -n "${db}" ]] || err "Keine Datenbank gefunden. Setze DB_NAME oder db_name in ${ODOO_CONF}."
  [[ -x "${ODOO_VENV}/bin/python3" ]] || err "Python im venv nicht gefunden: ${ODOO_VENV}/bin/python3"
  [[ -f "${ODOO_BIN}" ]] || err "odoo-bin nicht gefunden: ${ODOO_BIN}"

  log "Aktualisiere App-Liste in Datenbank ${db}..."
  sudo -u "${ODOO_USER}" "${ODOO_VENV}/bin/python3" "${ODOO_BIN}" \
    -c "${ODOO_CONF}" \
    -d "${db}" \
    --stop-after-init \
    --update=base
}

main() {
  require_root
  mkdir -p "${WORKDIR}" "${BACKUP_DIR}" "${DST_CUSTOM}"

  log "ODOO_CONF : ${ODOO_CONF}"
  log "SRC_CUSTOM: ${SRC_CUSTOM}"
  log "DST_CUSTOM: ${DST_CUSTOM}"
  log "BACKUP   : ${BACKUP_DIR}"

  confirm "Custom Addons für Odoo 19 synchronisieren und App-Liste aktualisieren?"

  ensure_custom_addons_in_conf
  sync_known_modules
  copy_remaining_local_modules

  chown -R "${ODOO_USER}:${ODOO_USER}" "${DST_CUSTOM}" || true

  refresh_apps_list

  log "Fertig."
  log "Custom Addons liegen unter: ${DST_CUSTOM}"
  log "Bitte danach in Odoo Apps ggf. Filter entfernen und 'Apps aktualisieren' prüfen."
}

main "$@"
