# CIH — Contexto para Claude Code

Inteligencia de código estructurada para agentes de IA. Este archivo es el contexto interno del
proyecto (objetivos, decisiones, cómo trabajar). El `README.md` es solo producto/resultados; la
conceptualización completa está en `docs/CONCEPT.md`.

## Objetivo

Reducir tokens, iteraciones y tiempo que un agente necesita para responder preguntas sobre un
repositorio, exponiendo conocimiento estructurado vía MCP en lugar de obligarlo a leer código como
texto. Metas: tokens 5–10× ↓ · tool-calls 2–5× ↓ · precisión 85–95%.

## Decisiones de arquitectura (fijadas)

- **Dart-first**, con visión multi-lenguaje. Proyecto de validación: el CRM `zefiron`.
- **Harness implementado EN Dart**, usando el package `analyzer` nativo (el mismo motor del IDE) en
  proceso. No scip-dart, no TypeScript. El analyzer da el modelo semántico completo (tipos, element
  model), no el subconjunto de SCIP — clave para los niveles altos.
- **Core agnóstico + adaptadores por lenguaje.** La frontera es el **modelo intermedio normalizado**
  (`lib/src/model/intermediate_model.dart`). El core nunca conoce el lenguaje de origen.
  - Adaptador Dart → `analyzer` nativo.
  - Adaptadores futuros (Python/TS) → indexadores SCIP como subproceso, normalizados al mismo modelo.
- **YAGNI multi-lenguaje:** una sola implementación (Dart) hoy; solo se mantiene la costura limpia.
- **MCP en Dart:** `dart_mcp` (oficial) o `mcp_dart`/`mcp_server`.
- **Storage:** SQLite (+ FTS5). El ahorro de tokens vive en el *formatter* (agregar/contar, firma +
  `file:line`, nunca el cuerpo por defecto).

## Niveles del producto

1. Símbolos · 2. Referencias · 3. Call graph · 4. Dependency graph · 5. Business flow graph.
N1–N3 son commodity (el analyzer da ~90%); **el diferenciador son N4–N5.** Detalle en `docs/CONCEPT.md`.

## Proyecto de validación: zefiron

- Ruta: `/Users/mijaelcama/Documents/trabajo/navia/zefiron` (solo lectura, nunca escribir ahí).
- CRM inmobiliario, Flutter. ~1498 archivos `.dart`. SDK del proyecto `^3.11`, toolchain 3.12.1.
- Stack: **GetX** (state + DI + navegación) + **Clean Architecture por feature**.
  - DI: 728 `Get.put` + 916 `Get.find` → grafo de inyección (requiere resolver el tipo genérico
    `<X>`; por eso el analyzer nativo). 129 `GetxController`.
  - Sin `GetPage`: navegación imperativa; los entry points de N5 se infieren de `Get.to(View())`.
  - Capas por path: `modules/<dominio>/<feature>/{application,domain,infraestructure,presentation}`
    → N4 casi gratis + posible detección de violaciones de capa.

## Estructura del repo

- `lib/src/model/` — modelo intermedio (contrato core ↔ adaptadores)
- `lib/src/adapter/` — interfaz `LanguageAdapter`
- `bin/` — ejecutables (spikes, CLI)
- `docs/` — conceptualización y diseño interno

## Cómo trabajar aquí

- A `zefiron` solo se lee, jamás se escribe.
- Toda capacidad nueva pasa por el modelo intermedio; no acoplar el core al `analyzer`.
- Medir siempre (tokens/tool-calls/tiempo): el benchmark es parte del producto.
