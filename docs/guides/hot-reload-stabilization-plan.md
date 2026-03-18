# Hot Reload Stabilization Plan

## Estado Implementado

Ver estado actual implementado del pipeline en:

- `docs/guides/auto-apply-v3-architecture.md`

## Objetivo

Construir un flujo de edición estable para Apus donde cada cambio termine en un resultado visible:

1. `save -> decision engine -> apply -> verify`
2. Si hot reload falla, fallback automático a build/deploy.
3. Reducir la fragilidad de `source_code` manual y movernos a `file_path`.

---

## Problema actual

El hot reload existe, pero es frágil por una combinación de factores:

1. Requiere `source_code` manual (payload grande y propenso a errores).
2. Restricción de structs autocontenidos y dependencias implícitas.
3. Precondiciones técnicas estrictas (simulator/debug/linker/toolchain/build products).
4. Carrera entre autosave build y hot reload.
5. Errores poco tipados, difíciles de automatizar.

---

## Definition of Done

1. `hot_reload_doctor` responde `PASS/WARN/FAIL` con checks estructurados.
2. `hot_reload` devuelve `error_code` + `remediation` en todos los fallos.
3. VS Code ejecuta pipeline inteligente:
   - `doctor -> hot_reload_file -> fallback preview/build`.
4. `hot_reload_file(file_path)` funciona sin pegar `source_code` manual.
5. Meta operativa:
   - 20 cambios consecutivos.
   - `>=90%` aplican por hot reload en `<5s`.
   - `100%` terminan en cambio visible por fallback.

---

## Precondiciones técnicas no negociables

1. `-Xlinker -interposable` habilitado.
2. `ENABLE_DEBUG_DYLIB = NO`.
3. Build en `Debug`.
4. Simulador (no dispositivo físico).
5. Toolchain/SDK consistentes entre build base y compilación de inyección.
6. Build products válidos (`Apus.swiftmodule`, `Debug-iphonesimulator`).

---

## Contrato MCP objetivo

### 1) `hot_reload_doctor`

Salida propuesta:

```json
{
  "status": "PASS|WARN|FAIL",
  "checks": [
    {"id":"is_debug","ok":true,"blocking":true,"details":"..."},
    {"id":"is_simulator","ok":true,"blocking":true,"details":"..."},
    {"id":"hot_reload_tool_registered","ok":true,"blocking":true,"details":"..."},
    {"id":"project_root_detected","ok":true,"blocking":false,"details":"..."},
    {"id":"build_products_found","ok":true,"blocking":true,"details":"..."},
    {"id":"apus_swiftmodule_found","ok":true,"blocking":false,"details":"..."},
    {"id":"interposable_hint","ok":true,"blocking":false,"details":"..."}
  ],
  "recommended_path": "hot_reload|preview_changes",
  "reason_codes": []
}
```

### 2) `hot_reload_file(file_path, symbol?, include_screenshot?)`

Comportamiento:

1. Leer archivo en project root.
2. Resolver payload compilable (v1 archivo completo, v2 dependency closure).
3. Compilar/injectar.
4. Regresar resultado estructurado y screenshot opcional.

### 3) `hot_reload(source_code)` (compatibilidad)

Se mantiene para backward compatibility, pero todos los errores deben incluir:

1. `error_code`
2. `message`
3. `remediation`

---

## Reason codes base

1. `HR_NOT_DEBUG`
2. `HR_NOT_SIMULATOR`
3. `HR_HOT_RELOAD_TOOL_MISSING`
4. `HR_PROJECT_ROOT_UNDETECTED`
5. `HR_BUILD_PRODUCTS_MISSING`
6. `HR_APUS_SWIFTMODULE_MISSING`
7. `HR_INTERPOSABLE_NOT_DETECTED`
8. `HR_SOURCE_COMPILE_ERROR`
9. `HR_INTERPOSE_FAILED`
10. `HR_PATH_NOT_ALLOWED`

---

## Arquitectura objetivo

1. Runtime Apus (Swift): checks, compilación, inyección, códigos de error.
2. VS Code Extension (TS): orquestación de camino + fallback.
3. MCP contract estructurado: decisiones automáticas y trazables.

