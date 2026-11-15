import http from 'k6/http';
import { BASE_URL, ESTATISTICAS, ENDPOINTS_COMPRA, metricasSeparadas, marcarDegrau, cenario, prepararDados, aleatorio, verificar, resumo } from './lib/comum.js';

export const options = {
    scenarios: { compra: cenario('comprar') },
    thresholds: metricasSeparadas(['compra'], ENDPOINTS_COMPRA),
    summaryTrendStats: ESTATISTICAS,
};

const ENDERECO = { cep: '01001000', rua: 'Praca da Se', bairro: 'Se', numero: '1', cidade: 'Sao Paulo', uf: 'SP' };

export function setup() {
    return prepararDados(true);
}

function item(produto) {
    const it = { idProduto: produto.id, quantidade: 1 };
    if (produto.variacoes.length > 0) {
        it.idProdutoVariacao = aleatorio(produto.variacoes);
    }
    return it;
}

export function comprar(dados) {
    marcarDegrau();
    const cliente = dados.clientes[(__VU - 1) % dados.clientes.length];
    const p1 = aleatorio(dados.produtos);
    let p2 = aleatorio(dados.produtos);
    while (dados.produtos.length > 1 && p2.id === p1.id) {
        p2 = aleatorio(dados.produtos);
    }

    const pedido = {
        itensPedido: [item(p1), item(p2)],
        endereco: ENDERECO,
        pagamento: {
            tipoPagamento: 'PIX',
            emailPagador: cliente.email,
            primeiroNomePagador: 'Cliente',
            segundoNomePagador: 'Benchmark',
            cpfCnpjPagador: '39053344705',
        },
    };

    let res = http.post(`${BASE_URL}/pedido`, JSON.stringify(pedido), {
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cliente.token}` },
        tags: { name: 'POST /pedido' },
    });
    if (!verificar(res, 'criar pedido', 201)) {
        return;
    }

    const notificacao = { type: 'payment', data: { id: String(res.json('id')) } };
    res = http.post(`${BASE_URL}/webhook/mercadopago`, JSON.stringify(notificacao), {
        headers: { 'Content-Type': 'application/json' },
        tags: { name: 'POST /webhook/mercadopago' },
    });
    verificar(res, 'notificação de pagamento', 200);
}

export default comprar;

export function handleSummary(data) {
    return resumo(data);
}
