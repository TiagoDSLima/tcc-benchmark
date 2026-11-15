#!/bin/bash
# Variáveis e funções usadas pelos outros scripts.
# Uso: source scripts/comum.sh <monolito|microsservicos>
# Variáveis opcionais: RECURSOS (2cpu, 4cpu ou 8cpu), ESCALA=1 (balanceador e réplicas), REPLICAS_<SERVIÇO>

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

DOCKER_BIN=/c/Users/tiago/AppData/Local/Programs/DockerDesktop/resources/bin
[ -d "$DOCKER_BIN" ] && export PATH="$DOCKER_BIN:$PATH"

carregar_env() {
    local chave valor
    while IFS='=' read -r chave valor || [ -n "$chave" ]; do
        valor=${valor%$'\r'}
        [[ "$chave" =~ ^[A-Z0-9_]+$ ]] || continue
        if [ -z "${!chave+x}" ]; then export "$chave=$valor"; fi
    done < "$1"
    return 0
}

if [ ! -f "$RAIZ/.env" ]; then
    cp "$RAIZ/.env.example" "$RAIZ/.env"
    echo "Criado .env a partir do .env.example" >&2
fi

RECURSOS=${RECURSOS:-4cpu}
[ -f "$RAIZ/recursos/$RECURSOS.env" ] || { echo "Perfil de recursos inexistente: recursos/$RECURSOS.env" >&2; exit 1; }
carregar_env "$RAIZ/recursos/$RECURSOS.env"
carregar_env "$RAIZ/.env"
export RECURSOS

ESCALA=${ESCALA:-0}
export ESCALA

ARQ=${1:-}
case "$ARQ" in
    monolito)
        APPS="monolito"
        ENTRADA="http://monolito:8080"
        BANCO_AUTH=ecommerce
        BANCO_PARTICIPANTE=ecommerce
        REPLICAS="monolito=${REPLICAS_MONOLITO:-1}"
        ;;
    microsservicos)
        APPS="api-gateway auth participante produto loja pedido pagamento"
        ENTRADA="http://api-gateway:8080"
        BANCO_AUTH=ecommerceauth
        BANCO_PARTICIPANTE=ecommerceparticipante
        REPLICAS="gateway=${REPLICAS_GATEWAY:-1} auth=${REPLICAS_AUTH:-1} participante=${REPLICAS_PARTICIPANTE:-1} produto=${REPLICAS_PRODUTO:-1} loja=${REPLICAS_LOJA:-1} pedido=${REPLICAS_PEDIDO:-1} pagamento=${REPLICAS_PAGAMENTO:-1}"
        ;;
    *)
        echo "Informe a arquitetura: monolito ou microsservicos" >&2
        exit 1
        ;;
esac

ARQUIVOS_COMPOSE=(-f "$RAIZ/compose.comum.yml" -f "$RAIZ/compose.$ARQ.yml")
if [ "$ESCALA" = "1" ]; then
    ARQUIVOS_COMPOSE+=(-f "$RAIZ/compose.escala.$ARQ.yml")
    ENTRADA="http://balanceador:8080"
else
    REPLICAS="sem balanceador"
fi

PROJETO="bench-$ARQ"
REDE="${PROJETO}_default"
BASE_URL="http://localhost:$PORTA"

compose() { docker compose -p "$PROJETO" "${ARQUIVOS_COMPOSE[@]}" "$@"; }
sql() { compose exec -T postgres psql -U postgres -d "$1" -tA -c "$2"; }
caminho_windows() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else echo "$1"; fi; }

CLIENTES=${CLIENTES:-100}
SENHA_CLIENTE=bench123
ADMIN_EMAIL=admin@bench.test
ADMIN_SENHA=admin123
