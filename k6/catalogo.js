import http from 'k6/http';
import { BASE_URL, ESTATISTICAS, ENDPOINTS_CATALOGO, metricasSeparadas, marcarDegrau, cenario, prepararDados, aleatorio, verificar, resumo } from './lib/comum.js';

export const options = {
    scenarios: { catalogo: cenario('navegar') },
    thresholds: metricasSeparadas(['catalogo'], ENDPOINTS_CATALOGO),
    summaryTrendStats: ESTATISTICAS,
};

export function setup() {
    return prepararDados(false);
}

export function navegar(dados) {
    marcarDegrau();
    let res = http.get(`${BASE_URL}/produto/buscaTodosComEstoque`, { tags: { name: 'GET /produto/buscaTodosComEstoque' } });
    verificar(res, 'listar produtos', 200);

    const produto = aleatorio(dados.produtos);
    res = http.get(`${BASE_URL}/produto/busca/${produto.id}`, { tags: { name: 'GET /produto/busca/{id}' } });
    verificar(res, 'detalhar produto', 200);

    res = http.get(`${BASE_URL}/loja`, { tags: { name: 'GET /loja' } });
    verificar(res, 'configuração da loja', 200);
}

export default navegar;

export function handleSummary(data) {
    return resumo(data);
}
