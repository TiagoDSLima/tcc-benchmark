import http from 'k6/http';
import { check, fail } from 'k6';
import exec from 'k6/execution';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:18080';
const CLIENTES = parseInt(__ENV.CLIENTES || '100');
const SENHA_CLIENTE = 'bench123';

export const ESTATISTICAS = ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'];

export const ENDPOINTS_CATALOGO = ['GET /produto/buscaTodosComEstoque', 'GET /produto/busca/{id}', 'GET /loja'];
export const ENDPOINTS_COMPRA = ['POST /pedido', 'POST /webhook/mercadopago'];

const PERFIL = __ENV.PERFIL || 'fumaca';
const PASSOS = parseInt(__ENV.PASSOS || '8');
const RAMPA_MS = 10000;

function milissegundos(duracao) {
    const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)$/.exec(duracao);
    if (!m) {
        fail(`Duração inválida: ${duracao}`);
    }
    return parseFloat(m[1]) * { ms: 1, s: 1000, m: 60000, h: 3600000 }[m[2]];
}

const PASSO_MS = milissegundos(__ENV.DURACAO_PASSO || '1m');

export function marcarDegrau() {
    if (PERFIL !== 'estresse') {
        return;
    }
    const decorrido = Date.now() - exec.scenario.startTime;
    const bloco = RAMPA_MS + PASSO_MS;
    const indice = Math.floor(decorrido / bloco);
    const degrau = decorrido - indice * bloco < RAMPA_MS ? 'transicao' : String(Math.min(indice + 1, PASSOS));
    exec.vu.metrics.tags.degrau = degrau;
}

export function metricasSeparadas(cenarios, endpoints) {
    const limites = {};
    for (const c of cenarios) {
        limites[`http_req_duration{scenario:${c}}`] = ['max>=0'];
        limites[`http_req_failed{scenario:${c}}`] = ['rate>=0'];
        limites[`http_reqs{scenario:${c}}`] = ['count>=0'];
        limites[`iterations{scenario:${c}}`] = ['count>=0'];
        limites[`iteration_duration{scenario:${c}}`] = ['max>=0'];
    }
    for (const e of endpoints) {
        limites[`http_req_duration{name:${e}}`] = ['max>=0'];
        limites[`http_req_failed{name:${e}}`] = ['rate>=0'];
        limites[`http_reqs{name:${e}}`] = ['count>=0'];
    }
    if (PERFIL === 'estresse') {
        for (let i = 1; i <= PASSOS; i++) {
            limites[`http_req_duration{degrau:${i}}`] = ['max>=0'];
            limites[`http_req_failed{degrau:${i}}`] = ['rate>=0'];
            limites[`http_reqs{degrau:${i}}`] = ['count>=0'];
            limites[`iterations{degrau:${i}}`] = ['count>=0'];
            for (const c of cenarios) {
                limites[`http_req_duration{scenario:${c},degrau:${i}}`] = ['max>=0'];
                limites[`http_req_failed{scenario:${c},degrau:${i}}`] = ['rate>=0'];
                limites[`iterations{scenario:${c},degrau:${i}}`] = ['count>=0'];
            }
        }
    }
    return limites;
}

export function cenario(exec, pesoTaxa = 1) {
    const perfil = PERFIL;
    const taxa = Math.max(1, Math.round(parseFloat(__ENV.TAXA || '50') * pesoTaxa));
    const duracao = __ENV.DURACAO || '3m';
    const vusMax = parseInt(__ENV.VUS_MAX || '500');

    if (perfil === 'fumaca') {
        return { executor: 'per-vu-iterations', vus: 1, iterations: 5, exec };
    }
    if (perfil === 'aquecimento') {
        return {
            executor: 'constant-arrival-rate', exec, rate: Math.max(1, Math.round(taxa / 2)), timeUnit: '1s',
            duration: __ENV.DURACAO_AQUECIMENTO || '1m', preAllocatedVUs: 20, maxVUs: vusMax,
        };
    }
    if (perfil === 'carga') {
        return {
            executor: 'constant-arrival-rate', exec, rate: taxa, timeUnit: '1s', duration: duracao,
            preAllocatedVUs: Math.min(vusMax, Math.max(10, taxa)), maxVUs: vusMax,
        };
    }
    if (perfil === 'estresse') {
        const stages = [];
        for (let i = 1; i <= PASSOS; i++) {
            const alvo = Math.max(1, Math.round((taxa * i) / PASSOS));
            stages.push({ target: alvo, duration: `${RAMPA_MS}ms` });
            stages.push({ target: alvo, duration: `${PASSO_MS}ms` });
        }
        return {
            executor: 'ramping-arrival-rate', exec, startRate: 1, timeUnit: '1s', stages,
            preAllocatedVUs: 50, maxVUs: vusMax,
        };
    }
    fail(`Perfil desconhecido: ${perfil}`);
}

export function login(email, senha) {
    const res = http.post(`${BASE_URL}/auth/login`, JSON.stringify({ email, senha }), {
        headers: { 'Content-Type': 'application/json' },
        tags: { name: 'POST /auth/login' },
    });
    if (res.status !== 200) {
        fail(`Login de ${email} falhou: HTTP ${res.status}`);
    }
    return res.json('token');
}

export function prepararDados(precisaClientes) {
    const res = http.get(`${BASE_URL}/produto/buscaTodosComEstoque`);
    if (res.status !== 200 || res.json().length === 0) {
        fail('Nenhum produto cadastrado: rode scripts/popular.sh antes');
    }
    const produtos = res.json().map((p) => ({
        id: p.id,
        variacoes: (p.variacoes || []).map((v) => v.id),
    }));

    const clientes = [];
    if (precisaClientes) {
        for (let i = 1; i <= CLIENTES; i++) {
            const email = `cliente${i}@bench.test`;
            clientes.push({ email, token: login(email, SENHA_CLIENTE) });
        }
    }
    return { produtos, clientes };
}

export function aleatorio(lista) {
    return lista[Math.floor(Math.random() * lista.length)];
}

export function verificar(res, nome, status) {
    return check(res, { [`${nome} -> ${status}`]: (r) => r.status === status });
}

export function resumo(data) {
    const saida = { stdout: textSummary(data, { indent: ' ', enableColors: false }) };
    if (__ENV.SAIDA) {
        saida[__ENV.SAIDA] = JSON.stringify(data, null, 2);
    }
    return saida;
}
