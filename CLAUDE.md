# CLAUDE.md — SCR-ACLs_SMB

## Propósito
Sistema declarativo, idempotente y auditable para gestión de ACLs POSIX sobre proyectos Samba.
Reemplaza comandos `setfacl` manuales por reglas versionadas en Git.
Principio rector: **DENY-BY-DEFAULT** — todo acceso debe ser explícito. Lo no declarado queda `---`.

## Infraestructura objetivo
- OS: Ubuntu Server
- Ruta base: `/srv/samba/02_Proyectos/<PROYECTO>/01_WIP/<ESPECIALIDAD>`
- Samba configurado con `hide unreadable = yes` — las carpetas sin permisos no aparecen en Windows
- Los permisos se aplican vía grupos Linux (`soporte`, `sudo`, etc.)

## Estructura del repositorio
```
SCR-ACLs_SMB/
├── config/
│   └── acls.ini                  ← Fuente de verdad. Perfiles y permisos por especialidad BIM
├── scripts/
│   ├── perfilar.sh               ← Punto de entrada único. SIEMPRE usar este
│   ├── apply_acls.sh             ← Proyectos estándar (01_WIP en primer nivel)
│   ├── apply_acls_nonstandard.sh ← Proyectos sin estructura estándar
│   └── backup_restore_acl.sh     ← Backup (getfacl) y rollback (setfacl --restore)
├── legacy/
│   └── Asignar_permisos.sh       ← NO tocar. Solo referencia histórica
└── docs/
    └── seq.png                   ← Diagrama de secuencia
```

## Flujo de trabajo
- Desarrollo en rama `develop` (PC Windows, Claude Code)
- Merge a `main` → se ejecuta en el servidor Ubuntu
- Nunca hardcodear rutas absolutas del servidor en los scripts

## Comandos de uso
```bash
# Simular sin aplicar cambios (dry-run)
bash scripts/perfilar.sh --dry-run

# Aplicar en producción (requiere sudo en el servidor)
sudo bash scripts/perfilar.sh
```

## Reglas críticas
- El script valida que la ruta base sea `/srv/samba/02_Proyectos` — falla si se corre fuera de ese contexto
- El backup de ACLs se genera automáticamente antes de cualquier cambio
- `apply_acls.sh` recibe el proyecto vía variable de entorno `TARGET_PROJECT` — nunca modifica proyectos no seleccionados
- El perfil BIM es la excepción al modelo estándar: obtiene control total sobre el WIP (`wip_full_control`)
- Proyectos no estándar (sin `01_WIP`) se procesan con `apply_acls_nonstandard.sh` — flujo interactivo con confirmación explícita
