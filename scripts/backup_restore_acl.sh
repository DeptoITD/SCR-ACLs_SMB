#!/usr/bin/env bash
set -euo pipefail

# scripts/backup_restore_acl.sh
# Backup/Restore de ACLs POSIX.
#
# Uso:
#   sudo ./scripts/backup_restore_acl.sh backup /srv/samba/02_Proyectos /root/acl_before.facl
#   sudo ./scripts/backup_restore_acl.sh restore / /root/acl_before.facl
#
# Notas:
# - Backup usa getfacl -R --absolute-names para rutas absolutas.
# - Restore usa setfacl --restore (requiere las mismas rutas/usuarios/grupos).

cmd="${1:-}"
target="${2:-}"
file="${3:-}"

if [[ -z "${cmd}" || -z "${target}" || -z "${file}" ]]; then
  echo "Uso:"
  echo "  $0 backup  <ruta_objetivo> <archivo_salida.facl>"
  echo "  $0 restore <ruta_base>     <archivo_entrada.facl>"
  exit 1
fi

case "${cmd}" in
  backup)
    if [[ ! -d "${target}" ]]; then
      echo "[ERROR] Ruta objetivo no existe: ${target}"
      exit 2
    fi
    echo "[BACKUP] Exportando ACLs de: ${target}"
    getfacl -R --absolute-names "${target}" > "${file}"
    echo "[OK] Backup generado: ${file}"
    ;;
  restore)
    if [[ ! -f "${file}" ]]; then
      echo "[ERROR] Archivo .facl no existe: ${file}"
      exit 2
    fi
    echo "[RESTORE] Restaurando ACLs desde: ${file}"
    setfacl --restore="${file}"
    echo "[OK] Restore completado."
    ;;
  *)
    echo "[ERROR] Comando inválido: ${cmd}"
    echo "Comandos válidos: backup | restore"
    exit 1
    ;;
esac
