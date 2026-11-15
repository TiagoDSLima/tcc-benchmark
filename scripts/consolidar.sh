#!/bin/bash
# Junta os resultados de todas as execuções em resultados/consolidado/ com média, desvio padrão,
# coeficiente de variação e intervalo de confiança de 95% de cada métrica.
# Uso: bash scripts/consolidar.sh

source "$(dirname "$0")/comum.sh" monolito

[ -d resultados ] || { echo "Nenhum resultado encontrado" >&2; exit 1; }
MSYS_NO_PATHCONV=1 docker run --rm -v "$(caminho_windows "$RAIZ"):/dados" node:22.11.0-alpine \
    node /dados/scripts/consolidar.js /dados/resultados
