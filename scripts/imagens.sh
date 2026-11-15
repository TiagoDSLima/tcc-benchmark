#!/bin/bash
# Registra o tamanho das imagens Docker das aplicações.
# Uso: bash scripts/imagens.sh

source "$(dirname "$0")/comum.sh" monolito

mkdir -p resultados
saida=resultados/imagens.csv
echo "imagem;tamanho_bytes;tamanho" > "$saida"
for img in monolito api-gateway auth participante produto loja pedido pagamento; do
    bytes=$(docker image inspect "bench/$img" --format '{{.Size}}' 2>/dev/null || echo "")
    [ -n "$bytes" ] || { echo "bench/$img não foi construída" >&2; continue; }
    echo "bench/$img;$bytes;$(awk "BEGIN { printf \"%.0f MB\", $bytes / 1000000 }")" >> "$saida"
done
cat "$saida"
