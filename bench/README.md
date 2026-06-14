# Benchmark end-to-end (headless)

Mide el comportamiento **real** del agente resolviendo tareas, en dos condiciones,
corriendo `claude -p` de forma headless. A diferencia del A/B sintético (que compara
una consulta aislada), esto captura el flujo completo: cuántos turnos, cuánto
contexto y cuánto costo necesita el agente para llegar a la respuesta — con y sin CIH.

## Condiciones

| Condición | MCP | Comportamiento |
|---|---|---|
| `baseline` | ninguno | Solo grep/herramientas nativas (uso normal). |
| `cih` | `cih` expuesto | System prompt que **fuerza** usar `find_symbol`/`find_references`, con **fallback a grep**. |

`--strict-mcp-config` aísla el experimento: aunque tengas `cih` en scope user, el
baseline NO lo ve.

## Requisitos

1. Índice fresco del proyecto a evaluar:
   ```bash
   dart run bin/cih.dart index /ruta/al/proyecto
   ```
2. Define las preguntas: copia la plantilla y complétala.
   ```bash
   cp bench/questions.example.json bench/questions.json
   ```

Cada pregunta es:
```json
{
  "id": "identificador-corto",
  "prompt": "La pregunta tal cual se la harías al agente.",
  "expect_contains": ["substring1", "42"]
}
```
`expect_contains` = lista de textos que DEBEN aparecer en la respuesta para
contarla como correcta (p. ej. el nombre del archivo y la línea de la definición,
o el número de referencias). Case-insensitive. Es el criterio de acierto.

## Correr

```bash
dart run tool/bench_e2e.dart
```

Corre cada pregunta × 2 condiciones × `_repetitions` (default 3). Escribe:
- `bench/results/run-<ts>.jsonl` — datos crudos por corrida.
- `bench/results/summary-<ts>.md` — tabla agregada + ratios.

## Interpretar

La tabla resume, por condición: acierto (%), tokens de entrada/salida/total,
turnos, tiempo y costo promedio. Los **ratios** (baseline ÷ cih) dicen cuántas
veces menos contexto/turnos/costo necesitó CIH. La fila de **acierto** muestra si
CIH además es más preciso (grep da falsos positivos en comentarios/strings).

## Caveats

- **No-determinismo**: el agente varía entre corridas; por eso se repite cada
  caso (`_repetitions`) y se promedia. Sube las repeticiones si ves mucha varianza.
- **Cuesta tokens reales**: cada corrida consume API. `total_cost_usd` lo refleja.
  Set de 20 preguntas × 2 × 3 = 120 ejecuciones.
- **Reproducibilidad**: fija `_model` en `tool/bench_e2e.dart` para que A y B usen
  el mismo modelo.
- **Permisos**: usa `--permission-mode bypassPermissions` (solo-lectura sobre el
  código). Si tu entorno aún pide confirmación, cambia a
  `--dangerously-skip-permissions`.
- **Justicia**: lo único que cambia entre A y B es la disponibilidad de cih y el
  system prompt; mismo modelo, mismas preguntas.
