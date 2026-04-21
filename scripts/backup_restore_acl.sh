#!/usr/bin/env bash
set -euo pipefail

# scripts/backup_restore_acl.sh
# Backup/Restore de ACLs POSIX.
#
# Uso:
#   sudo ./scripts/backup_restore_acl.sh backup  /srv/samba/02_Proyectos
#   sudo ./scripts/backup_restore_acl.sh backup  /srv/samba/02_Proyectos /ruta/custom.facl
#   sudo ./scripts/backup_restore_acl.sh restore backups/acl_before_YYYYMMDD_HHMMSS.facl
#
# Variables:
#   FORCE=1   -> omite confirmación en restore.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${REPO_DIR}/backups"
LOG_DIR="${REPO_DIR}/logs"
mkdir -p "${BACKUP_DIR}" "${LOG_DIR}"
chmod 750 "${BACKUP_DIR}" "${LOG_DIR}" || true

cmd="${1:-}"
arg1="${2:-}"
arg2="${3:-}"

FORCE="${FORCE:-0}"

ts() { date -Is; }
log() { printf "[%s] %s\n" "$(ts)" "$*" | tee -a "${LOG_DIR}/backup_restore_acl.log" >/dev/null; }
die() { log "[ERROR] $*"; exit 1; }

case "${cmd}" in
  backup)
    target="${arg1:-}"
    file="${arg2:-}"

    [[ -n "${target}" ]] || die "Uso: $0 backup <ruta_objetivo> [archivo_salida.facl]"

    [[ -d "${target}" ]] || die "Ruta objetivo no existe: ${target}"

    # Si no te pasan archivo, usa nombre fijo (siempre sobreescribe el anterior)
    if [[ -z "${file}" ]]; then
      file="${BACKUP_DIR}/acl_latest.facl"
    fi

    # Seguridad básica del archivo resultante
    umask 077

    log "[BACKUP] Exportando ACLs de: ${target}"
    log "[BACKUP] Archivo: ${file}"
    getfacl -R --absolute-names "${target}" > "${file}"
    log "[OK] Backup generado: ${file}"
    ;;

  restore)
    file="${arg1:-}"
    [[ -n "${file}" ]] || die "Uso: $0 restore <archivo_entrada.facl>"

    [[ -f "${file}" ]] || die "Archivo .facl no existe: ${file}"

    log "[RESTORE] Restaurando ACLs desde: ${file}"
    log "[WARN] Esto sobrescribirá ACLs de las rutas contenidas en el archivo."

    if [[ "${FORCE}" != "1" ]]; then
      read -r -p "Escribe 'yes' para continuar: " confirm
      if [[ "${confirm}" != "yes" ]]; then
        log "[ABORT] Restore cancelado."
        exit 0
      fi
    fi

    setfacl --restore="${file}"
    log "[OK] Restore completado."
    ;;

  *)
    echo "Uso:"
    echo "  $0 backup  <ruta_objetivo> [archivo_salida.facl]"
    echo "  $0 restore <archivo_entrada.facl>"
    echo ""
    echo "Opcional: FORCE=1 para omitir confirmación en restore."
    exit 1
    ;;
esac
