# Naming Strategy: Runtime Intelligence MCP Server for iOS

## La tesis del nombre

Tidewave (el referente) se llama así porque:
- **Tide** (marea) + **Wave** (ola) = fenómeno del agua
- Elixir es un líquido → el nombre ancla al ecosistema sin decirlo
- Cuando expandieron a Rails, Django, Flask, Next.js → el nombre seguía funcionando
- Si se hubieran llamado "Elixirwave" → rebrand obligado

Nuestro nombre debe seguir la misma lógica:
- Swift es un pájaro (vencejo) → el nombre debe oler a aire/vuelo/visión
- Pero NO debe decir "Swift" → nos limitaría cuando soportemos Kotlin, Flutter, React Native
- Debe sonar a producto tech, no a medicina ni a departamento

## El vencejo como metáfora

El vencejo (Apus apus) tiene características que mapean perfectamente al producto:

| Vencejo | Producto |
|---------|----------|
| Duerme mientras vuela | Corre sin frenar tu app |
| Nunca aterriza (años en el aire) | Siempre está en el runtime, no es análisis estático |
| Visión excepcional en pleno vuelo | Visibilidad total: DB, logs, network, views, state |
| Vuelo horizontal más rápido | Mínimo overhead en debug builds |
| Se sostiene en térmicas invisibles | Infraestructura invisible (localhost, zero config) |
| Nombre científico: Apus ("sin pies") | Nunca toca el suelo, nunca deja de observar |

## Nombres descartados y por qué

### Descartados: demasiado explícitos (limitan a Swift)
| Nombre | Problema |
|--------|----------|
| Swiftray | "Swift" en el nombre nos ata al lenguaje |
| Swiftwake | Mismo problema |
| Swiftbeam | Mismo problema |
| SwiftScope | Mismo problema |
| RuntimeInspector | Genérico, no tiene identidad |

### Descartados: suenan a medicina/pharma
| Nombre | Problema |
|--------|----------|
| Aervigil | Suena a pastilla (Provigil es un fármaco real) |
| Vigilens | Suena clínico |
| Vigilux | Suena a laboratorio |
| Vigilo | Suena a pharma |

### Descartados: asociaciones no deseadas
| Nombre | Problema |
|--------|----------|
| Vigiloft | "Loft" = departamento hipster |
| Glasswing | Es una mariposa, rompe la narrativa del vencejo |
| Drift | Tokyo Drift, crypto |
| Lumen | Laravel ya tiene Lumen |
| Pulse | Kean tiene Pulse (iOS logging framework) |
| Sonar | SonarQube existe |
| Glide | Glide existe (Android image loading) |

### Descartados: caros o tomados
| Nombre | Problema |
|--------|----------|
| Vigil | vigil.dev cuesta una fortuna |
| Thermal.dev | Probablemente caro |
| Beacon | iBeacon de Apple, Bluetooth beacons |
| Flare | No tiene conexión con vuelo/Swift |

## Finalistas

### #1: Apus ⭐⭐⭐

```
Apus (del griego: "sin pies")
Género científico del vencejo (Apus apus)
También: constelación del hemisferio sur
```

| Criterio | Evaluación |
|----------|-----------|
| Conexión con Swift | ES el vencejo, pero solo los curiosos lo sabrán |
| Exclusividad | Nadie más lo usa en tech |
| Expansibilidad | Funciona para cualquier plataforma |
| Como import | `import Apus` — 4 letras, limpio |
| Dominio | apus.dev — probablemente accesible |
| Longitud | 4 letras (el más corto de todos) |
| Narrativa | "Un pájaro que nunca aterriza. Nunca deja de observar." |
| Suena a producto | Como Figma — no significa nada hasta que lo googles |
| Logo | Constelación Apus o silueta de vencejo |

**El pitch:**
> "Why Apus? It's the scientific name for the swift — a bird that never lands.
> Like Apus, your runtime inspector never stops watching."

### #2: Thermal ⭐⭐

```
Thermal: corriente de aire caliente ascendente
Lo que sostiene al vencejo mientras duerme en vuelo
```

| Criterio | Evaluación |
|----------|-----------|
| Conexión con Swift | Indirecta: la térmica sostiene al vencejo |
| Exclusividad | Puede haber conflictos (término común) |
| Expansibilidad | Universal, no atado a ningún lenguaje |
| Como import | `import Thermal` — 7 letras |
| Dominio | thermal.dev o usethermal.dev |
| Longitud | 7 letras |
| Narrativa | "La fuerza invisible que revela todo" |
| Suena a producto | Sí, pero puede confundirse con ropa/calefacción |
| Logo | Ondas de calor ascendentes |

**El pitch:**
> "The invisible force that reveals everything happening inside your running app."

### #3: Updraft ⭐

```
Updraft: corriente ascendente de aire
Lo que eleva a los pájaros sin esfuerzo
```

| Criterio | Evaluación |
|----------|-----------|
| Conexión con Swift | Indirecta: el updraft eleva al vencejo |
| Exclusividad | Menos conflictos que Thermal |
| Expansibilidad | Universal |
| Como import | `import Updraft` — 7 letras |
| Dominio | updraft.dev |
| Longitud | 7 letras |
| Narrativa | "Te eleva por encima de tu app para verla completa" |
| Suena a producto | Sí, energético y positivo |
| Logo | Flecha ascendente + silueta de pájaro |

**El pitch:**
> "Updraft lifts your AI agent above your running app —
> giving it access to your database, logs, network, views, and more."

## Comparación directa con Tidewave

```
                Tidewave              Apus / Thermal / Updraft
Ecosistema:     Elixir (líquido)      Swift (pájaro)
Metáfora:       Agua                  Aire
Conexión:       Tide/Wave = agua      Apus = vencejo, Thermal = lo que lo sostiene
Explícito:      No dice "Elixir"      No dice "Swift"
Expandible:     ✅ Rails, Django...   ✅ Kotlin, Flutter...
Letras:         8                     4 / 7 / 7
```

## Recomendación

**Apus** es el nombre más fuerte por:
1. **Es el más corto** (4 letras) — fácil de escribir, recordar, importar
2. **La historia es inmejorable** — "sin pies, nunca aterriza, nunca deja de observar"
3. **Es el vencejo sin decir Swift** — la conexión está ahí para quien la busque
4. **Escala sin fricción** — el día que soporten Android, nada que cambiar
5. **Es único** — no hay productos tech llamados Apus
6. **Tiene doble significado** — pájaro + constelación = rico para branding
7. **Modelo Figma** — nombre que no significa nada para la mayoría, pero tiene una historia profunda para quien la descubre

## Pendiente

- [ ] Verificar disponibilidad de dominio: apus.dev, apus.io, getapus.dev, useapus.dev
- [ ] Verificar disponibilidad en GitHub: github.com/apus-dev, github.com/apus-ai
- [ ] Verificar que no haya trademark conflicts en tech
- [ ] Decisión final del nombre
- [ ] Renombrar package de RuntimeInspector → [nombre elegido]
- [ ] Crear repositorio con nombre definitivo
