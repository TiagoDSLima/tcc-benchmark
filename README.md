# Ambiente de testes comparativos

Este ambiente sobe, um de cada vez, o monólito (`../ecommerce-monolith`) ou os microsserviços
(`../ecommerce-microservices`) em containers com limites de recursos. Depois, gera carga com o k6 e
registra a latência, a vazão, a taxa de erro e o uso de CPU e memória de cada container.

## Pré-requisitos

- Docker Desktop. Testado com 12 CPUs e 15 GB disponíveis para o Docker.
- Bash (Git Bash no Windows).
- As pastas `ecommerce-monolith` e `ecommerce-microservices` ao lado desta.
- Os ambientes de desenvolvimento parados durante as medições. Eles disputariam CPU com o teste.

As configurações ficam no `.env`, que não vai para o git. Na primeira execução, os scripts criam o
`.env` a partir do `.env.example`, que já traz os valores usados no trabalho.

## Fluxo das medições

```bash
bash scripts/lote.sh planos/calibracao.txt 1   # 1) encontra o ponto de saturação (cerca de 1 h 20 min)
bash scripts/consolidar.sh                     #    e gera as tabelas para escolher as taxas
# 2) ajuste as taxas em planos/desempenho.txt e planos/escalabilidade.txt
bash scripts/lote.sh planos/desempenho.txt     # 3) 5 repetições (cerca de 13 h)
bash scripts/lote.sh planos/escalabilidade.txt # 4) 5 repetições (cerca de 8 h)
bash scripts/consolidar.sh                     # 5) tabelas finais em resultados/consolidado/
bash scripts/imagens.sh                        #    tamanho das imagens
```

O `lote.sh` recria o ambiente do zero a cada execução (`subir.sh`, `executar.sh`, `descer.sh`) e
alterna a ordem das arquiteturas entre as repetições. Ele não deixa dois lotes rodarem ao mesmo
tempo. O andamento fica em `resultados/lote-<data>-<plano>.log`. Se uma execução falhar, o lote
registra a falha e segue para a próxima.

### Formato dos planos

Cada linha é `<cenário> <perfil> [VARIAVEL=valor ...]`, por exemplo:

```text
misto carga TAXA=150
misto estresse TAXA=400 VUS_MAX=1000 DURACAO_PASSO=30s RECURSOS=8cpu
misto estresse TAXA=600 ESCALA=1 ARQ=microsservicos REPLICAS_PRODUTO=2 REPLICAS_PEDIDO=2
repouso repouso DURACAO=2m
```

`ARQ=` restringe a linha a uma arquitetura, e `REPETICOES=n` limita a linha às n primeiras repetições.

## Execução manual

```bash
bash scripts/subir.sh monolito            # sobe do zero, mede a inicialização e popula os dados
bash scripts/executar.sh monolito misto   # aquece a JVM por 1 min e mede 3 min a 50 iterações/s
bash scripts/descer.sh monolito
```

As variáveis de recursos e de escala precisam ser as mesmas no `subir.sh` e no `executar.sh`:

```bash
ESCALA=1 REPLICAS_MONOLITO=2 bash scripts/subir.sh monolito
ESCALA=1 REPLICAS_MONOLITO=2 TAXA=200 bash scripts/executar.sh monolito misto estresse
```

| Variável | Padrão | Significado |
|---|---|---|
| `TAXA` | 50 | iterações por segundo (no perfil `estresse`, a taxa do último degrau) |
| `DURACAO` | 3m | duração da medição no perfil `carga` e no cenário `repouso` |
| `PASSOS` / `DURACAO_PASSO` | 8 / 1m | degraus do perfil `estresse` (cada um com 10 s de transição) |
| `AQUECER` / `DURACAO_AQUECIMENTO` | 1 / 1m | aquecimento da JVM antes de medir (não entra no resultado) |
| `VUS_MAX` | 500 | limite de usuários virtuais do k6 |
| `RECURSOS` | 4cpu | perfil de CPUs da camada de aplicação (`recursos/2cpu.env`, `4cpu.env`, `8cpu.env`) |
| `ESCALA` | 0 | `1` coloca o balanceador nginx na frente das aplicações |
| `REPLICAS_<SERVIÇO>` | 1 | réplicas com `ESCALA=1`: `MONOLITO`, `GATEWAY`, `AUTH`, `PARTICIPANTE`, `PRODUTO`, `LOJA`, `PEDIDO`, `PAGAMENTO` |
| `REPETICAO` | 1 | rótulo da rodada (o `lote.sh` preenche sozinho) |

Qualquer valor do `.env` também pode ser sobrescrito na linha de comando.

## Cenários (pasta `k6/`)

| Cenário | Cada iteração faz |
|---|---|
| `catalogo` | lista os produtos com estoque, detalha um produto e busca a configuração da loja (sem login) |
| `compra` | cria um pedido com 2 itens pago com PIX e envia a notificação de pagamento aprovado (webhook) |
| `misto` | 80% das iterações de `catalogo` e 20% de `compra`, executados em paralelo |
| `repouso` | não gera carga: mede CPU e memória com as aplicações no ar e paradas |

## Perfis

| Perfil | Comportamento |
|---|---|
| `fumaca` | 1 usuário virtual faz 5 iterações. Serve só para conferir se tudo responde (não entra na consolidação). |
| `carga` | mantém uma taxa constante de iterações (modelo aberto) durante `DURACAO`. |
| `estresse` | sobe a taxa em degraus até `TAXA`. Cada iteração recebe a etiqueta do degrau, e o resultado traz latência, erros e vazão de cada degrau. |

