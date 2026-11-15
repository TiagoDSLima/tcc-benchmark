import { ESTATISTICAS, ENDPOINTS_CATALOGO, ENDPOINTS_COMPRA, metricasSeparadas, cenario, prepararDados, resumo } from './lib/comum.js';
import { navegar } from './catalogo.js';
import { comprar } from './compra.js';

export { navegar, comprar };

export const options = {
    scenarios: {
        catalogo: cenario('navegar', 0.8),
        compra: cenario('comprar', 0.2),
    },
    thresholds: metricasSeparadas(['catalogo', 'compra'], [...ENDPOINTS_CATALOGO, ...ENDPOINTS_COMPRA]),
    summaryTrendStats: ESTATISTICAS,
};

export function setup() {
    return prepararDados(true);
}

export function handleSummary(data) {
    return resumo(data);
}
