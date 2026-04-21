# SCR-ACLs_SMB — Perfilación de usuarios Samba

Script de perfilación de usuarios sobre carpeta Samba en Ubuntu Server.
- Servidor: Ubuntu Server, ruta /srv/samba/02_Proyectos/
- Permisos manejados vía grupos (soporte, sudo, etc.)
- Rama de trabajo: develop → merge a main para despliegue

## Contexto
- Servidor Ubuntu con carpetas Samba en /srv/samba/02_Proyectos/
- Los permisos se gestionan por grupos (soporte, sudo, etc.)
- El script se corre en el servidor (rama main), se desarrolla en Windows (rama develop)

## Comandos frecuentes
- Probar localmente: `bash scripts/perfilar.sh --dry-run`
- En servidor: `sudo bash scripts/perfilar.sh`

## Reglas importantes
- No hardcodear rutas absolutas del servidor en los scripts
- Los permisos Samba deben coincidir con grupos del sistema

## Estructura
- scripts/ → scripts de perfilación de ACLs
- config/  → configuración de usuarios/grupos
- docs/    → documentación
- legacy/  → versiones anteriores

## Tareas frecuentes
- Agregar/modificar usuarios en grupos Samba
- Ajustar permisos sobre carpetas de proyectos (5296_IPFM, etc.)
- Probar cambios en develop antes de mergear a main