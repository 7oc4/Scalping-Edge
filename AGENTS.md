# Instruções do projeto — Scalping Edge

## Regra permanente sobre dados (pedido explícito do dono)

Neste projeto **nada de dado atrasado, estimado, simulado, inventado ou "fake"**.

- Só entra na interface o que a fonte entrega **em tempo real** (`delaySeconds = 0`).
- Se um ativo só existe com atraso (ex.: índices, ações e commodities no scanner
  público do TradingView, que vêm com 10/15 min; Yahoo Finance também atrasa
  ações em 15 min), ele **fica fora do radar** em vez de aparecer com preço velho.
- Nunca rotular dado atrasado como tempo real, nem arredondar/estimar para
  "parecer" atual. Falta de dado vira aviso/erro explícito, nunca número inventado.
- Histórico real (candles do Yahoo) pode ser usado para série/gráfico, desde que a
  fonte seja citada na tela e o preço exibido venha do feed em tempo real.

Ativos hoje em tempo real na fonte pública: cripto (Binance: BTC, ETH, SOL, XRP,
DOGE) e moedas (FX: EUR/USD, GBP/USD, USD/JPY). Para incluir bolsas/ações em tempo
real é preciso um provedor pago/autenticado; não é possível com a fonte pública.

## Animação e progresso também não mentem

- Animação de busca (varredura do radar/varredor) só gira enquanto existe
  requisição real em andamento; termina em ok ou falha.
- Barra de progresso usa números reais (candles/trades/reamostragens). Sem total
  conhecido, fica indeterminada — nunca avança sozinha para parecer trabalho.
- O backtest é simulação educativa do passado: não é prova de edge, previsão nem
  recomendação. Custos, spread e slippage ficam fora do cálculo.
