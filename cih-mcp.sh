#!/usr/bin/env bash
# Lanza el servidor MCP del CIH con el directorio de trabajo correcto
# (el repo CIH, donde vive .cih/index.db). Apto para usar como `command`
# en la configuración MCP de Claude Code desde cualquier proyecto.
cd "$(dirname "$0")" || exit 1
exec dart run bin/cih_mcp.dart
