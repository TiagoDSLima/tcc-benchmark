#!/bin/bash
# Cadastra a massa de dados usada nos testes: 1 admin, N clientes, 20 produtos com estoque alto
# e o token (falso) do Mercado Pago na loja, que é atendido pelo simulador.
# Uso: bash scripts/popular.sh <monolito|microsservicos>

source "$(dirname "$0")/comum.sh" "$1"

PRODUTOS=20
ESTOQUE=1000000
IMAGEM="../ecommerce-microservices/servicos/seed/produto.png"

campo() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }

cpf() {
    local base d1 d2 soma i
    base=$(printf "%09d" $((200000000 + $1)))
    soma=0; for i in 0 1 2 3 4 5 6 7 8; do soma=$((soma + ${base:$i:1} * (10 - i))); done
    d1=$(( (soma * 10) % 11 % 10 ))
    soma=0; for i in 0 1 2 3 4 5 6 7 8; do soma=$((soma + ${base:$i:1} * (11 - i))); done
    soma=$((soma + d1 * 2))
    d2=$(( (soma * 10) % 11 % 10 ))
    echo "$base$d1$d2"
}

registra() {
    curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/auth/register" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$1\",\"senha\":\"$2\",\"nome\":\"$3\",\"cpf\":\"$4\",\"dataNascimento\":\"1995-05-10\"}"
}

login() {
    curl -s -X POST "$BASE_URL/auth/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"$1\",\"senha\":\"$2\"}" | campo token
}

echo "==> Usuários"
registra "$ADMIN_EMAIL" "$ADMIN_SENHA" "Administrador" "11144477735" > /dev/null
sql "$BANCO_AUTH" "UPDATE usuario SET role = 'ROLE_ADMIN' WHERE email = '$ADMIN_EMAIL';" > /dev/null
ADMIN_TOKEN=$(login "$ADMIN_EMAIL" "$ADMIN_SENHA")
[ -n "$ADMIN_TOKEN" ] || { echo "Falha no login do admin" >&2; exit 1; }

falhas=0
for i in $(seq 1 "$CLIENTES"); do
    codigo=$(registra "cliente$i@bench.test" "$SENHA_CLIENTE" "Cliente $i" "$(cpf "$i")")
    [ "$codigo" = "201" ] || [ "$codigo" = "200" ] || falhas=$((falhas + 1))
done
echo "    $CLIENTES clientes cadastrados ($falhas já existiam ou falharam)"

echo "==> Produtos"
if [ "$(curl -s "$BASE_URL/produto/buscaTodos")" = "[]" ]; then
    criados=0
    for i in $(seq 1 "$PRODUTOS"); do
        extra=()
        quantidade=$ESTOQUE
        if [ $((i % 5)) -eq 0 ]; then
            extra=(-F "variacoes[0].tamanho=P" -F "variacoes[0].cor=Preta" -F "variacoes[0].quantidade=$ESTOQUE"
                   -F "variacoes[1].tamanho=M" -F "variacoes[1].cor=Preta" -F "variacoes[1].quantidade=$ESTOQUE"
                   -F "variacoes[2].tamanho=G" -F "variacoes[2].cor=Branca" -F "variacoes[2].quantidade=$ESTOQUE")
            quantidade=$((3 * ESTOQUE))
        fi
        codigo=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/produto" -H "Authorization: Bearer $ADMIN_TOKEN" \
            -F "descricao=Produto $i" -F "valorUnitario=$((10 + i)).90" -F "quantidade=$quantidade" \
            -F "imagem=@$IMAGEM;type=image/png" "${extra[@]}")
        if [ "$codigo" = "201" ] || [ "$codigo" = "200" ]; then
            criados=$((criados + 1))
        else
            echo "    produto $i: HTTP $codigo" >&2
        fi
    done
    echo "    $criados de $PRODUTOS produtos cadastrados"
    [ "$criados" = "$PRODUTOS" ] || exit 1
else
    echo "    produtos já cadastrados"
fi

echo "==> Token do Mercado Pago (simulador)"
curl -s -o /dev/null -w "    HTTP %{http_code}\n" -X PUT "$BASE_URL/loja/mercadopago-token" -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H 'Content-Type: application/json' -d '{"token":"TEST-benchmark-simulador"}'

echo "==> Participantes"
esperado=$((CLIENTES + 1))
for _ in $(seq 1 60); do
    total=$(sql "$BANCO_PARTICIPANTE" "SELECT count(*) FROM participante;")
    [ "$total" -ge "$esperado" ] && break
    sleep 1
done
echo "    $total participantes (esperado $esperado)"
[ "$total" -ge "$esperado" ] || { echo "Participantes não foram criados" >&2; exit 1; }
echo "Pronto."
