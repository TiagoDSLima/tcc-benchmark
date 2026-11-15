'use strict';

const fs = require('fs');
const path = require('path');

const RESULTADOS = process.argv[2] || '/dados/resultados';
const SAIDA = path.join(RESULTADOS, 'consolidado');
const INFRA = new Set(['postgres', 'minio', 'mercadopago', 'kafka', 'zookeeper', 'balanceador']);
const LIMITE_P95_MS = 1000;
const LIMITE_ERROS = 0.01;
const T_95 = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.16, 2.145,
    2.131, 2.12, 2.11, 2.101, 2.093, 2.086, 2.08, 2.074, 2.069, 2.064, 2.06, 2.056, 2.052, 2.048, 2.045, 2.042];
const CHAVE = ['arquitetura', 'cenario', 'perfil', 'taxa', 'duracao', 'passos', 'duracao_passo', 'recursos', 'escala', 'replicas'];

function lerAmbiente(arquivo) {
    const cfg = {};
    for (const linha of fs.readFileSync(arquivo, 'utf8').split(/\r?\n/)) {
        const i = linha.indexOf('=');
        if (i > 0) cfg[linha.slice(0, i)] = linha.slice(i + 1);
    }
    return cfg;
}

function segundos(duracao) {
    const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)$/.exec(duracao || '');
    if (!m) return NaN;
    return parseFloat(m[1]) * { ms: 0.001, s: 1, m: 60, h: 3600 }[m[2]];
}

function separarMetrica(chave) {
    const i = chave.indexOf('{');
    if (i < 0) return { base: chave, grupo: 'geral', tags: {} };
    const base = chave.slice(0, i);
    const tags = {};
    for (const parte of chave.slice(i + 1, chave.lastIndexOf('}')).split(',')) {
        const j = parte.indexOf(':');
        tags[parte.slice(0, j)] = parte.slice(j + 1);
    }
    const nomes = { scenario: 'cenario', name: 'rota', degrau: 'degrau' };
    const grupo = Object.entries(tags).map(([k, v]) => `${nomes[k] || k}=${v}`).join(' | ');
    return { base, grupo, tags };
}

function metricasK6(k6, cfg) {
    const linhas = [];
    const duracaoCarga = segundos(cfg.duracao);
    const passo = segundos(cfg.duracao_passo);
    const passos = parseInt(cfg.passos || '8');
    const duracaoEstresse = passos * (passo + 10);
    const add = (grupo, metrica, valor) => {
        if (valor !== undefined && valor !== null && !Number.isNaN(valor)) linhas.push({ grupo, metrica, valor });
    };

    for (const [chave, dados] of Object.entries(k6.metrics)) {
        const { base, grupo, tags } = separarMetrica(chave);
        if (grupo === 'geral' && base !== 'dropped_iterations') continue;
        const v = dados.values || {};
        const duracao = cfg.perfil === 'carga' ? duracaoCarga : (tags.degrau ? passo : duracaoEstresse);
        if (base === 'http_req_duration') {
            add(grupo, 'latencia_media_ms', v.avg);
            add(grupo, 'latencia_mediana_ms', v.med);
            add(grupo, 'latencia_p90_ms', v['p(90)']);
            add(grupo, 'latencia_p95_ms', v['p(95)']);
            add(grupo, 'latencia_p99_ms', v['p(99)']);
            add(grupo, 'latencia_max_ms', v.max);
        } else if (base === 'http_req_failed') {
            add(grupo, 'taxa_erros_percentual', v.rate * 100);
        } else if (base === 'http_reqs') {
            add(grupo, 'requisicoes', v.count);
            add(grupo, 'vazao_req_s', v.count / duracao);
        } else if (base === 'iterations') {
            add(grupo, 'iteracoes', v.count);
            add(grupo, 'vazao_iteracoes_s', v.count / duracao);
        } else if (base === 'iteration_duration') {
            add(grupo, 'duracao_iteracao_media_ms', v.avg);
            add(grupo, 'duracao_iteracao_p95_ms', v['p(95)']);
        } else if (base === 'dropped_iterations') {
            add('geral', 'iteracoes_descartadas', v.count);
        }
    }

    if (cfg.perfil === 'estresse') {
        const taxa = parseFloat(cfg.taxa);
        let limite = 0;
        let atingida = 0;
        for (let i = 1; i <= passos; i++) {
            const lat = k6.metrics[`http_req_duration{degrau:${i}}`];
            const err = k6.metrics[`http_req_failed{degrau:${i}}`];
            const it = k6.metrics[`iterations{degrau:${i}}`];
            const ok = lat && err && it && lat.values['p(95)'] < LIMITE_P95_MS && err.values.rate < LIMITE_ERROS;
            if (!ok) break;
            limite = i;
            atingida = it.values.count / passo;
        }
        add('geral', 'degrau_limite', limite);
        add('geral', 'vazao_maxima_sustentada_alvo_it_s', limite ? Math.round((taxa * limite) / passos) : 0);
        add('geral', 'vazao_maxima_sustentada_medida_it_s', atingida);
    }
    return linhas;
}

