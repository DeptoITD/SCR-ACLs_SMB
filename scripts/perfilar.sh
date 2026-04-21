#!/usr/bin/env bash
set -euo pipefail

# perfilar.sh — Punto de entrada para perfilación de proyectos Samba.
#
# Uso: sudo bash scripts/perfilar.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts"
INI_FILE="${INI_FILE:-${REPO_DIR}/config/acls.ini}"

LOG_DIR="${REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/perfilar.log"
mkdir -p "${LOG_DIR}"

WIP_FOLDER="01_WIP"

# -------------------------
# Logging
# -------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }

log_info() { printf "[INFO]  %s ℹ️  %s\n" "$(ts)" "$*" | tee -a "${LOG_FILE}"; }
log_ok()   { printf "[OK]    %s ✅ %s\n" "$(ts)" "$*" | tee -a "${LOG_FILE}"; }
log_warn() { printf "[WARN]  %s ⚠️  %s\n" "$(ts)" "$*" | tee -a "${LOG_FILE}"; }
log_err()  { printf "[ERROR] %s ❌ %s\n" "$(ts)" "$*" | tee -a "${LOG_FILE}"; }

die() { log_err "$*"; exit 1; }

trap 'rc=$?; log_err "Abortado (exit=$rc) en línea ${LINENO}: ${BASH_COMMAND}"; exit $rc' ERR

# -------------------------
# Helpers
# -------------------------
trim() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

read_root_from_ini() {
  local root=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line
    line="$(trim "$raw")"
    [[ "$line" =~ ^root= ]] && root="${line#root=}" && break
  done < "${INI_FILE}"
  printf "%s" "$(trim "$root")"
}

# -------------------------
# Prerequisitos
# -------------------------
[[ -f "${INI_FILE}" ]]                               || die "INI no encontrado: ${INI_FILE}"
[[ -f "${SCRIPTS_DIR}/apply_acls.sh" ]]              || die "apply_acls.sh no encontrado"
[[ -f "${SCRIPTS_DIR}/apply_acls_nonstandard.sh" ]]  || die "apply_acls_nonstandard.sh no encontrado"
[[ -f "${SCRIPTS_DIR}/backup_restore_acl.sh" ]]      || die "backup_restore_acl.sh no encontrado"

ROOT="$(read_root_from_ini)"
[[ -n "${ROOT}" ]] || die "No se pudo leer GLOBAL.root del INI"
[[ -d "${ROOT}" ]]  || die "Directorio raíz no existe: ${ROOT}"

# -------------------------
# Listar proyectos
# -------------------------
mapfile -t ALL_PROJECTS < <(
  find -P "${ROOT}" -maxdepth 1 -mindepth 1 -type d | sort | xargs -I{} basename {}
)

[[ "${#ALL_PROJECTS[@]}" -gt 0 ]] || die "No hay proyectos en ${ROOT}"

printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Perfilación de proyectos Samba\n"
printf "  Raíz: %s\n" "${ROOT}"
printf "════════════════════════════════════════════════════\n\n"
printf "  Proyectos disponibles:\n\n"

for i in "${!ALL_PROJECTS[@]}"; do
  proj="${ALL_PROJECTS[$i]}"
  if [[ -d "${ROOT}/${proj}/${WIP_FOLDER}" ]]; then
    tag="estándar"
  else
    tag="no estándar"
  fi
  printf "    %3d)  %-30s  [%s]\n" $((i+1)) "$proj" "$tag"
done

printf "\n  Selecciona el número del proyecto a perfilar [1-%d]: " "${#ALL_PROJECTS[@]}"
read -r selection
selection="$(trim "$selection")"

# -------------------------
# Validar selección
# -------------------------
[[ "$selection" =~ ^[0-9]+$ ]] || die "Entrada no válida: '$selection'"

idx=$((selection - 1))
[[ $idx -ge 0 && $idx -lt ${#ALL_PROJECTS[@]} ]] || \
  die "Número fuera de rango. Elige entre 1 y ${#ALL_PROJECTS[@]}."

PROJ_NAME="${ALL_PROJECTS[$idx]}"
PROJ_PATH="${ROOT}/${PROJ_NAME}"

# -------------------------
# Mostrar resumen antes de continuar
# -------------------------
printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Proyecto seleccionado\n"
printf "════════════════════════════════════════════════════\n\n"
printf "  Nombre:    %s\n" "$PROJ_NAME"
printf "  Ruta:      %s\n" "$PROJ_PATH"

if [[ -d "${PROJ_PATH}/${WIP_FOLDER}" ]]; then
  ESTRUCTURA="estándar"
  SCRIPT_A_CORRER="apply_acls.sh"
  DESCRIPCION="Aplica los permisos definidos en config/acls.ini"
else
  ESTRUCTURA="no estándar"
  SCRIPT_A_CORRER="apply_acls_nonstandard.sh"
  DESCRIPCION="Asistente interactivo nivel por nivel"
fi

printf "  Estructura: %s\n" "$ESTRUCTURA"
printf "  Script:     %s\n" "$SCRIPT_A_CORRER"
printf "  Acción:     %s\n" "$DESCRIPCION"
printf "\n"

printf "  ¿Continuar? [s/N]: "
read -r confirm
confirm="$(trim "$confirm")"
[[ "${confirm,,}" == "s" || "${confirm,,}" == "si" ]] || \
  { log_warn "Operación cancelada por el usuario."; exit 0; }

# -------------------------
# Backup obligatorio
# -------------------------
printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Backup de ACLs\n"
printf "════════════════════════════════════════════════════\n\n"

log_info "Generando backup antes de aplicar cambios..."
BACKUP_FILE=$(bash "${SCRIPTS_DIR}/backup_restore_acl.sh" backup "${ROOT}" 2>&1 | \
  grep -oP "(?<=Archivo: ).*\.facl" || true)
log_ok "Backup completado."

if [[ -n "${BACKUP_FILE}" ]]; then
  printf "\n  Si necesitas revertir los cambios ejecuta:\n"
  printf "  sudo bash scripts/backup_restore_acl.sh restore %s\n\n" "${BACKUP_FILE}"
fi

# -------------------------
# Ejecutar el script correspondiente
# -------------------------
printf "════════════════════════════════════════════════════\n"
printf "  Ejecutando: %s\n" "$SCRIPT_A_CORRER"
printf "════════════════════════════════════════════════════\n\n"

if [[ "$ESTRUCTURA" == "estándar" ]]; then
  TARGET_PROJECT="${PROJ_NAME}" bash "${SCRIPTS_DIR}/apply_acls.sh"
else
  bash "${SCRIPTS_DIR}/apply_acls_nonstandard.sh" "${PROJ_PATH}"
fi

printf "\n"
log_ok "Perfilación completada: ${PROJ_NAME}"
log_ok "Log: ${LOG_FILE}"
