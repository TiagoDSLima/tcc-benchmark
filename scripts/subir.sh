#!/bin/bash
# Sobe o ambiente do zero (bancos vazios), mede o tempo de inicialização das aplicações e popula os dados.
# Uso: bash scripts/subir.sh <monolito|microsservicos>
# Variáveis opcionais: RECURSOS, ESCALA=1, REPLICAS_<SERVIÇO> (ver scripts/comum.sh)

source "$(dirname "$0")/comum.sh" "$1"

echo "==> Removendo ambiente anterior"
compose down -v --remove-orphans > /dev/null 2>&1 || true

echo "==> Subindo $PROJETO (recursos $RECURSOS, $REPLICAS)"
inicio=$(date +%s)
compose up -d --build 2>&1 | grep -vE "^\s*$" | tail -3

echo "==> Aguardando aplicações"
mkdir -p resultados
saida="resultados/inicializacao.csv"
[ -f "$saida" ] || echo "data;arquitetura;recursos;replicas;aplicacao;segundos_spring;segundos_desde_up" > "$saida"
for app in $APPS; do
    esperado=$(compose ps -q "$app" | wc -l)
    prontos=0
    for _ in $(seq 1 400); do
        prontos=$(compose logs --no-color "$app" 2>/dev/null | grep -cE "Started [A-Za-z]+ in [0-9.]+ seconds" || true)
        [ "$prontos" -ge "$esperado" ] && break
        if compose ps -a --format '{{.Service}} {{.State}}' | grep -q "^$app exited"; then
            echo "    $app parou durante a inicialização:" >&2
            compose logs --no-color --tail 30 "$app" >&2
            exit 1
        fi
        sleep 1
    done
    [ "$prontos" -ge "$esperado" ] || { echo "    $app não iniciou a tempo ($prontos de $esperado instâncias)" >&2; exit 1; }
    segundos=$(compose logs --no-color "$app" | grep -oE "Started [A-Za-z]+ in [0-9.]+ seconds" \
        | sed -E 's/.* in ([0-9.]+) seconds/\1/' | sort -n | tail -1)
    decorrido=$(( $(date +%s) - inicio ))
    printf "    %-14s %6ss (Spring, %s instância(s))\n" "$app" "$segundos" "$esperado"
    echo "$(date -Iseconds);$ARQ;$RECURSOS;$REPLICAS;$app;$segundos;$decorrido" >> "$saida"
done

for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/loja")" = "200" ] && break
    sleep 1
done
total=$(( $(date +%s) - inicio ))
echo "$(date -Iseconds);$ARQ;$RECURSOS;$REPLICAS;(todas);;$total" >> "$saida"
echo "    tudo no ar em ${total}s desde o 'up' (inclui infraestrutura)"

bash "$RAIZ/scripts/popular.sh" "$ARQ"