function mebibytes(texto) {
    const m = /^([\d.]+)\s*([KMGT]?i?B)$/.exec(texto.trim());
    if (!m) return NaN;
    const fator = { B: 1 / 1048576, KiB: 1 / 1024, KB: 1 / 1024, MiB: 1, MB: 1, GiB: 1024, GB: 1024, TiB: 1048576 }[m[2]];
    return parseFloat(m[1]) * fator;
}

function metricasRecursos(arquivo, cfg) {
    const prefixo = `bench-${cfg.arquitetura}-`;
    const porMomento = new Map();
    const linhasCsv = fs.readFileSync(arquivo, 'utf8').split(/\r?\n/).slice(1).filter(Boolean);
    for (const linha of linhasCsv) {
        const [momento, container, cpu, memoria] = linha.split(';');
        if (!container || !container.startsWith(prefixo)) continue;
        const servico = container.slice(prefixo.length).replace(/-\d+$/, '');
        const nucleos = parseFloat(cpu) / 100;
        const mb = mebibytes(memoria);
        if (Number.isNaN(nucleos) || Number.isNaN(mb)) continue;
        if (!porMomento.has(momento)) porMomento.set(momento, {});
        const amostra = porMomento.get(momento);
        const atual = amostra[servico] || { cpu: 0, mem: 0 };
        amostra[servico] = { cpu: atual.cpu + nucleos, mem: atual.mem + mb };
    }

    const series = {};
    const acumular = (grupo, cpu, mem) => {
        if (!series[grupo]) series[grupo] = { cpu: [], mem: [] };
        series[grupo].cpu.push(cpu);
        series[grupo].mem.push(mem);
    };
    for (const amostra of porMomento.values()) {
        let appCpu = 0, appMem = 0, totCpu = 0, totMem = 0;
        for (const [servico, { cpu, mem }] of Object.entries(amostra)) {
            acumular(`recursos=${servico}`, cpu, mem);
            totCpu += cpu; totMem += mem;
            if (!INFRA.has(servico)) { appCpu += cpu; appMem += mem; }
        }
        acumular('recursos=aplicacao', appCpu, appMem);
        acumular('recursos=total', totCpu, totMem);
    }

    const linhas = [];
    for (const [grupo, { cpu, mem }] of Object.entries(series)) {
        linhas.push({ grupo, metrica: 'cpu_media_nucleos', valor: media(cpu) });
        linhas.push({ grupo, metrica: 'cpu_max_nucleos', valor: Math.max(...cpu) });
        linhas.push({ grupo, metrica: 'memoria_media_mb', valor: media(mem) });
        linhas.push({ grupo, metrica: 'memoria_max_mb', valor: Math.max(...mem) });
        linhas.push({ grupo, metrica: 'amostras', valor: cpu.length });
    }
    return linhas;
}

function media(valores) {
    return valores.reduce((a, b) => a + b, 0) / valores.length;
}

function estatisticas(valores) {
    const n = valores.length;
    const m = media(valores);
    const dp = n > 1 ? Math.sqrt(valores.reduce((a, v) => a + (v - m) ** 2, 0) / (n - 1)) : 0;
    const t = n > 1 ? (T_95[n - 2] || 1.96) : 0;
    const margem = n > 1 ? (t * dp) / Math.sqrt(n) : 0;
    return { n, media: m, desvio: dp, cv: m !== 0 ? (dp / m) * 100 : 0, ic_inf: m - margem, ic_sup: m + margem };
}

function numero(v) {
    if (typeof v !== 'number') return v ?? '';
    return Number.isInteger(v) ? String(v) : v.toFixed(3).replace('.', ',');
}

function escreverCsv(arquivo, colunas, linhas) {
    const conteudo = [colunas.join(';'), ...linhas.map((l) => colunas.map((c) => numero(l[c])).join(';'))].join('\n');
    fs.writeFileSync(path.join(SAIDA, arquivo), '﻿' + conteudo + '\n');
}

function variante(replicas) {
    return /=([2-9]|\d{2,})/.test(replicas || '') ? 'escalado' : 'referencia';
}

