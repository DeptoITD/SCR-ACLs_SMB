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

## Decisión 6: Punto de entrada único — perfilar.sh

Se crea `scripts/perfilar.sh` como único punto de entrada para el operador.
El script lista los proyectos disponibles con un número y una etiqueta
`[estándar]` o `[no estándar]`, el usuario selecciona uno por número, y el
script muestra el proyecto, su tipo de estructura y el script que se ejecutará
antes de pedir confirmación.

Esto elimina la necesidad de que el operador conozca qué script invocar
manualmente según la estructura del proyecto.

---

## Decisión 7: Backup automático integrado en el flujo

El backup de ACLs deja de ser responsabilidad del operador y pasa a ejecutarse
automáticamente dentro de `perfilar.sh`, antes de aplicar cualquier cambio.
Al finalizar, el script muestra el comando exacto de restore por si se necesita
revertir, eliminando la búsqueda manual del archivo `.facl`.

---

## Decisión 8: Dos scripts según estructura del proyecto

Se separa la lógica de aplicación de permisos en dos scripts especializados:

- `apply_acls.sh` — para proyectos con estructura estándar (`01_WIP` en el
  primer nivel). Recibe el proyecto a procesar mediante la variable de entorno
  `TARGET_PROJECT`, evitando modificar proyectos no seleccionados.

- `apply_acls_nonstandard.sh` — para proyectos sin estructura estándar.
  Navega el árbol de directorios nivel por nivel: el operador identifica la
  carpeta que actúa como WIP y configura los permisos grupo a grupo para cada
  subcarpeta. Muestra un resumen de los comandos antes de aplicar y pide
  confirmación explícita.

---
