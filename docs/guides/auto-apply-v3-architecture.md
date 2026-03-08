# Auto Apply v3: Arquitectura y Estado Actual

## Contexto

Este documento describe el estado real del pipeline `save -> apply` que hoy corre en la extensión de VS Code para Apus.

Objetivo operativo actual:

1. Evitar fallos silenciosos al guardar.
2. Elegir automáticamente entre `hot_reload` y `build+deploy`.
3. Dejar trazabilidad clara en logs para diagnóstico rápido.

---

## Resumen de la solución actual

Se implementó un **Apply Planner** en la extensión (v3) que centraliza la decisión del camino de aplicación.

Rutas disponibles:

1. `hot_reload`
2. `preview_build`
3. `preview_deploy` (en la práctica `build+deploy` cuando viene de deploy-first/fallback)

La ruta se decide por:

1. `apus.autoApplyMode` (`build`, `smart`, `hotReload`)
2. reglas `deploy-first` por glob
3. memoria de archivos frágiles (si ya fallaron por dependencias cruzadas)

---

## Componentes

### 1) VS Code Extension (orquestación)

Archivo principal:

- `vscode-extension/src/extension.ts`

Responsabilidades:

1. Suscribirse a `onDidSaveTextDocument`.
2. Debounce + cola serial para evitar carreras.
3. Planear ruta (`planAutoApply`).
4. Ejecutar `hot_reload` o fallback a preview script.
5. Registrar diagnóstico MCP (`get_diagnostics`) cuando falla.

### 2) Runtime MCP (fuente de verdad técnica)

Tools clave:

1. `hot_reload_doctor`
2. `hot_reload`
3. `get_diagnostics`
4. `get_view_hierarchy`

Uso en pipeline:

1. `doctor` valida readiness.
2. `hot_reload` intenta inyección.
3. `diagnostics` se consulta automáticamente si hay fallo.

### 3) IndexStore incremental (MVP)

Backend actual:

1. `vscode-extension/src/auto-apply/index-store.ts`
2. Persistencia en archivo: `.apus/cache/index-v1.json`

Uso actual:

1. En cada `save`, se actualiza entrada incremental (hash/mtime/símbolos básicos).
2. Al activar la extensión, se hace bootstrap de índice por workspace (`**/Sources/**/*.swift`) una sola vez.
3. El planner lee contexto del índice para trazabilidad (`auto_apply.index_context`).
4. El dependency-retry de `hot_reload` ahora es `index-first` (busca providers en caché) y solo usa escaneo de disco como fallback.

---

## Flujo de decisión actual

```txt
Save file
  |
  v
Queue (serial)
  |
  v
planAutoApply()
  |
  +--> preview_build   (modo build)
  |
  +--> preview_deploy  (deploy-first config/memory)
  |
  +--> hot_reload
         |
         +--> hot_reload_doctor
         +--> hot_reload
               |
               +--> success
               |
               +--> fail -> diagnostics snapshot -> fallback preview_deploy (smart)
```

---

## Reglas de planificación

`PLAN_*` codes actuales:

1. `PLAN_MODE_BUILD`
2. `PLAN_DEPLOY_FIRST_CONFIG`
3. `PLAN_DEPLOY_FIRST_MEMORY`
4. `PLAN_HOT_RELOAD`

Interpretación:

1. `PLAN_DEPLOY_FIRST_CONFIG`: el archivo coincide con `apus.autoDeployFirstFileGlobs`.
2. `PLAN_DEPLOY_FIRST_MEMORY`: el archivo quedó marcado como frágil tras fallos de hot reload.
3. `PLAN_HOT_RELOAD`: se intenta `doctor + hot_reload`.

---

## Manejo de fallos y resiliencia

### 1) Reintento de conexión MCP

Si un call falla por socket/conexión (`connection closed`, `not connected`, etc), se hace:

1. reconnect automático
2. retry una vez

### 2) Retry por tipos faltantes

Si `hot_reload` falla con `cannot find type ... in scope`:

1. se detectan tipos faltantes
2. se intenta resolver providers con `IndexStore` (mismo source-tree del archivo editado)
3. si faltan tipos, se hace escaneo limitado (`MAX_HOT_RELOAD_SOURCE_FILE_SCAN`)
4. si requiere tipos `class/protocol/actor`, se aborta retry (riesgo de inestabilidad) y se usa fallback

### 3) Source injectability guard (runtime)

`hot_reload` y `hot_reload_doctor` validan ahora el source antes de inyectar:

1. `source_code` con `class/actor/protocol` => bloquea hot reload (`HR_SOURCE_CONTAINS_REFERENCE_TYPES`)
2. `source_code` con `@main` => bloquea hot reload (`HR_SOURCE_CONTAINS_MAIN_ENTRY`)
3. doctor recibe `source_code + original_path` y puede recomendar `preview_changes` antes del intento
4. la extensión extrae `HR_*` del runtime y marca deploy-first en memoria para archivos no inyectables

### 4) Diagnostics on failure

Cuando falla auto-apply:

1. se llama `get_diagnostics`
2. se agrega snapshot al canal `Apus Auto Apply`

---

## Configuración relevante

Settings en `package.json`:

1. `apus.autoApplyMode`
2. `apus.autoHotReloadDoctorTimeoutSec`
3. `apus.autoHotReloadTimeoutSec`
4. `apus.autoHotReloadIncludeScreenshot`
5. `apus.autoDeployFirstFileGlobs`
6. `apus.autoApplyLogLevel` (`off|info|debug`)
7. `apus.autoApplyDiagnosticsOnFailure`
8. `apus.autoPreviewScriptPath`
9. `apus.previewChangesScriptPath`

### Recomendación actual para ExampleApp

`ContentView.swift` está marcado como deploy-first por dependencias cruzadas con `AppState/User`.

Esto evita:

1. errores repetidos de compilación por scope
2. inyecciones inestables en runtime

---

## Observabilidad

Canal principal:

- `Apus Auto Apply`

Mensajes clave:

1. `auto apply started (...)`
2. `plan: ... (PLAN_...)`
3. `doctor: ...`
4. `hot_reload result: ...`
5. `auto hot reload failed: ...`
6. `diagnostics: ...`

Canal secundario:

- `Apus Preview Changes` (build/deploy script output)

---

## Runbook de validación

### Smoke (rápido)

1. Guardar `Sources/AppState.swift`:
   - esperado: `plan: hot_reload`
2. Guardar `Sources/ContentView.swift`:
   - esperado: `plan: preview_deploy`

### Verificación MCP manual

1. `tools/list` debe incluir `hot_reload`, `hot_reload_doctor`, `get_diagnostics`
2. `hot_reload_doctor` debe responder `PASS/WARN/FAIL` estructurado
3. `get_diagnostics` debe responder snapshot de salud del runtime

---

## Limitaciones conocidas

1. `hot_reload` sigue siendo más sólido en vistas autocontenidas.
2. Vistas con dependencias complejas entre archivos pueden requerir build+deploy.
3. La lógica de decisión aún vive mayormente en extensión; falta mover más decisión al runtime para reducir heurística local.

---

## Próximos pasos sugeridos

1. Feature flags de observabilidad:
   - `apus.autoApplyLogLevel = off|info|debug`
   - `apus.autoApplyDiagnosticsOnFailure = true|false`
2. Comando manual `Apus: Runtime Status` (`get_diagnostics + hot_reload_doctor + view snapshot`).
3. Extender `hot_reload_doctor(file_path)` para que el runtime recomiende camino por archivo y simplificar planner local.
