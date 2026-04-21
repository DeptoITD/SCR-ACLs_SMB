#!/usr/bin/env bash
set -euo pipefail

# apply_acls_nonstandard.sh — Perfilación interactiva DFS
# para proyectos sin estructura estándar (sin 01_WIP en primer nivel).
#
# Uso: bash scripts/apply_acls_nonstandard.sh <ruta_absoluta_del_proyecto>
#
# Flujo:
#   1. Recorre el árbol del proyecto en profundidad (DFS)
#   2. En cada carpeta pregunta qué perfiles tienen permiso de edición
#   3. Los perfiles sin permiso reciben --- (ocultos vía Samba hide unreadable)
#   4. Pregunta si los mismos permisos aplican a todo lo de abajo (atajo recursivo)
#   5. Muestra DRY-RUN y aplica con confirmación

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
    local line; line="$(trim "$raw")"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^\; ]] && continue
    [[ "$line" =~ ^# ]]  && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="$(trim "${BASH_REMATCH[1]}")"
      continue
    fi
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
# Cola de comandos ACL
# Formato: "TIPO|subject|path"
#   WRITE_DIR — rwx en dir + default rwx + rw- en archivos directos del dir
#   DENY_DIR  — --- en dir + default --- + --- en archivos directos del dir
#   WRITE_REC — rwx recursivo en dirs + default rwx + rw- en archivos (todo el subárbol)
#   DENY_REC  — --- recursivo en dirs + default --- + --- en archivos (todo el subárbol)
# -------------------------
declare -a ACL_CMDS=()

# -------------------------
# Selección interactiva de perfiles
# Popula globales _WRITE_PROFILES y _DENY_PROFILES
# -------------------------
declare -a _WRITE_PROFILES=()
declare -a _READ_PROFILES=()
declare -a _DENY_PROFILES=()

# Parsea una respuesta de selección de perfiles y popula un array asociativo
# Uso: _parse_selection "$input" remaining_profiles_array result_assoc_array
_parse_selection() {
  local input="$1" arr_name="$2" result_name="$3"
  local -n _arr="$arr_name"
  local -n _result="$result_name"

  if [[ "${input,,}" == "todos" ]]; then
    for p in "${_arr[@]}"; do _result["$p"]=1; done
    return
  fi
  [[ "${input,,}" == "ninguno" || -z "$input" ]] && return

  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="$(trim "$part")"
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      local idx=$((part - 1))
      if [[ $idx -ge 0 && $idx -lt ${#_arr[@]} ]]; then
        _result["${_arr[$idx]}"]=1
      else
        printf "  [!] Número fuera de rango ignorado: %s\n" "$part"
      fi
    else
      printf "  [!] Entrada no válida ignorada: '%s'\n" "$part"
    fi
  done
}

select_profiles() {
  local rel="$1"
  _WRITE_PROFILES=()
  _READ_PROFILES=()
  _DENY_PROFILES=()

  printf "\n"
  printf "  ┌──────────────────────────────────────────────────────────────┐\n"
  printf "  │  📂 %-58s│\n" "$rel"
  printf "  └──────────────────────────────────────────────────────────────┘\n"
  printf "\n  Perfiles disponibles:\n"
  for i in "${!PROFILES[@]}"; do
    printf "    %3d) %s\n" $((i+1)) "${PROFILES[$i]}"
  done

  # --- Pregunta 1: ¿Quién EDITA aquí? ---
  printf "\n  ¿Quién puede EDITAR aquí? (crear y modificar documentos)\n"
  printf "  Ingresa números separados por coma, 'todos' o 'ninguno': "
  local input1
  read -r input1 < /dev/tty
  input1="$(trim "$input1")"

  local -A write_sel=()
  _parse_selection "$input1" PROFILES write_sel
  local -a remaining=()
  for p in "${PROFILES[@]}"; do
    if [[ "${write_sel[$p]+x}" ]]; then
      _WRITE_PROFILES+=("$p")
    else
      remaining+=("$p")
    fi
  done

  # Si todos editan o no queda nadie sin asignar, terminar
  if [[ "${#remaining[@]}" -eq 0 ]]; then
    return
  fi

  # --- Pregunta 2: de los restantes, ¿quién puede al menos VER/ENTRAR? ---
  printf "\n  De los restantes, ¿quién puede VER/ENTRAR (navegar, bajar más profundo)?\n"
  printf "  Perfiles aún sin asignar:\n"
  for i in "${!remaining[@]}"; do
    printf "    %3d) %s\n" $((i+1)) "${remaining[$i]}"
  done
  printf "  Ingresa números separados por coma, 'todos' o 'ninguno': "
  local input2
  read -r input2 < /dev/tty
  input2="$(trim "$input2")"

  local -A read_sel=()
  _parse_selection "$input2" remaining read_sel
  for p in "${remaining[@]}"; do
    if [[ "${read_sel[$p]+x}" ]]; then
      _READ_PROFILES+=("$p")
    else
      _DENY_PROFILES+=("$p")
    fi
  done
}

# -------------------------
# Recorrido DFS interactivo
# -------------------------
walk_tree() {
  local dir="$1" rel="$2"

  local -a subdirs=()
  mapfile -t subdirs < <(find -P "$dir" -maxdepth 1 -mindepth 1 -type d | sort)

  select_profiles "$rel"

  local -a wp=("${_WRITE_PROFILES[@]:-}")
  local -a rp=("${_READ_PROFILES[@]:-}")
  local -a dp=("${_DENY_PROFILES[@]:-}")

  # Mostrar resumen de la selección
  [[ ${#wp[@]} -gt 0 ]] && printf "  → Edición   (rwx): %s\n" "${wp[*]}"
  [[ ${#rp[@]} -gt 0 ]] && printf "  → Ver/entrar(r-x): %s\n" "${rp[*]}"
  [[ ${#dp[@]} -gt 0 ]] && printf "  → Oculto    (---): %s\n" "${dp[*]}"

  # Si hay subcarpetas, ofrecer atajo recursivo
  local apply_rec=0
  if [[ "${#subdirs[@]}" -gt 0 ]]; then
    printf "\n  Subcarpetas en este nivel:\n"
    for sd in "${subdirs[@]}"; do
      printf "    - %s\n" "$(basename "$sd")"
    done
    printf "\n  ¿Aplicar los MISMOS permisos a TODO lo que hay debajo? [s/n]: "
    local choice
    read -r choice < /dev/tty
    choice="$(trim "${choice,,}")"
    [[ "$choice" == "s" || "$choice" == "si" || "$choice" == "y" || "$choice" == "yes" ]] && apply_rec=1
  fi

  if [[ $apply_rec -eq 1 ]]; then
    # Recursivo: cubre dir actual + todo el subárbol
    for p in "${wp[@]:-}"; do
      ACL_CMDS+=("WRITE_REC|$(resolve_acl_subject "$p")|${dir}")
    done
    for p in "${rp[@]:-}"; do
      ACL_CMDS+=("READ_REC|$(resolve_acl_subject "$p")|${dir}")
    done
    for p in "${dp[@]:-}"; do
      ACL_CMDS+=("DENY_REC|$(resolve_acl_subject "$p")|${dir}")
    done
  else
    # No recursivo: solo dir actual + archivos directos; luego DFS en subdirs
    for p in "${wp[@]:-}"; do
      ACL_CMDS+=("WRITE_DIR|$(resolve_acl_subject "$p")|${dir}")
    done
    for p in "${rp[@]:-}"; do
      ACL_CMDS+=("READ_DIR|$(resolve_acl_subject "$p")|${dir}")
    done
    for p in "${dp[@]:-}"; do
      ACL_CMDS+=("DENY_DIR|$(resolve_acl_subject "$p")|${dir}")
    done
    for sd in "${subdirs[@]}"; do
      walk_tree "$sd" "${rel%/}/$(basename "$sd")"
    done
  fi
}

# -------------------------
# Aplicar la cola de comandos
# -------------------------
apply_acl_cmds() {
  if [[ "${#ACL_CMDS[@]}" -eq 0 ]]; then
    log_warn "No hay comandos ACL registrados."
    return
  fi

  for entry in "${ACL_CMDS[@]}"; do
    IFS='|' read -r type subject path <<< "$entry"
    local kind="${subject%%:*}" name="${subject#*:}"

    case "$type" in
      WRITE_DIR)
        printf "  # %s → rwx (dir + archivos directos)\n" "$path" | tee -a "${LOG_FILE}"
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 setfacl -m %s:%s:rwx '%s'\n"   "$kind" "$name" "$path" | tee -a "${LOG_FILE}"
          printf "  🧾 setfacl -d -m %s:%s:rwx '%s'\n" "$kind" "$name" "$path" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -maxdepth 1 -type f -exec setfacl -m %s:%s:rw- {} +\n" \
            "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
        else
          setfacl -m "${kind}:${name}:rwx" "$path"
          setfacl -d -m "${kind}:${name}:rwx" "$path"
          find -P "$path" -maxdepth 1 -type f -exec setfacl -m "${kind}:${name}:rw-" {} + 2>/dev/null || true
        fi
        ;;
      READ_DIR)
        printf "  # %s → r-x (dir, navegar; archivos directos r--)\n" "$path" | tee -a "${LOG_FILE}"
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 setfacl -m %s:%s:r-x '%s'\n"   "$kind" "$name" "$path" | tee -a "${LOG_FILE}"
          printf "  🧾 setfacl -d -m %s:%s:r-x '%s'\n" "$kind" "$name" "$path" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -maxdepth 1 -type f -exec setfacl -m %s:%s:r-- {} +\n" \
            "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
        else
          setfacl -m "${kind}:${name}:r-x" "$path"
          setfacl -d -m "${kind}:${name}:r-x" "$path"
          find -P "$path" -maxdepth 1 -type f -exec setfacl -m "${kind}:${name}:r--" {} + 2>/dev/null || true
        fi
        ;;
      DENY_DIR)
        printf "  # %s → --- (dir + archivos directos)\n" "$path" | tee -a "${LOG_FILE}"
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 setfacl -m %s:%s:--- '%s'\n"   "$kind" "$name" "$path" | tee -a "${LOG_FILE}"
          printf "  🧾 setfacl -d -m %s:%s:--- '%s'\n" "$kind" "$name" "$path" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -maxdepth 1 -type f -exec setfacl -m %s:%s:--- {} +\n" \
            "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
        else
          setfacl -m "${kind}:${name}:---" "$path"
          setfacl -d -m "${kind}:${name}:---" "$path"
          find -P "$path" -maxdepth 1 -type f -exec setfacl -m "${kind}:${name}:---" {} + 2>/dev/null || true
        fi
        ;;
      READ_REC)
        printf "  # %s → r-x recursivo (dirs) + r-- (archivos)\n" "$path" | tee -a "${LOG_FILE}"
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 find '%s' -xdev -type d -exec setfacl -m %s:%s:r-x {} +\n"   "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -xdev -type d -exec setfacl -d -m %s:%s:r-x {} +\n" "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -xdev -type f -exec setfacl -m %s:%s:r-- {} +\n"   "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
        else
          find -P "$path" -xdev -type d -exec setfacl -m "${kind}:${name}:r-x" {} +
          find -P "$path" -xdev -type d -exec setfacl -d -m "${kind}:${name}:r-x" {} +
          find -P "$path" -xdev -type f -exec setfacl -m "${kind}:${name}:r--" {} +
        fi
        ;;
      WRITE_REC)
        printf "  # %s → rwx recursivo (dirs) + rw- (archivos)\n" "$path" | tee -a "${LOG_FILE}"
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 find '%s' -xdev -type d -exec setfacl -m %s:%s:rwx {} +\n"   "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -xdev -type d -exec setfacl -d -m %s:%s:rwx {} +\n" "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -xdev -type f -exec setfacl -m %s:%s:rw- {} +\n"   "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
        else
          find -P "$path" -xdev -type d -exec setfacl -m "${kind}:${name}:rwx" {} +
          find -P "$path" -xdev -type d -exec setfacl -d -m "${kind}:${name}:rwx" {} +
          find -P "$path" -xdev -type f -exec setfacl -m "${kind}:${name}:rw-" {} +
        fi
        ;;
      DENY_REC)
        printf "  # %s → --- recursivo (dirs + archivos)\n" "$path" | tee -a "${LOG_FILE}"
        if [[ "${DRY_RUN}" == "1" ]]; then
          printf "  🧾 find '%s' -xdev -type d -exec setfacl -m %s:%s:--- {} +\n"   "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -xdev -type d -exec setfacl -d -m %s:%s:--- {} +\n" "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
          printf "  🧾 find '%s' -xdev -type f -exec setfacl -m %s:%s:--- {} +\n"   "$path" "$kind" "$name" | tee -a "${LOG_FILE}"
        else
          find -P "$path" -xdev -type d -exec setfacl -m "${kind}:${name}:---" {} +
          find -P "$path" -xdev -type d -exec setfacl -d -m "${kind}:${name}:---" {} +
          find -P "$path" -xdev -type f -exec setfacl -m "${kind}:${name}:---" {} +
        fi
        ;;
    esac
  done
}

# ========================
# MAIN
# ========================

printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Perfilación no estándar: %s\n" "$PROJ_NAME"
printf "════════════════════════════════════════════════════\n"
printf "\n  Perfiles cargados: %s\n" "${PROFILES[*]}"
printf "\n  El árbol de carpetas se recorrerá nivel por nivel.\n"
printf "  En cada carpeta elige qué perfiles tienen permiso\n"
printf "  de edición (ver + abrir + crear/modificar documentos).\n"
printf "  Los perfiles sin permiso no verán esa carpeta (Samba hide).\n"
printf "  Si los mismos permisos aplican a todo lo de abajo,\n"
printf "  responde 's' para aplicarlos en bloque sin seguir bajando.\n"

log_info "Iniciando perfilación DFS no estándar para: ${PROJ_NAME}"

walk_tree "${PROJ_PATH}" "${PROJ_NAME}"

# Vista previa
printf "\n"
printf "════════════════════════════════════════════════════\n"
printf "  Vista previa — comandos que se ejecutarán:\n"
printf "════════════════════════════════════════════════════\n\n"

_ORIG_DRY_RUN="${DRY_RUN}"
DRY_RUN=1
apply_acl_cmds
DRY_RUN="${_ORIG_DRY_RUN}"

printf "\n"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "DRY_RUN=1 — los cambios mostrados NO se aplicarán."
  exit 0
fi

if [[ "${FORCE}" != "1" ]]; then
  printf "  ¿Aplicar los cambios mostrados? [yes/no]: "
  confirm=""
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
