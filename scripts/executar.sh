#!/bin/bash
# Executa um cenário do k6 contra o ambiente que está no ar e coleta CPU e memória dos containers.
# Uso: bash scripts/executar.sh <monolito|microsservicos> <catalogo|compra|misto|repouso> [perfil]
# Variáveis opcionais: TAXA (iterações/s, padrão 50), DURACAO (padrão 3m), PASSOS, DURACAO_PASSO,
#                      AQUECER (padrão 1), DURACAO_AQUECIMENTO (padrão 1m), REPETICAO (rótulo da rodada),
#                      RECURSOS, ESCALA, REPLICAS_<SERVIÇO> (iguais aos usados no subir.sh)
# O cenário "repouso" não gera carga: só mede CPU e memória com as aplicações paradas durante DURACAO.

source "$(dirname "$0")/comum.sh" "$1"

CENARIO=${2:?Informe o cenário: catalogo, compra, misto ou repouso}
PERFIL=${3:-carga}
[ "$CENARIO" = "repouso" ] && PERFIL=repouso
TAXA=${TAXA:-50}
DURACAO=${DURACAO:-3m}
PASSOS=${PASSOS:-8}
DURACAO_PASSO=${DURACAO_PASSO:-1m}
AQUECER=${AQUECER:-1}
REPETICAO=${REPETICAO:-1}
K6_IMAGEM=grafana/k6:0.54.0

[ "$CENARIO" = "repouso" ] || [ -f "k6/$CENARIO.js" ] || { echo "Cenário inexistente: k6/$CENARIO.js" >&2; exit 1; }
compose ps --status running --services | grep -q . || { echo "Ambiente $ARQ não está no ar: rode scripts/subir.sh $ARQ" >&2; exit 1; }

PASTA="resultados/$(date +%Y%m%d-%H%M%S)_${ARQ}_${CENARIO}_${PERFIL}_${RECURSOS}_e${ESCALA}_r${REPETICAO}"
mkdir -p "$PASTA"

k6() {
    MSYS_NO_PATHCONV=1 docker run --rm --network "$REDE" --cpus "$K6_CPUS" --memory "$K6_MEMORIA" \
        -v "$(caminho_windows "$RAIZ/k6"):/scripts:ro" -v "$(caminho_windows "$RAIZ/$PASTA"):/resultados" \
        -e BASE_URL="$ENTRADA" -e CLIENTES="$CLIENTES" -e TAXA="$TAXA" -e DURACAO="$DURACAO" \
        -e PASSOS="$PASSOS" -e DURACAO_PASSO="$DURACAO_PASSO" \
        -e DURACAO_AQUECIMENTO="${DURACAO_AQUECIMENTO:-1m}" -e VUS_MAX="${VUS_MAX:-500}" \
        "$@"
}

segundos() {
    case "$1" in
        *ms) echo $(( ${1%ms} / 1000 )) ;;
        *s) echo "${1%s}" ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *h) echo $(( ${1%h} * 3600 )) ;;
        *) echo "$1" ;;
    esac
}

{
    echo "data=$(date -Iseconds)"
    echo "arquitetura=$ARQ"
    echo "cenario=$CENARIO"
    echo "perfil=$PERFIL"
    echo "taxa=$TAXA"
    echo "duracao=$DURACAO"
    echo "passos=$PASSOS"
    echo "duracao_passo=$DURACAO_PASSO"
    echo "recursos=$RECURSOS"
    echo "escala=$ESCALA"
    echo "replicas=$REPLICAS"
    echo "repeticao=$REPETICAO"
    echo "commit_microsservicos=$(git -C ../ecommerce-microservices rev-parse --short HEAD 2>/dev/null)"
    echo "commit_monolito=$(git -C ../ecommerce-monolith rev-parse --short HEAD 2>/dev/null)"
    echo "docker=$(docker version --format '{{.Server.Version}}')"
    echo "cpus_host=$(docker info --format '{{.NCPU}}')"
    echo "memoria_host=$(docker info --format '{{.MemTotal}}')"
    env | grep -E "^([A-Z0-9]+_(CPUS|MEMORIA)|JAVA_OPCOES)=" | sort
} > "$PASTA/ambiente.txt"

if [ "$CENARIO" != "repouso" ] && [ "$AQUECER" = "1" ] && [ "$PERFIL" != "fumaca" ]; then
    echo "==> Aquecimento da JVM (${DURACAO_AQUECIMENTO:-1m}, não é medido)"
    k6 -e PERFIL=aquecimento "$K6_IMAGEM" run --quiet --no-summary "/scripts/$CENARIO.js" > "$PASTA/aquecimento.log" 2>&1 \
        || echo "    aquecimento terminou com erros, veja $PASTA/aquecimento.log"
fi

if [ "$CENARIO" = "repouso" ]; then
    echo "==> Aguardando ${ESPERA_REPOUSO:-30}s sem carga antes de medir"
    sleep "${ESPERA_REPOUSO:-30}"
fi

echo "==> Coletando recursos dos containers"
echo "momento;container;cpu_percentual;memoria_uso;memoria_limite;rede" > "$PASTA/recursos.csv"
(
    while [ ! -f "$PASTA/.fim" ]; do
        docker stats --no-stream --format '{{.Name}};{{.CPUPerc}};{{.MemUsage}};{{.NetIO}}' \
            | grep "^$PROJETO-" | sed -E "s/^/$(date +%s);/; s| / |;|" >> "$PASTA/recursos.csv" || true
    done
) &
COLETOR=$!

STATUS=0
if [ "$CENARIO" = "repouso" ]; then
    echo "==> Medindo consumo em repouso de $ARQ por $DURACAO"
    sleep "$(segundos "$DURACAO")"
else
    echo "==> Executando $CENARIO ($PERFIL, taxa $TAXA/s, recursos $RECURSOS, $REPLICAS) em $ARQ"
    set +e
    k6 -e PERFIL="$PERFIL" -e SAIDA="/resultados/k6.json" "$K6_IMAGEM" run "/scripts/$CENARIO.js" 2>&1 | tee "$PASTA/k6.log"
    STATUS=${PIPESTATUS[0]}
    set -e
fi

touch "$PASTA/.fim"
wait "$COLETOR" 2>/dev/null || true
rm -f "$PASTA/.fim"

compose logs --no-color --since 30m > "$PASTA/aplicacoes.log" 2>&1 || true
echo "==> Resultados em $PASTA (código $STATUS)"
exit "$STATUS"
