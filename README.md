# Sistema Declarativo de Gestión de ACLs para Proyectos Samba

## 1. Propósito

Este repositorio implementa un **sistema declarativo, idempotente y auditable** para la gestión de permisos **ACL POSIX** sobre proyectos alojados en un servidor **Linux (Ubuntu)** con almacenamiento compartido vía **Samba**.

El objetivo es **estandarizar y automatizar** la asignación de permisos por **perfil** y **proyecto**, eliminando configuraciones manuales, inconsistencias y residuos de ACL antiguas.

El sistema está diseñado para operar correctamente incluso cuando:

- Existen proyectos sin estructura completa.
- Algunas especialidades no existen aún.
- Los usuarios o grupos provienen de **Samba / AD / LDAP**.
- El script se ejecuta múltiples veces (**idempotencia real**).

---

## 2. Principio de seguridad

> **"Lo que no edita, NO lo ve (ni lo lista, ni le aparece)"**

Modelo **DENY-BY-DEFAULT**:

- Solo se otorgan permisos explícitos en carpetas declaradas como `write`.
- En `01_WIP`, los perfiles restringidos reciben **solo `x` (traverse)**.
- Las carpetas no editables reciben ACL explícita `---`.
- BIM es la única excepción con visibilidad total del WIP.

---

## 3. Alcance funcional

El sistema permite:

- Aplicar permisos ACL POSIX (`setfacl`) de forma declarativa.
- Ejecutarse múltiples veces sin efectos acumulativos.
- Simular cambios mediante **DRY-RUN**.
- Respaldar y restaurar ACLs completas.
- Registrar todas las acciones en logs estructurados.

🚫 El sistema **NO** crea carpetas, usuarios ni grupos.

---

## 4. Alcance técnico

El script **solo opera** sobre:

```
/srv/samba/02_Proyectos
```

Existe una validación dura que aborta la ejecución si el `root` configurado no coincide exactamente con esta ruta.

---

## 5. Estructura del repositorio

```
SCR-ACLs_SMB/
├── config/
│   └── rules.d/
│       └── acls.ini
├── scripts/
│   ├── apply_acls.sh
│   └── backup_restore_acl.sh
├── logs/
│   └── apply_acls.log
└── README.md
```

---

## 6. Perfiles y permisos

| Perfil | Carpetas con visualización y edición |
|------|--------------------------------------|
| IND_A | A_ARQ, O_LEV, YAC_ACU, YPA_PAT, YPM_PTR, YSE_SEN, YSH_SGH |
| IND_E | E_EST, O_LEV |
| IND_YTP | YTP_TOP, A_ARQ, O_LEV, YAC_ACU, YPA_PAT, YPM_PTR, YSE_SEN, YSH_SGH, E_EST |
| IND_B | TODAS las carpetas del WIP |

---

## 7. Flujo operativo obligatorio

### 7.1 Backup

```bash
sudo ./scripts/backup_restore_acl.sh backup \
  /srv/samba/02_Proyectos \
  /root/acl_before_$(date +%Y%m%d_%H%M).facl
```

### 7.2 DRY-RUN (prueba)

```bash
sudo DRY_RUN=1 ./scripts/apply_acls.sh
```

No modifica ACLs. Solo simula.

### 7.3 Ejecución real

```bash
sudo ./scripts/apply_acls.sh
```

---

## 8. Rollback

```bash
sudo ./scripts/backup_restore_acl.sh restore / /root/acl_before_YYYYMMDD_HHMM.facl
```

---

## 9. Nota Samba / Windows

Para ocultar carpetas sin permiso en Windows Explorer:

```ini
hide unreadable = yes
```

---

## 10. Reglas operativas

- Git **NUNCA** con `sudo`.
- Scripts ACL **SIEMPRE** con `sudo`.
- No modificar ACLs manualmente fuera del sistema.
- Flujo obligatorio: **backup → DRY-RUN → apply**.

---

## 11. Estado

Sistema validado y listo para operación controlada en producción.
