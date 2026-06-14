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

Para conectarlo a **Claude Code**, agrega a `.mcp.json` (con `cwd` apuntando a este repo, donde vive el índice):

```json
{
  "mcpServers": {
    "cih": {
      "command": "dart",
      "args": ["run", "bin/cih_mcp.dart"],
      "cwd": "/ruta/a/CIH"
    }
  }
}
```

## Estado

🚧 Desarrollo temprano. Lenguaje soportado: **Dart / Flutter**. Multi-lenguaje en el horizonte.

## Resultados

_Próximamente: métricas de reducción de tokens e iteraciones frente a la búsqueda tradicional._
