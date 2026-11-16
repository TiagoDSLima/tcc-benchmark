'use strict';

const fs = require('fs');
const path = require('path');

const PASTA = process.argv[2];
const CK = path.join(PASTA, 'ck');

function lerCsv(arquivo, separador) {
    const [cabecalho, ...linhas] = fs.readFileSync(arquivo, 'utf8').replace(/^﻿/, '').split(/\r?\n/).filter(Boolean);
    const colunas = cabecalho.split(separador);
    return linhas.map((l) => {
        const valores = l.split(separador);
        return Object.fromEntries(colunas.map((c, i) => [c, valores[i]]));
    });
}

function numero(v) {
    if (typeof v !== 'number') return v;
    return Number.isInteger(v) ? String(v) : v.toFixed(2).replace('.', ',');
}

function escrever(arquivo, colunas, linhas) {
    const texto = [colunas.join(';'), ...linhas.map((l) => colunas.map((c) => numero(l[c] ?? '')).join(';'))].join('\n');
    fs.writeFileSync(path.join(PASTA, arquivo), '﻿' + texto + '\n');
}

const METRICAS = ['cbo', 'wmc', 'rfc', 'lcom', 'loc'];

function resumir(classes) {
    const r = { classes: classes.length };
    for (const m of METRICAS) {
        const v = classes.map((c) => parseFloat(c[m])).filter((x) => !Number.isNaN(x));
        r[`${m}_total`] = v.reduce((a, b) => a + b, 0);
        r[`${m}_media`] = v.length ? r[`${m}_total`] / v.length : 0;
        r[`${m}_max`] = v.length ? Math.max(...v) : 0;
    }
    return r;
}

const porProjeto = [];
const porArquitetura = { monolito: [], microsservicos: [] };
for (const projeto of fs.readdirSync(CK).sort()) {
    const arquivo = path.join(CK, projeto, 'class.csv');
    if (!fs.existsSync(arquivo)) continue;
    const classes = lerCsv(arquivo, ',');
    const arquitetura = projeto === 'monolito' ? 'monolito' : 'microsservicos';
    porArquitetura[arquitetura].push(...classes);
    porProjeto.push({ arquitetura, projeto, ...resumir(classes) });
}
const totais = Object.entries(porArquitetura).map(([arquitetura, classes]) => ({ arquitetura, projeto: '(total)', ...resumir(classes) }));

const colunasCk = ['arquitetura', 'projeto', 'classes', ...METRICAS.flatMap((m) => [`${m}_total`, `${m}_media`, `${m}_max`])];
escrever('ck_resumo.csv', colunasCk, [...porProjeto, ...totais]);

const repositorios = lerCsv(path.join(PASTA, 'repositorios.csv'), ';');
const somas = {};
for (const r of repositorios) {
    const s = somas[r.arquitetura] || (somas[r.arquitetura] = { arquitetura: r.arquitetura, projeto: '(total)', projetos: 0 });
    s.projetos += 1;
    for (const [k, v] of Object.entries(r)) {
        if (k !== 'arquitetura' && k !== 'projeto') s[k] = (s[k] || 0) + parseInt(v || '0');
    }
}
const colunasRepo = Object.keys(repositorios[0]);
escrever('repositorios_total.csv', ['arquitetura', 'projetos', ...colunasRepo.slice(2)], Object.values(somas));

console.log('CK por arquitetura:');
for (const t of totais) {
    console.log(`  ${t.arquitetura}: ${t.classes} classes, ${t.loc_total} linhas, CBO médio ${t.cbo_media.toFixed(2)}, ` +
        `WMC médio ${t.wmc_media.toFixed(2)}, LCOM médio ${t.lcom_media.toFixed(2)}`);
}
console.log('Repositórios:');
for (const s of Object.values(somas)) {
    console.log(`  ${s.arquitetura}: ${s.projetos} projeto(s), ${s.arquivos_java_main} arquivos Java, ${s.linhas_java_main} linhas, ` +
        `${s.testes} testes, ${s.dependencias_pom} dependências, ${s.arquivos_configuracao} arquivos de configuração, ` +
        `${s.arquivos_comunicacao} arquivos de comunicação`);
}
console.log(`Arquivos em ${PASTA}`);
