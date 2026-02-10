# Bitácora / Registro de Cambios – Sistema de Gestión de ACLs

> Nota terminológica: en TI también se usa “Registro de Cambios” o “Change Log”. 
> El término **Bitácora** es válido y correcto en contextos técnicos en español,
> especialmente para registro cronológico de decisiones y eventos.

---

## Contexto inicial

La gestión de permisos se realizaba manualmente mediante comandos `setfacl` repetitivos,
con alto riesgo de error, baja trazabilidad y resultados inconsistentes entre proyectos.

---

## Decisión 1: Modelo declarativo

Se adopta un modelo basado en reglas declarativas versionadas en Git,
permitiendo:
- auditoría,
- control de cambios,
- reproducibilidad.

---

## Decisión 2: Deny-by-default

Se define como principio rector que todo acceso debe ser explícito.
Lo no declarado queda sin permisos (`---`).

---

## Decisión 3: Tolerancia a inexistencias

El sistema no falla si:
- un proyecto no existe,
- una especialidad aún no está creada.

Esto permite operar en múltiples servidores con estructuras diferentes.

---

## Decisión 4: DRY-RUN obligatorio

Se incorpora un modo de simulación para validar impacto antes de producción,
reduciendo riesgos operativos.

---

## Decisión 5: Blindaje de alcance

Se implementa una validación dura que impide ejecutar el script fuera de:
`/srv/samba/02_Proyectos`.

---
