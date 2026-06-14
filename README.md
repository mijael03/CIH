# 🧭 CIH — Code Intelligence Harness

> Inteligencia de código estructurada para agentes de IA.
> Responde preguntas sobre un repositorio con datos precisos en lugar de obligar al agente a leer archivos completos.

<p>
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white">
  <img alt="estado" src="https://img.shields.io/badge/estado-en%20desarrollo-yellow">
  <img alt="licencia" src="https://img.shields.io/badge/licencia-TBD-lightgrey">
</p>

---

## ¿Qué es?

CIH es una capa que se sitúa entre un agente de programación (Claude Code, Codex, Cursor…) y tu repositorio. En vez de que el agente haga `grep` → leer archivo → repetir, le entrega **respuestas estructuradas y mínimas**: dónde se define un símbolo, dónde se usa, quién lo llama, de qué depende y qué ocurre en un flujo de negocio completo.

El resultado: **menos tokens, menos iteraciones y respuestas más precisas.**

## Capacidades

- 🔎 **Símbolos** — definiciones, firmas y ubicación exacta, sin volcar el archivo.
- 🔗 **Referencias** — dónde se usa algo, agrupado y contado.
- 🧬 **Herencia** — implementaciones y subclases.
- 📞 **Llamadas** — quién llama a qué.
- 🧱 **Dependencias** — entre módulos y capas.
- 🌊 **Flujos** — el recorrido completo de una acción de negocio.

Se integra vía **MCP**, así cualquier agente compatible lo consulta como una herramienta más.

## Uso

```bash
# 1. Indexar un proyecto Dart/Flutter
dart run bin/cih.dart index /ruta/al/proyecto

# 2. Consultar desde la CLI
dart run bin/cih.dart find  LeadController   # ¿dónde se define?
dart run bin/cih.dart refs  LeadModel        # ¿dónde se usa? (semántico)

# 3. O exponerlo como servidor MCP para tu agente
dart run bin/cih_mcp.dart
```

Para conectarlo a **Claude Code** (disponible en todos tus proyectos):

```bash
claude mcp add cih -s user -- /ruta/a/CIH/cih-mcp.sh
```

El wrapper `cih-mcp.sh` fija el directorio correcto, así el server encuentra el índice sin importar desde dónde lances Claude Code. Verifica con `/mcp` y pídele al agente que use `find_symbol` / `find_references`.

## Estado

🚧 Desarrollo temprano. Lenguaje soportado: **Dart / Flutter**. Multi-lenguaje en el horizonte.

## Resultados

Benchmark sobre un CRM Flutter real (~1.500 archivos, 33k símbolos). Mide el **contexto entregado al LLM**: el output crudo de `grep -rn` (lo que un agente debe leer) frente a la respuesta de CIH, para la misma consulta.

| Consulta | Tipo | grep (tokens) | CIH (tokens) | Ahorro |
|---|---|--:|--:|--:|
| LeadModel | refs | 30 265 | 4 985 | 6.1× |
| LeadController | refs | 15 252 | 2 443 | 6.2× |
| CustomerController | refs | 6 228 | 1 419 | 4.4× |
| TicketHeaderModel | refs | 7 839 | 1 271 | 6.2× |
| ProcessInstanceController | def | 7 220 | 500 | 14.4× |
| LeadDetailController | def | 1 014 | 85 | 11.9× |
| LeadAdapter | def | 370 | 77 | 4.8× |
| LeadUseCase | def | 586 | 246 | 2.4× |
| **Total** | | **68 774** | **11 026** | **6.2×** |

**6.2× menos contexto** — y es un piso conservador: no cuenta las lecturas de archivo que un agente con grep haría además para descartar los falsos positivos (que CIH, al ser semántico, no tiene). Reproducible con `dart run bin/bench.dart`.
