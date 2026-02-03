# SCR-ACC_PR_SMB

Repositorio para estandarizar la gestión de permisos ACL (setfacl/getfacl) sobre proyectos en
`/srv/samba/02_Proyectos` (Ubuntu).

## Objetivo
- Evitar scripts gigantes repetitivos.
- Permitir validación, auditoría, backup/restore y ejecución idempotente.
- Versionar reglas y cambios con Git (PRs, tags, releases).

## Estructura
- `config/projects.conf`: lista de proyectos y BASE
- `config/users.conf`: usuarios objetivo (IND_*)
- `config/rules.d/*.rules`: reglas declarativas
- `scripts/validate.sh`: valida rutas y usuarios
- `scripts/apply_acls.sh`: aplica reglas
- `scripts/backup_restore_acl.sh`: backup/restore completo

## Uso rápido
1) Validar
```bash
sudo ./scripts/validate.sh
```

2) Backup antes
```bash
sudo ./scripts/backup_restore_acl.sh backup /srv/samba/02_Proyectos /root/acl_before.facl
```

3) Aplicar reglas
```bash
sudo ./scripts/apply_acls.sh
```

4) Backup después
```bash
sudo ./scripts/backup_restore_acl.sh backup /srv/samba/02_Proyectos /root/acl_after.facl
```

5) Rollback (si algo sale mal)
```bash
sudo ./scripts/backup_restore_acl.sh restore / /root/acl_before.facl
```

## Convenciones
- Cambios solo por PR.
- Cada ticket de permisos debe quedar como commit/PR con evidencia.
