#!/bin/bash
# Derruba o ambiente e apaga os dados.
# Uso: bash scripts/descer.sh <monolito|microsservicos>

source "$(dirname "$0")/comum.sh" "$1"
compose down -v --remove-orphans