## Resultados (pasta `resultados/`)

Cada execução cria uma pasta `<data>_<arquitetura>_<cenário>_<perfil>_<recursos>_e<escala>_r<repetição>` com:

| Arquivo | Conteúdo |
|---|---|
| `k6.json` | resumo completo do k6, separado por cenário, por rota e, no estresse, por degrau |
| `k6.log` | saída do k6 |
| `recursos.csv` | CPU e memória de cada container, amostrados durante a medição (`docker stats`) |
| `ambiente.txt` | configuração da execução, commits dos dois repositórios, limites usados e recursos da máquina |
| `aplicacoes.log` | logs dos containers |

`resultados/inicializacao.csv` acumula os tempos de inicialização de cada `subir.sh`.

### Consolidação

O `consolidar.sh` lê todas as execuções e gera em `resultados/consolidado/`, com `;` como separador
e vírgula decimal, prontos para abrir no Excel:

| Arquivo | Conteúdo |
|---|---|
| `metricas_execucoes.csv` | cada métrica de cada execução |
| `resumo.csv` | por configuração: número de repetições, média, desvio padrão, coeficiente de variação e intervalo de confiança de 95% (t de Student) |
| `comparacao.csv` | monólito × microsserviços na mesma configuração: médias, intervalos, diferença percentual e se a diferença é significativa (intervalos sem sobreposição) |
| `inicializacao_resumo.csv` | tempos de inicialização por arquitetura e aplicação |

As métricas incluem:
- latência média, mediana, p90, p95, p99 e máxima;
- taxa de erros, requisições e vazão;
- iterações descartadas pelo k6;
- CPU (em núcleos) e memória de cada serviço, da camada de aplicação e do total.

No estresse, a **vazão máxima sustentada** é o último degrau em que o p95 ficou abaixo de 1 s e os
erros abaixo de 1%.

## Decisões do ambiente

### Mesmo orçamento de recursos

A camada de aplicação tem 4 CPUs e 4 GB nas duas arquiteturas (ver `.env`):
- **Monólito:** recebe tudo em um único container.
- **Microsserviços:** dividem o orçamento entre os 7 serviços.
- **Infraestrutura:** PostgreSQL, MinIO e o simulador têm os mesmos limites nas duas. Kafka e
  Zookeeper só existem nos microsserviços e têm limites próprios.

### Escalabilidade vertical

`RECURSOS=2cpu` e `RECURSOS=8cpu` mudam só as CPUs da camada de aplicação, na mesma proporção entre
os serviços. A memória fica em 4 GB, porque reduzi-la proporcionalmente deixaria cada microsserviço
com 256 MB, abaixo do mínimo para uma aplicação Spring Boot.

Com 8 CPUs na aplicação, a soma dos limites passa das 12 CPUs da máquina. Os limites são tetos e não
reservas, mas pode haver disputa com a infraestrutura nos degraus mais altos.

### Escalabilidade horizontal

Com `ESCALA=1`, um nginx (`balanceador/`) fica na frente das aplicações e distribui as requisições
entre as réplicas:
- **Monólito:** o k6 chama o nginx, que repassa para as réplicas do monólito.
- **Microsserviços:** o nginx tem uma porta por serviço (8080 a 8086). O gateway, o pedido e o
  pagamento passam a chamar os outros serviços pelo nginx.

O nginx descobre as réplicas pelo DNS do Docker quando sobe. A execução com `ESCALA=1` e 1 réplica é
a referência para calcular o ganho, porque também passa pelo balanceador.

Os consumidores Kafka replicados ficam no mesmo grupo. Como os tópicos têm uma partição, só uma
réplica consome as mensagens. A parte assíncrona não está no caminho das requisições medidas.

### Mesma JVM e mesma imagem base

Todas as aplicações usam o mesmo `Dockerfile` (`eclipse-temurin:21.0.5_11-jre`), o Spring Boot
3.5.13 e a opção `-XX:MaxRAMPercentage=60`. O log de SQL (`show-sql`) fica desligado nas duas versões.

### Bancos zerados

Cada `subir.sh` recria os bancos e cadastra a mesma massa de dados:
- 1 administrador;
- 100 clientes;
- 20 produtos com estoque de 1.000.000 (4 deles com 3 variações);
- o token do Mercado Pago na loja.

### Simulador do Mercado Pago

O WireMock atende como `api.mercadopago.com` dentro da rede do Docker, com um certificado próprio
confiado apenas pelos containers. O código de pagamento é o mesmo de produção:
- **Atraso fixo:** 100 ms em cada chamada, simulando uma API externa.
- **PIX:** o pagamento é criado como pendente, com QR Code.
- **Cartão:** o pagamento é aprovado na criação.
- **Consulta:** sempre retorna aprovado.
- **Id do pagamento:** igual ao id do pedido.

O certificado de teste foi gerado com o `keytool` e está em `mercadopago-stub/certs`. A senha é `benchmark`.

### Aquecimento

Antes de cada medição, o k6 roda 1 minuto com metade da taxa. Isso evita medir a JVM antes da
compilação JIT.

### Gerador de carga isolado

O k6 roda em um container com 2 CPUs na mesma rede das aplicações. As requisições não passam pela
porta publicada do Windows.

## Cuidados ao comparar

- Não rode as duas arquiteturas ao mesmo tempo nem dois lotes em paralelo.
- Para interromper um lote, encerre também os processos filhos (`subir.sh`, `executar.sh`) e rode
  `scripts/descer.sh` nas duas arquiteturas.
- O tamanho das imagens inclui as camadas da imagem base, que são compartilhadas entre os
  serviços no disco.
