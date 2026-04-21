#!/usr/bin/env bash
set -euo pipefail

# apply_acls_nonstandard.sh — Perfilación interactiva nivel por nivel
# para proyectos sin estructura estándar (sin 01_WIP en el primer nivel).
#
# Uso: bash scripts/apply_acls_nonstandard.sh <ruta_absoluta_del_proyecto>
#
# Flujo:
#   1. Navega el árbol del proyecto nivel por nivel hasta que el usuario
#      identifica la carpeta que actúa como WIP
#   2. Lista las subcarpetas del WIP (especialidades)
#   3. Para cada subcarpeta, pregunta el permiso por cada grupo
#   4. Muestra un DRY-RUN con los setfacl generados
#   5. Pide confirmación y aplica

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INI_FILE="${INI_FILE:-${REPO_DIR}/config/acls.ini}"

LOG_DIR="${REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/apply_acls_nonstandard.log"
mkdir -p "${LOG_DIR}"

DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

# -------------------------
# Argumento obligatorio
# -------------------------
PROJ_PATH="${1:-}"
[[ -n "${PROJ_PATH}" ]] || { printf "Uso: %s <ruta_proyecto>\n" "$0"; exit 1; }
[[ -d "${PROJ_PATH}" ]] || { printf "La ruta no existe: %s\n" "${PROJ_PATH}"; exit 1; }
PROJ_NAME="$(basename "${PROJ_PATH}")"

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

run_cmd() {
  printf "  🧾 %s\n" "$*" | tee -a "${LOG_FILE}"
  [[ "${DRY_RUN}" == "1" ]] && return 0
  "$@"
}

normalize_perms() {
  local p="$1"
  case "$p" in
    rwx|r-x|rw-|r--|--x|---|"-wx") printf "%s" "$p"; return 0 ;;
  esac
  local r="-" w="-" x="-"
  [[ "$p" == *"r"* ]] && r="r"
  [[ "$p" == *"w"* ]] && w="w"
  [[ "$p" == *"x"* ]] && x="x"
  printf "%s" "${r}${w}${x}"
}

resolve_acl_subject() {
  local raw="$1"
  [[ "$raw" =~ ^[ug]: ]] && { printf "%s" "$raw"; return 0; }
  getent group  "$raw" >/dev/null 2>&1 && { printf "g:%s" "$raw"; return 0; }
  getent passwd "$raw" >/dev/null 2>&1 && { printf "u:%s" "$raw"; return 0; }
  printf "u:%s" "$raw"
}

# -------------------------
# Leer perfiles del INI
# -------------------------
declare -a PROFILES=()

