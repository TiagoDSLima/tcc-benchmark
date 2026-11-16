#!/bin/bash
# Coleta as métricas de código das duas versões: métricas CK (CBO, WMC, LCOM, RFC, LOC) por classe,
# tamanho do código, testes, dependências, arquivos de configuração e código de comunicação.
# Uso: bash scripts/metricas-codigo.sh
# Na primeira execução baixa o CK 0.7.0 do Maven Central para ferramentas/.

source "$(dirname "$0")/comum.sh" monolito

MS=../ecommerce-microservices
MONO=../ecommerce-monolith
SERVICOS="api-gateway auth participante produto loja pedido pagamento"
SAIDA=resultados/codigo
mkdir -p "$SAIDA/ck" ferramentas

CK=ferramentas/ck-0.7.0-jar-with-dependencies.jar
if [ ! -f "$CK" ]; then
    echo "==> Baixando o CK 0.7.0 (Maven Central)"
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(caminho_windows "$RAIZ/ferramentas"):/f" maven:3.9.9-eclipse-temurin-21 \
        mvn -q dependency:copy -Dartifact=com.github.mauricioaniche:ck:0.7.0:jar:jar-with-dependencies -DoutputDirectory=/f
fi

ck() { # nome caminho-relativo-a-IdeaProjects
    mkdir -p "$SAIDA/ck/$1"
    MSYS_NO_PATHCONV=1 docker run --rm \
        -v "$(caminho_windows "$RAIZ/ferramentas"):/f:ro" \
        -v "$(caminho_windows "$(cd "$RAIZ/.." && pwd)"):/projetos:ro" \
        -v "$(caminho_windows "$RAIZ/$SAIDA/ck/$1"):/saida" \
        eclipse-temurin:21.0.5_11-jre java -jar /f/$(basename "$CK") "/projetos/$2" false 0 false /saida/ > /dev/null
}

echo "==> CK"
ck monolito ecommerce-monolith/src/main/java
for s in $SERVICOS; do ck "$s" "ecommerce-microservices/$s/src/main/java"; done

linhas() { # conta linhas não vazias
    [ $# -eq 0 ] && { echo 0; return; }
    cat "$@" 2>/dev/null | grep -cvE '^\s*$' || true
}

echo "==> Contagens dos repositórios"
saida="$SAIDA/repositorios.csv"
echo "arquitetura;projeto;arquivos_java_main;linhas_java_main;arquivos_java_teste;linhas_java_teste;testes;dependencias_pom;arquivos_configuracao;linhas_configuracao;arquivos_comunicacao;linhas_comunicacao" > "$saida"

contar() { # arquitetura projeto diretório
    local dir=$3
    mapfile -t main < <(find "$dir/src/main/java" -name '*.java' 2>/dev/null)
    mapfile -t teste < <(find "$dir/src/test/java" -name '*.java' 2>/dev/null)
    mapfile -t config < <(find "$dir" -maxdepth 1 \( -name pom.xml -o -name Dockerfile -o -name .dockerignore \) 2>/dev/null; \
                          find "$dir/src/main/resources" -maxdepth 1 -name 'application*' 2>/dev/null)
    mapfile -t comunicacao < <(printf '%s\n' "${main[@]}" | grep -E '/(client|publisher|subscriber|representation)/|(Kafka|Feign|ServiceToken|Clients)[A-Za-z]*\.java$|Event\.java$' ; \
                               grep -lE '@(EventListener|TransactionalEventListener|KafkaListener|FeignClient)|KafkaTemplate|ApplicationEventPublisher' "${main[@]}" 2>/dev/null)
    mapfile -t comunicacao < <(printf '%s\n' "${comunicacao[@]}" | grep -v '^$' | sort -u)
    local testes
    testes=$(cat "${teste[@]}" 2>/dev/null | grep -cE '@(Test|ParameterizedTest)\b' || true)
    local deps
    deps=$(grep -c '<dependency>' "$dir/pom.xml")
    echo "$1;$2;${#main[@]};$(linhas "${main[@]}");${#teste[@]};$(linhas "${teste[@]}");$testes;$deps;${#config[@]};$(linhas "${config[@]}");${#comunicacao[@]};$(linhas "${comunicacao[@]}")" >> "$saida"
}

contar monolito monolito "$MONO"
for s in $SERVICOS; do contar microsservicos "$s" "$MS/$s"; done

echo "==> Arquivos de implantação"
{
    echo "arquitetura;arquivo;linhas"
    for f in compose.comum.yml compose.monolito.yml compose.escala.monolito.yml balanceador/monolito.conf; do
        echo "monolito;$f;$(linhas "$f")"
    done
    for f in compose.comum.yml compose.microsservicos.yml compose.escala.microsservicos.yml balanceador/microsservicos.conf; do
        echo "microsservicos;$f;$(linhas "$f")"
    done
    echo "monolito;infra/schema.sql;$(linhas "$MONO/infra/schema.sql")"
    echo "microsservicos;servicos/database/schema.sql;$(linhas "$MS/servicos/database/schema.sql")"
} > "$SAIDA/implantacao.csv"

echo "==> Consolidando"
MSYS_NO_PATHCONV=1 docker run --rm -v "$(caminho_windows "$RAIZ"):/dados" node:22.11.0-alpine \
    node /dados/scripts/metricas-codigo.js /dados/$SAIDA
