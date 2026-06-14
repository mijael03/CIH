# CIH — Conceptualización y diseño

Doc interno: objetivos, niveles, arquitectura y roadmap. El `README.md` es solo producto/resultados.

## Tesis

El costo de un agente navegando código no está en ejecutar `grep`, sino en el razonamiento y los
tokens de leer archivos completos e iterar. CIH expone **conocimiento estructurado** del repo vía
MCP para que el agente obtenga la respuesta sin leer código como texto.

Metas: tokens 5–10× ↓ · tool-calls 2–5× ↓ · latencia 30–70% ↓ · precisión 85–95%.

## Niveles

| Nivel | Capacidad | Herramientas | Origen |
|---|---|---|---|
| 1 | Símbolos | `find_symbol`, `list_symbols` | analyzer (parse) |
| 2 | Referencias | `find_references`, `find_usages` | analyzer (resuelto) |
| 3 | Call graph | `find_callers`, `find_callees`, `trace_execution` | analyzer + AST resuelto |
| 4 | Dependency graph | `module_dependencies`, `layer_violations` | imports + capas + DI GetX |
| 5 | Business flow graph | `trace_flow("lead")` | call graph + capas + entry points |

N1–N3 son commodity: el `analyzer` los da casi hechos. **El diferenciador son N4–N5.**

## Arquitectura

```
Agente ──MCP──> CIH core (agnóstico) ──> modelo intermedio <── adaptadores (por lenguaje)
                     │                                            └ Dart: analyzer nativo
                     ├ query engine                               └ (futuro) Python/TS: SCIP
                     ├ formatter (token-efficient)
                     └ store: SQLite + FTS5
```

- **Modelo intermedio** (`lib/src/model/`): symbols · occurrences · relationships. Único contrato.
- **Adaptador** (`lib/src/adapter/`): `LanguageAdapter` → emite `IndexResult`.
- El ahorro vive en el **formatter**: agregar/contar, firma + `file:line`, nunca el cuerpo por defecto.

## Decisiones

- Dart-first; harness EN Dart con `analyzer` nativo (modelo semántico completo > subconjunto SCIP).
- Core agnóstico + adaptadores; multi-lenguaje vía nuevos adaptadores, sin tocar el core.
- YAGNI: solo adaptador Dart hoy; costura limpia para el resto.

## Roadmap (reajustado)

- **Fase 0 — Validación:** confirmar que el `analyzer` parsea zefiron; spike de símbolos + tiempos.
- **Fase 1 — Formatter + ingest:** symbols/refs/impl → SQLite; respuestas compactas; MCP server.
- **Fase 2 — Call graph + slicing:** derivar callers/callees del AST resuelto.
- **Fase 3 — Dependency graph (N4):** capas por path + grafo DI (GetX put/find).
- **Fase 4 — Business flow graph (N5):** `trace_flow` por dominio.

## N4–N5 en zefiron (GetX + Clean Architecture)

- **Capas:** el segmento del path da la capa (`application/domain/infraestructure/presentation`).
  Habilita N4 directo + detectar violaciones de Clean Architecture
  (p. ej. `presentation` importando `infraestructure`).
- **DI:** `Get.put<T>()` = provee, `Get.find<T>()` = consume. Resolver `<T>` con el analyzer da el
  grafo de inyección (728 + 916 señales). 129 `GetxController` = orquestadores de cada feature.
- **Flujos:** sin `GetPage`; los entry points salen de `Get.to(View())`. Flujo =
  `View → Controller → application → domain → infraestructure(API)`.

## Benchmark

Dataset de ~20–30 preguntas sobre zefiron con respuesta dorada. Correr A (grep) vs B (CIH);
loguear tokens, tool-calls, latencia, precisión. `token_reduction = tokens_A / tokens_B`.