read_profiles_from_ini() {
  [[ -f "${INI_FILE}" ]] || die "INI no existe: ${INI_FILE}"
  local section=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line
    line="$(trim "$raw")"
    [[ -z "$line" ]]     && continue
    [[ "$line" =~ ^\; ]] && continue
    [[ "$line" =~ ^# ]]  && continue

    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="$(trim "${BASH_REMATCH[1]}")"
      continue
    fi

    # Ignorar GLOBAL y SPECIALTIES; todo lo demás es un perfil
    if [[ "$section" != "GLOBAL" && "$section" != "SPECIALTIES" && -n "$section" ]]; then
      local found=0
      for p in "${PROFILES[@]:-}"; do [[ "$p" == "$section" ]] && found=1 && break; done
      [[ $found -eq 0 ]] && PROFILES+=("$section")
    fi
  done < "${INI_FILE}"
}

read_profiles_from_ini
[[ "${#PROFILES[@]}" -gt 0 ]] || die "No se encontraron perfiles en el INI"

# -------------------------
# Navegación nivel por nivel
# -------------------------
navigate_to_wip() {
  local current="$1"
  local rel_path=""

  while true; do
    # Listar subdirectorios
    local -a subdirs=()
    mapfile -t subdirs < <(
      find -P "$current" -maxdepth 1 -mindepth 1 -type d | sort
    )

    printf "\n"
    if [[ -n "$rel_path" ]]; then
      printf "  📂 Ubicación actual: %s/%s\n\n" "$PROJ_NAME" "$rel_path"
    else
      printf "  📂 Raíz del proyecto: %s\n\n" "$PROJ_NAME"
    fi

    if [[ "${#subdirs[@]}" -eq 0 ]]; then
      printf "  (Sin subcarpetas — esta carpeta se usará como WIP)\n"
      WIP_ABS="$current"
      WIP_REL="$rel_path"
      return 0
    fi

    printf "  Subcarpetas encontradas:\n\n"
    for i in "${!subdirs[@]}"; do
      printf "    %3d) %s\n" $((i+1)) "$(basename "${subdirs[$i]}")"
    done

    printf "\n  Opciones:\n"
    printf "    0) Esta carpeta ES el WIP (seleccionar la ubicación actual)\n"
    printf "    [número] Entrar en esa subcarpeta\n"
    printf "\n  Selección: "

    local choice
    read -r choice < /dev/tty
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      WIP_ABS="$current"
      WIP_REL="$rel_path"
      return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      local idx=$((choice - 1))
      if [[ $idx -ge 0 && $idx -lt ${#subdirs[@]} ]]; then
        local selected="${subdirs[$idx]}"
        local name
        name="$(basename "$selected")"
        rel_path="${rel_path:+${rel_path}/}${name}"
        current="$selected"
      else
        printf "  Número fuera de rango. Intenta de nuevo.\n"
      fi
    else
      printf "  Entrada no válida. Ingresa un número o 0.\n"
    fi
  done
}

# -------------------------
# Pedir permisos por grupo para cada subcarpeta del WIP
# -------------------------
# Almacena: ACL_CMDS — array de strings "subject:perms:path"
declare -a ACL_CMDS=()

collect_permissions() {
  local wip_path="$1"

  local -a specialties=()
  mapfile -t specialties < <(
    find -P "$wip_path" -maxdepth 1 -mindepth 1 -type d | sort
  )

  if [[ "${#specialties[@]}" -eq 0 ]]; then
    log_warn "El WIP no tiene subcarpetas. No hay especialidades que perfilar."
    return 0
  fi

  printf "\n  WIP identificado: %s\n" "$wip_path"
  printf "  Especialidades encontradas: %d\n\n" "${#specialties[@]}"

  printf "  Permisos disponibles:\n"
  printf "    rwx = lectura + escritura + ejecución (control total)\n"
  printf "    r-x = solo lectura (ver y entrar)\n"
  printf "    --- = sin acceso (ocultar)\n"
  printf "    omitir = no modificar este permiso\n\n"

  for sp_path in "${specialties[@]}"; do
    local sp_name
    sp_name="$(basename "$sp_path")"

    printf "  ┌─────────────────────────────────────────────┐\n"
    printf "  │  Carpeta: %-33s │\n" "$sp_name"
    printf "  └─────────────────────────────────────────────┘\n"

    for profile in "${PROFILES[@]}"; do
      printf "    %-25s [rwx / r-x / --- / omitir]: " "$profile"
      local perm_input
      read -r perm_input < /dev/tty
      perm_input="$(trim "$perm_input")"

      [[ -z "$perm_input" || "${perm_input,,}" == "omitir" || "${perm_input,,}" == "o" ]] && continue

      local perms
      perms="$(normalize_perms "$perm_input")"
      local subject
      subject="$(resolve_acl_subject "$profile")"

      ACL_CMDS+=("${subject}|${perms}|${sp_path}")
    done
    printf "\n"
  done

  # Permiso base: listar WIP (r-x para todos los perfiles)
  for profile in "${PROFILES[@]}"; do
    local subject
    subject="$(resolve_acl_subject "$profile")"
    ACL_CMDS=("${subject}|r-x|${wip_path}" "${ACL_CMDS[@]}")
  done
}

# -------------------------
# Aplicar comandos
# -------------------------
apply_acl_cmds() {
  for entry in "${ACL_CMDS[@]}"; do
    IFS='|' read -r subject perms path <<< "$entry"
    local kind="${subject%%:*}" name="${subject#*:}"

    if [[ -d "$path" ]]; then
      run_cmd setfacl -m "${kind}:${name}:${perms}" "$path"
      run_cmd setfacl -d -m "${kind}:${name}:${perms}" "$path"
      # Recursivo en especialidades (no en el WIP mismo)
      if [[ "$path" != "${WIP_ABS}" ]]; then
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 find '%s' -type f -exec setfacl -m %s:%s:%s {} +\n" \
            "$path" "$kind" "$name" "$perms" | tee -a "${LOG_FILE}"
        else
          find -P "$path" -xdev -type f -exec setfacl -m "${kind}:${name}:${perms}" {} +
        fi
      fi
    fi
  done
}

# ========================
# MAIN
# ========================

printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Perfilación no estándar: %s\n" "$PROJ_NAME"
printf "════════════════════════════════════════════════════\n"

log_info "Iniciando perfilación no estándar para: ${PROJ_NAME}"

# Paso 1: navegación nivel por nivel
WIP_ABS=""
WIP_REL=""

printf "\n  Navega el árbol del proyecto para identificar la carpeta WIP.\n"
printf "  En cada nivel puedes entrar en una subcarpeta o confirmar\n"
printf "  que la ubicación actual ES el WIP (opción 0).\n"

navigate_to_wip "${PROJ_PATH}"

printf "\n  WIP seleccionado: %s\n" "${WIP_ABS}"
log_info "WIP identificado: ${WIP_ABS}"

# Paso 2: configurar permisos por grupo
printf "\n  Ahora configura los permisos de cada grupo sobre cada especialidad.\n"
collect_permissions "${WIP_ABS}"

# Paso 3: DRY-RUN
printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Vista previa — comandos que se ejecutarán:\n"
printf "════════════════════════════════════════════════════\n\n"

_ORIG_DRY_RUN="${DRY_RUN}"
DRY_RUN=1
apply_acl_cmds
DRY_RUN="${_ORIG_DRY_RUN}"

# Paso 4: confirmación y apply
printf "\n"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "DRY_RUN=1 — los cambios mostrados NO se aplicarán."
  exit 0
fi

if [[ "${FORCE}" != "1" ]]; then
  printf "  ¿Aplicar los cambios mostrados? [yes/no]: "
  local confirm
  read -r confirm < /dev/tty
  confirm="$(trim "$confirm")"
  if [[ "$confirm" != "yes" ]]; then
    log_warn "Aplicación cancelada por el usuario."
    exit 0
  fi
fi

log_info "Aplicando ACLs..."
apply_acl_cmds

log_ok "Perfilación no estándar completada: ${PROJ_NAME}"
log_ok "Log: ${LOG_FILE}"
