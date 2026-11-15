#!/bin/bash
# Executa um plano de testes inteiro, sem acompanhamento.
# Uso: bash scripts/lote.sh <planos/arquivo.txt> [repetições, padrão 5]
#
# Cada linha do plano tem: <cenário> <perfil> [VARIAVEL=valor ...]
# Exemplos de variáveis: TAXA, DURACAO, PASSOS, DURACAO_PASSO, VUS_MAX, RECURSOS, ESCALA, REPLICAS_<SERVIÇO>.
# ARQ=monolito ou ARQ=microsservicos restringe a linha a uma arquitetura.
# REPETICOES=n limita aquela linha às n primeiras repetições.
#
# Cada execução recria o ambiente do zero (subir, executar, descer). Nas repetições ímpares o monólito
# roda primeiro; nas pares, os microsserviços, para que variações da máquina afetem as duas igualmente.

set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RAIZ"

PLANO=${1:?Informe o plano, por exemplo planos/calibracao.txt}
TOTAL_REPETICOES=${2:-5}
[ -f "$PLANO" ] || { echo "Plano inexistente: $PLANO" >&2; exit 1; }

mkdir -p resultados
TRAVA=resultados/.lote.pid
if [ -f "$TRAVA" ] && kill -0 "$(cat "$TRAVA")" 2>/dev/null; then
    echo "Já existe um lote em execução (processo $(cat "$TRAVA")). Encerre-o antes de iniciar outro." >&2
    exit 1
fi
echo $$ > "$TRAVA"
trap 'rm -f "$TRAVA"' EXIT
LOG="resultados/lote-$(date +%Y%m%d-%H%M%S)-$(basename "$PLANO" .txt).log"
falhas=0
execucoes=0

registrar() { echo "[$(date '+%d/%m %H:%M:%S')] $*" | tee -a "$LOG"; }

linhas=()
while IFS= read -r linha || [ -n "$linha" ]; do
    linha=${linha%$'\r'}
    linha=${linha%%#*}
    [ -n "${linha// }" ] && linhas+=("$linha")
done < "$PLANO"

registrar "Plano $PLANO: ${#linhas[@]} linha(s), $TOTAL_REPETICOES repetição(ões)"

for repeticao in $(seq 1 "$TOTAL_REPETICOES"); do
    if [ $((repeticao % 2)) -eq 1 ]; then ordem="monolito microsservicos"; else ordem="microsservicos monolito"; fi

    for linha in "${linhas[@]}"; do
        read -r -a partes <<< "$linha"
        cenario=${partes[0]}
        perfil=${partes[1]}
        variaveis=("${partes[@]:2}")

        so_arq=""
        limite=$TOTAL_REPETICOES
        for v in "${variaveis[@]}"; do
            case "$v" in
                ARQ=*) so_arq=${v#ARQ=} ;;
                REPETICOES=*) limite=${v#REPETICOES=} ;;
            esac
        done
        [ "$repeticao" -le "$limite" ] || continue

        for arq in $ordem; do
            [ -z "$so_arq" ] || [ "$so_arq" = "$arq" ] || continue
            execucoes=$((execucoes + 1))
            registrar "Repetição $repeticao: $arq $cenario $perfil ${variaveis[*]}"
            if env "${variaveis[@]}" REPETICAO="$repeticao" bash scripts/subir.sh "$arq" >> "$LOG" 2>&1 \
                && env "${variaveis[@]}" REPETICAO="$repeticao" bash scripts/executar.sh "$arq" "$cenario" "$perfil" >> "$LOG" 2>&1; then
                registrar "    concluída"
            else
                falhas=$((falhas + 1))
                registrar "    FALHOU (detalhes em $LOG)"
            fi
            env "${variaveis[@]}" bash scripts/descer.sh "$arq" >> "$LOG" 2>&1 || true
        done
    done
done

registrar "Fim: $execucoes execução(ões), $falhas falha(s)"
[ "$falhas" -eq 0 ]