---

## Plan por PRs

## PR-1: `hot_reload_doctor`

### Alcance

1. Nuevo tool en runtime.
2. Checks de entorno críticos.
3. Salida estructurada (`status/checks/recommended_path/reason_codes`).

### Archivos (propuestos)

1. `Sources/Apus/Tools/HotReloadDoctorTool.swift`
2. `Sources/Apus/Tools/ToolRegistry.swift`
3. `Tests/ApusTests/...` (unit + integration para doctor)

### Criterio de aceptación

1. Doctor responde `<300ms`.
2. Entrega recomendación clara (`hot_reload` vs `preview_changes`).

---

## PR-2: errores tipados en `HotReloadTool`

### Alcance

1. Introducir enum de errores (`HotReloadErrorCode`).
2. Mapear todos los puntos de fallo.
3. Retornar siempre `error_code + remediation`.

### Criterio de aceptación

1. Cero errores opacos.
2. Cada fallo común mapea a un reason code específico.

---

## PR-3: pipeline inteligente en VS Code

### Alcance

1. Nuevo modo: `apus.autoApplyMode = smart|build|hotReload`.
2. En `smart`:
   - Ejecuta `hot_reload_doctor`.
   - Si PASS, intenta hot reload.
   - Si falla, fallback automático a preview/build.

### Criterio de aceptación

1. Al guardar, siempre se ejecuta un camino final.
2. Output muestra ruta elegida + reason code.

---

## PR-4: `hot_reload_file(file_path)` v1

### Alcance

1. Extender hot reload para aceptar `file_path`.
2. Resolver ruta segura contra project root.
3. Compilar con contenido del archivo completo.

### Criterio de aceptación

1. Cambio hot reload con una sola ruta, sin `source_code` manual.

---

## PR-5: resolución automática de dependencias (v2)

### Alcance

1. Integrar SwiftSyntax para construir dependency closure.
2. Incluir structs/helpers necesarios en el payload.
3. Fallback interno a archivo completo si parser no puede resolver.

### Criterio de aceptación

1. Disminuyen fallos por “tipo no encontrado” y “struct no autocontenido”.

---

## PR-6: observabilidad, docs y QA

### Alcance

1. Métricas:
   - `doctor_pass_rate`
   - `hot_reload_success_rate`
   - `fallback_rate`
   - `avg_hot_reload_ms`
2. Guía de troubleshooting por `reason_code`.
3. Suite e2e de 20 cambios secuenciales.

### Criterio de aceptación

1. Reporte con tasa de éxito real por escenario.

---

## Roadmap sugerido

### Semana 1 (estabilidad primero)

1. PR-1 (`hot_reload_doctor`)
2. PR-2 (errores tipados)
3. PR-3 (pipeline + fallback)

Resultado: experiencia robusta aunque `hot_reload_file` aún no exista.

### Semana 2 (ergonomía y escala)

1. PR-4 (`hot_reload_file` v1)
2. PR-5 (dependency resolver v2)
3. PR-6 (observabilidad + QA + docs)

Resultado: flujo usable por terceros sin prompts frágiles.

---

## Riesgos y mitigación

1. Toolchain mismatch frecuente.
   - Mitigación: doctor bloqueante + remediation explícita.
2. Race entre autosave y ejecución.
   - Mitigación: cola única y lock por workspace.
3. Complejidad de parser SwiftSyntax.
   - Mitigación: v1 archivo completo; v2 incremental.
4. Regresiones de UX.
   - Mitigación: logs estructurados de decisión en extensión.

---

## Checklist de arranque (hoy)

1. Implementar PR-1 (`hot_reload_doctor`).
2. Definir enum final de `reason_codes` (PR-2).
3. Integrar fallback automático en extensión (PR-3).
4. Correr benchmark base de 20 cambios para medir punto de partida.

---

## ASCII de referencia

```txt
Cmd+S
  |
  v
[hot_reload_doctor]
  |
  +--> FAIL/WARN --> [Preview Changes]
  |
  +--> PASS -------> [hot_reload_file]
                         |
                         +--> FAIL -> [Preview Changes]
                         |
                         +--> OK   -> [Live update + screenshot]
```
