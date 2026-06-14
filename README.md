# 🧭 CIH — Code Intelligence Harness

> Inteligencia de código estructurada para agentes de IA.
> Responde preguntas sobre un repositorio con datos precisos en lugar de obligar al agente a leer archivos completos.

<p>
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white">
  <img alt="niveles" src="https://img.shields.io/badge/niveles-N1–N5-brightgreen">
  <img alt="licencia" src="https://img.shields.io/badge/licencia-TBD-lightgrey">
</p>

---

## ¿Qué es?

CIH es una capa que se sitúa entre un agente de programación (Claude Code, Codex, Cursor…) y tu repositorio. En vez de que el agente haga `grep` → leer archivo → repetir, le entrega **respuestas estructuradas y mínimas** por resolución semántica (vía el `analyzer` de Dart, el mismo motor del IDE): definiciones, usos reales, quién llama a qué, dependencias y el flujo completo de una acción de negocio.

Se integra vía **MCP**, así cualquier agente compatible lo consulta como una herramienta más.

## Capacidades

| Nivel | Tool MCP | Qué responde |
|---|---|---|
| N1 Símbolos | `find_symbol` | Dónde se define algo: tipo, firma y `file:line`, sin el cuerpo. |
| N2 Referencias | `find_references` | Dónde se usa, por resolución semántica (cero falsos positivos; separa homónimos por receptor). |
| N3 Call graph | `find_callers` / `find_callees` | Quién llama a X, y a quién llama X (con el método contenedor). |
| N4 Dependencias | `module_dependencies` | De qué módulos depende uno y cuáles lo usan. |
| N4 Capas | `layer_violations` | Cruces de capa de Clean Architecture (**informativo**, no bloquea). |
| N5 Flujos | `trace_flow` | El árbol de una acción de negocio, podado por capas. |

## Uso

```bash
# 1. Indexar un proyecto Dart/Flutter
dart run bin/cih.dart index /ruta/al/proyecto

# 2. Consultar desde la CLI
dart run bin/cih.dart find    LeadController     # dónde se define
dart run bin/cih.dart refs    LeadModel          # dónde se usa
dart run bin/cih.dart callers logout             # quién lo llama
dart run bin/cih.dart callees addPermissions     # a quién llama
dart run bin/cih.dart deps    commercial         # dependencias del módulo
dart run bin/cih.dart layers                     # violaciones de capa (info)
dart run bin/cih.dart flow    post --depth 4     # flujo de negocio
```

Para conectarlo a **Claude Code** (disponible en todos tus proyectos):

```bash
claude mcp add cih -s user -- /ruta/a/CIH/cih-mcp.sh
```

El wrapper `cih-mcp.sh` fija el directorio del índice, así el server lo encuentra sin importar desde dónde se lance. Verifica con `/mcp`.

## Estado

Niveles **N1–N5** implementados. Lenguaje soportado: **Dart / Flutter**. Multi-lenguaje en el horizonte (core agnóstico + adaptadores por lenguaje).

## Resultados

Medido end-to-end sobre un CRM Flutter real (~1.500 archivos, 33k símbolos), corriendo el agente headless con y sin CIH:

| Tipo de consulta | Contexto vs grep | Precisión |
|---|---|---|
| Definiciones simples | ≈ igual (grep ya es eficiente) | 100% = grep |
| Referencias de alto volumen | **2–2.4× menos** contexto y turnos | 100% = grep |
| Call graph / flujos (N3–N5) | grep no puede hacerlo | — |

**Conclusión honesta:** CIH no es un acelerador universal. **Empata a grep en precisión** y **gana fuerte donde hay volumen o ambigüedad** (referencias masivas, homónimos) y donde la búsqueda textual simplemente no llega (call graph, flujos). En lookups triviales, grep es suficiente.

Lo que ningún `grep` da — el flujo de "registrar una exoneración", en una llamada:

```
ArrearsExonerationUseCase.post            [application]
 ├─ ArrearsExonerationAdapter.post        [infrastructure] → Adapter.token
 ├─ ArrearsDTO.fromModel                  [domain]
 ├─ NaviaToast.show                       [presentation]
 └─ OnErrorNotifyer.printStatus           [infrastructure]
```

> El benchmark sintético por-consulta (`dart run bin/bench.dart`) da hasta ~6× menos contexto, pero es un proxy optimista: mide el output de una consulta aislada, no el flujo completo del agente. La tabla de arriba (E2E) es la medida representativa.