function main() {
    fs.mkdirSync(SAIDA, { recursive: true });
    const execucoes = [];
    for (const nome of fs.readdirSync(RESULTADOS).sort()) {
        const pasta = path.join(RESULTADOS, nome);
        const ambiente = path.join(pasta, 'ambiente.txt');
        if (!fs.statSync(pasta).isDirectory() || !fs.existsSync(ambiente)) continue;
        const cfg = lerAmbiente(ambiente);
        if (cfg.perfil === 'fumaca') continue;
        let linhas = [];
        const k6 = path.join(pasta, 'k6.json');
        if (fs.existsSync(k6)) {
            try {
                linhas = linhas.concat(metricasK6(JSON.parse(fs.readFileSync(k6, 'utf8')), cfg));
            } catch (e) {
                console.error(`Ignorando ${k6}: ${e.message}`);
            }
        } else if (cfg.cenario !== 'repouso') {
            console.error(`Execução sem k6.json (provavelmente falhou): ${nome}`);
            continue;
        }
        const recursos = path.join(pasta, 'recursos.csv');
        if (fs.existsSync(recursos)) linhas = linhas.concat(metricasRecursos(recursos, cfg));
        for (const l of linhas) execucoes.push({ ...pickChave(cfg), repeticao: cfg.repeticao, pasta: nome, ...l });
    }

    escreverCsv('metricas_execucoes.csv', [...CHAVE, 'repeticao', 'grupo', 'metrica', 'valor', 'pasta'], execucoes);

    const grupos = new Map();
    for (const e of execucoes) {
        const k = JSON.stringify([...CHAVE.map((c) => e[c]), e.grupo, e.metrica]);
        if (!grupos.has(k)) grupos.set(k, { linha: e, valores: [] });
        grupos.get(k).valores.push(e.valor);
    }
    const resumo = [];
    for (const { linha, valores } of grupos.values()) {
        resumo.push({ ...pickChave(linha), grupo: linha.grupo, metrica: linha.metrica, ...estatisticas(valores) });
    }
    escreverCsv('resumo.csv', [...CHAVE, 'grupo', 'metrica', 'n', 'media', 'desvio', 'cv', 'ic_inf', 'ic_sup'], resumo);

    const pares = new Map();
    for (const r of resumo) {
        const chave = CHAVE.filter((c) => c !== 'arquitetura' && c !== 'replicas').map((c) => r[c]);
        const k = JSON.stringify([...chave, variante(r.replicas), r.grupo, r.metrica]);
        if (!pares.has(k)) pares.set(k, { base: r, variante: variante(r.replicas) });
        pares.get(k)[r.arquitetura] = r;
    }
    const comparacao = [];
    for (const { base, variante: v, monolito: mo, microsservicos: ms } of pares.values()) {
        if (!mo || !ms) continue;
        const sobrepoe = mo.ic_inf <= ms.ic_sup && ms.ic_inf <= mo.ic_sup;
        comparacao.push({
            ...pickChave(base), variante: v, grupo: base.grupo, metrica: base.metrica,
            n_monolito: mo.n, media_monolito: mo.media, ic_monolito: `${numero(mo.ic_inf)} a ${numero(mo.ic_sup)}`,
            n_microsservicos: ms.n, media_microsservicos: ms.media, ic_microsservicos: `${numero(ms.ic_inf)} a ${numero(ms.ic_sup)}`,
            diferenca_percentual: mo.media !== 0 ? ((ms.media - mo.media) / mo.media) * 100 : '',
            significativa: mo.n > 1 && ms.n > 1 ? (sobrepoe ? 'nao' : 'sim') : 'n<2',
        });
    }
    const chaveComp = CHAVE.filter((c) => c !== 'arquitetura' && c !== 'replicas');
    escreverCsv('comparacao.csv', [...chaveComp, 'variante', 'grupo', 'metrica', 'n_monolito', 'media_monolito', 'ic_monolito',
        'n_microsservicos', 'media_microsservicos', 'ic_microsservicos', 'diferenca_percentual', 'significativa'], comparacao);

    const inicializacao = path.join(RESULTADOS, 'inicializacao.csv');
    let resumoInicio = [];
    if (fs.existsSync(inicializacao)) {
        const mapa = new Map();
        for (const linha of fs.readFileSync(inicializacao, 'utf8').split(/\r?\n/).slice(1).filter(Boolean)) {
            const [, arquitetura, recursos, replicas, aplicacao, spring, desdeUp] = linha.split(';');
            for (const [metrica, valor] of [['segundos_spring', spring], ['segundos_desde_up', desdeUp]]) {
                if (valor === '' || valor === undefined) continue;
                const k = JSON.stringify([arquitetura, recursos, replicas, aplicacao, metrica]);
                if (!mapa.has(k)) mapa.set(k, { arquitetura, recursos, replicas, aplicacao, metrica, valores: [] });
                mapa.get(k).valores.push(parseFloat(valor));
            }
        }
        resumoInicio = [...mapa.values()].map((g) => ({ ...g, ...estatisticas(g.valores) }));
        escreverCsv('inicializacao_resumo.csv', ['arquitetura', 'recursos', 'replicas', 'aplicacao', 'metrica', 'n', 'media',
            'desvio', 'cv', 'ic_inf', 'ic_sup'], resumoInicio);
    }

    const execs = new Set(execucoes.map((e) => e.pasta)).size;
    console.log(`${execs} execução(ões), ${resumo.length} linhas no resumo, ${comparacao.length} comparações, ` +
        `${resumoInicio.length} linhas de inicialização. Arquivos em ${SAIDA}`);
}

function pickChave(obj) {
    const r = {};
    for (const c of CHAVE) r[c] = obj[c];
    return r;
}

main();
