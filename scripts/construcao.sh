#!/bin/bash
# Mede o tempo de construção das imagens de cada arquitetura, sem reaproveitar camadas do Docker.
# As dependências do Maven ficam em cache, então o tempo mede a compilação e o empacotamento.
# Uso: bash scripts/construcao.sh [repetições, padrão 3]

REPETICOES=${1:-3}
source "$(dirname "$0")/comum.sh" monolito

mkdir -p resultados
saida=resultados/construcao.csv
[ -f "$saida" ] || echo "data;arquitetura;repeticao;segundos" > "$saida"

for r in $(seq 1 "$REPETICOES"); do
    for arq in monolito microsservicos; do
        inicio=$(date +%s)
        docker compose -p "bench-$arq" -f compose.comum.yml -f "compose.$arq.yml" build --no-cache > /dev/null 2>&1 \
            || { echo "Falha ao construir $arq" >&2; exit 1; }
        segundos=$(( $(date +%s) - inicio ))
        echo "$(date -Iseconds);$arq;$r;$segundos" >> "$saida"
        echo "    $arq (repetição $r): ${segundos}s"
    done
done
cat "$saida"
