# Changelog — Scalping Edge

Formato: cada versão lista o que mudou e por quê. O contrato (schema + validador)
e o prompt são versionados juntos; o nome do arquivo em `prompts/` acompanha
`$script:ContractVersion`.

## 9.6 — cadência segura e carregamento do varredor

- Mercado e Varredor passam a usar intervalos mínimos de 2 s, sempre esperando a
  resposta anterior terminar. Leituras lentas e falhas aumentam o intervalo
  progressivamente; abas ocultas não iniciam novas leituras do mercado.
- Um clique manual durante uma varredura automática fica enfileirado, em vez de
  ser descartado. A primeira leitura mostra o esqueleto enquanto a requisição
  real está em andamento; atualizações seguintes mantêm os resultados na tela.
- Candles ainda não armazenados são obtidos em lotes de até quatro chamadas
  concorrentes; o resultado do scanner exige cotação de TradingView com atraso
  zero e nunca usa fechamento histórico como preço atual.
- O botão de cálculo de risco ficou compacto, com ícone, foco visível e o mesmo
  comportamento de cálculo.

## 9.5 — amostra histórica no cálculo de risco

- A aba Cálculo e Risco pode consultar até 50 operações mais recentes fechadas
  em candles públicos de 5m dos últimos 60 dias, usando a estratégia EMA 9/21,
  stop de 1,5 ATR e alvo ajustado ao risco/retorno informado.
- Mostra frequências observadas de ganhos/perdas, resultado em R, recuo histórico
  e a conversão aritmética para o risco fixo informado. Não chama isso de
  probabilidade futura e não completa amostras menores.
- Usa o fluxo assíncrono existente com contagem de candles, operações e
  reamostragens; parâmetros de backtest são limitados e validados no servidor.

## 9.4 — notícias públicas das últimas 24 horas

- Amplia as buscas RSS para trading, Bitcoin/cripto, forex, bolsa americana,
  Nasdaq, S&P 500 e demais temas de mercado.
- Filtra por timestamp verificável no servidor; itens sem data, fora de 24 horas
  ou com data futura não são exibidos. O cache também revalida a janela a cada
  consulta.
- Mantém atualização automática a cada minuto e não usa IA para buscar ou
  resumir manchetes.

## 9.3 — revisão do prompt visual (contrato 8.1)

- Substitui a alegação de confidence determinístico por uma descrição explícita:
  coverage e confidence são estimativas do modelo; o servidor aplica tetos, mas
  não recalcula subescores internos nem comprova calibração estatística.
- Define coverage pelo peso das categorias legíveis entre as aplicáveis e separa
  legibilidade de força da evidência.
- Permite `risk` vazio quando não houver limitação específica, remove a ressalva
  genérica sobre o recorte visível e deixa de penalizar summaries curtos.
- Mantém os seis títulos do summary e os campos do schema, sem exigir palavras,
  preços, horários ou níveis que a imagem não permita verificar.
- O servidor resolve o arquivo do prompt a partir da versão do contrato.

## 9.2 — modelos de raciocínio (gpt-5.6-luna) com adaptação por família

Mesmo contrato 8.0, mesmas rotas, mesmo schema e mesmo fluxo de validação. Mudou
**como o corpo da requisição é montado**, porque trocar só a string do modelo
quebraria a análise.

- **`gpt-5.6-luna` é o modelo padrão**; `OPENAI_MODEL=gpt-4o-mini` volta ao
  anterior sem tocar no código.
- **Compatibilidade por família**: `gpt-5.6-luna` (e `gpt-5.x`, `gpt-6-*`,
  `o-series`) é modelo de raciocínio — exige `max_completion_tokens` e recusa
  `temperature`, `top_p` e penalidades. O request antigo mandava
  `temperature: 0` + `max_tokens` e teria voltado HTTP 400. Agora o perfil é
  derivado do id: modelos de raciocínio recebem `max_completion_tokens` e
  `reasoning_effort`, sem `temperature`; `gpt-4o-mini` continua recebendo
  `temperature: 0.0` + `max_tokens`, exatamente como antes. Structured Outputs
  (`json_schema`, `strict: true`) e `store: false` valem nas duas famílias.
- **Novo `OPENAI_REASONING_EFFORT`** (`none|low|medium|high|xhigh|max`, padrão
  `low`). É escolha de custo/latência, não economia medida; valor inválido cai no
  padrão com aviso visível.
- **Bug corrigido — resposta vazia com `finish_reason=length`**: o teste de
  conteúdo vazio vinha antes da repetição com mais tokens, então um modelo de
  raciocínio que gastasse o orçamento pensando falhava sem nunca repetir. A
  ordem foi invertida e a repetição grava no parâmetro de tokens da família.
- **Fallback honesto**: em 404/`model_not_found` o servidor avisa e repete uma
  única vez com `OPENAI_MODEL_FALLBACK` (padrão `gpt-4o-mini`), remontando o
  corpo para a outra família; a resposta traz `X-ZNX-Model` e
  `X-ZNX-Model-Fallback: 1`, e o JSONL grava `model` + `model_requested`. 400 de
  imagem, 401 e 429 não trocam de modelo.
- **`OPENAI_BASE_URL`** (padrão `https://api.openai.com/v1`) permite gateway
  compatível; o endpoint continua `/chat/completions`, sem migração para
  `/v1/responses`.
- **Redação de chave centralizada** em `Hide-SensitiveDiagnostic`: chave literal,
  cabeçalho `Bearer` e qualquer token `sk-…` somem do log, da resposta e da tela.
- **Chamada HTTP extraída** para `Invoke-OpenAIChatCompletion` no módulo, com o
  mesmo retry/backoff de antes e transporte injetável para teste.
- **Bug corrigido — `HttpClient.Timeout` reatribuído a cada chamada**: o valor só
  pode ser definido antes da primeira requisição, e o servidor reutiliza o
  cliente. A segunda análise (e a releitura automática) falhava antes de sair
  para a rede. O timeout agora só é aplicado ao cliente criado pela própria
  função; o cliente injetado mantém o timeout com que foi criado. Regressão
  coberta pelo teste 28.9.
- **Verificação ponta a ponta sem créditos**: `tests/fixtures/mock-openai.ps1`
  devolve o 404 real de `model_not_found` e registra o corpo recebido. Rodando o
  servidor contra ele confirmou-se, na prática, `gpt-5.6-luna` com
  `max_completion_tokens: 4000` + `reasoning_effort: low` e **sem** `temperature`,
  seguido do fallback `gpt-4o-mini` com `max_tokens: 4000` + `temperature: 0`.
  Nenhuma chamada real e nenhum crédito consumido.
- **`GET /api/status`** passou a devolver `fallbackModel`, `family`,
  `tokenParameter`, `temperature`, `reasoningEffort`, `maxOutputTokens`,
  `supportsStructuredOutputs` e `apiBaseUrl` (nunca a chave).
- **`tools/check-openai.ps1`**: confere modelo/conexão via `GET /v1/models`, sem
  consumir créditos, e lista os modelos que a chave enxerga.
- **Testes**: `tests/OpenAI.Tests.ps1` (27.1–27.11 unitários, 28.1–28.9 com
  transporte simulado) entrou no `npm test`; `tests/Server.Tests.ps1` ganhou o
  describe 29 (modelo, perfil e ausência da chave em `/api/status`) e o describe
  30, que roda o servidor contra `tests/fixtures/mock-openai.ps1` e prova a
  repetição de resposta cortada (4000 → 8000 tokens no parâmetro certo) sem
  inventar análise válida. Nenhum teste chama a API real.

## 9.1 — efeitos interativos só no Brave

Mesmo contrato 8.0. Camada visual; nenhum dado muda.

- **`assets/js/brave-fx.js`**: camada de canvas com partículas em vórtice no
  cursor, malha de ligações que acende perto do ponteiro, rastro, ondas no
  clique e pulso verde/vermelho a cada tique real de preço (evento
  `znx:market-tick` disparado pelo radar). É pesada de propósito: 70–130
  partículas e até ~8 mil ligações por quadro, com densidade proporcional à tela.
- **Só no Brave**: o gate é `navigator.brave.isBrave()`; sem essa confirmação
  o módulo não cria canvas nem classe no `body`. Nada de user-agent fingindo
  ser Brave. `?fx=on` e `?fx=off` existem apenas para testar/desligar sem
  editar código.
- **Acessibilidade**: `prefers-reduced-motion` continua respeitado; `?fx=on`
  sobrepõe a preferência do sistema porque é intenção explícita do usuário.
- **Tilt 3D** nas linhas do mercado (`.fx-tilt`), aplicado só quando o módulo
  está ativo; fora dele o layout e as transições seguem iguais.
- **Servidor**: `assets/js/brave-fx.js` entrou na lista estática; o teste
  10.17.1 garante o arquivo servido e a presença do gate.

## 9.0 — radar em milissegundos, varredor ao vivo e comparativo multi-mercado

Mesmo contrato 8.0. Nenhuma regra de dados mudou: tudo abaixo é leitura real,
com cadência curta e sem inventar número.

- **Radar em ms, sem derrubar a fonte**: o cache do snapshot caiu de 1 s para
  250 ms e o do TradingView para 250 ms; o laço do painel passou a 250 ms depois
  que a resposta anterior chega (nunca empilha). Quando a leitura passa de
  400 ms o intervalo sobe para 750 ms; em falhas seguidas recua até 4 s. Uma
  tentativa extra de 120 ms absorve blip de rede, e 429/5xx do TradingView
  impõem pausa de 2 s em vez de insistir. A tela mostra `fonte em X ms` e
  `painel em Y ms`, medidos de verdade.
- **Investidor10**: referência em R$/24 h passou de 180 s para 60 s de cache.
  É o ritmo da própria página; mais rápido só aumentaria risco de bloqueio.
- **Varredor mais inteligente**: novo `Get-ZnxScanIndicators` calcula EMA 9/21/50,
  RSI, ATR, ATR relativo (regime de volatilidade), momentum de 5 candles em ATR,
  posição na faixa de 20 candles e frescor do rompimento. O score ganhou esses
  fatores (todos opcionais; sem eles o resultado é idêntico ao anterior) e cada
  ativo passou a trazer confiança de força, entrada, stop, alvo e R/R.
- **Varredor ao vivo**: indicadores ficam 60 s em cache por ativo; preço e score
  são refeitos a cada leitura com a cotação ao vivo do TradingView. O painel
  atualiza sozinho a cada 5 s enquanto a aba Varredor está aberta, sem piscar a
  lista (sem esqueleto e mantendo o filtro escolhido).
- **Gráfico de 5 em 5 s**: cada período tem cache próprio (5 min → 5 s; 15 min →
  15 s; 1 h → 30 s; 1 dia → 60 s) e a aba Gráfico recarrega sozinha a cada 5 s,
  sem esqueleto quando já existe desenho na tela. O rodapé mostra a hora da
  atualização.
- **Máquina do tempo compara 8 mercados**: `GET /api/backtest/start?mode=sweep`
  roda o mesmo histórico real de 60 dias em 8 mercados × 9 combinações de
  stop/alvo (72 combinações, 8.640 reamostragens, ~5,7 milhões de cálculos numa
  execução medida em 26 s), guarda cada entrada e saída e mostra o agregado:
  entradas/saídas, acerto, média em R, fator de lucro, quantas combinações deram
  certo e quantas não, além do melhor par stop/alvo por mercado com amostras de
  operações. Nada é sorteado para "dar certo"; resultado negativo aparece como
  negativo.
- **Sinais reaproveitados**: `Get-ZnxBacktestSignals` calcula EMAs/ATR e os
  cruzamentos uma vez por ativo; o comparativo reusa isso nas 9 combinações, e
  um teste exige estatística idêntica à conta completa.
- **Testes**: 7 novos casos no describe 26 do contrato de mercado (score antigo
  preservado, fatores novos, confiança, frescor, detalhes de entrada/saída e
  paridade dos sinais pré-calculados).

## 8.9 — faixas de confidence iguais em todo lado

Mesmo contrato 8.0. Correção de classificação por faixa; inteiro preservado.

- **69,5 tinha três respostas**: no erro quadrático o valor fracionário não
  caía em faixa nenhuma (`>= Min -le Max` deixava 54,5 / 69,5 / 84,5 de fora),
  no relatório `[int]` arredondava 69,5 para 70 e o painel dava 70-84. Agora
  existe uma única definição em `market.psm1`
  (`Get-ZnxConfidenceBucketLabel`): o valor entra pelo inteiro truncado, então
  69,5 fica em 55-69, 54,9 em 0-54 e 84,5 em 70-84, sem buraco entre faixas.
- **Inteiro intacto**: 54 → 0-54, 55 → 55-69, 69 → 55-69, 70 → 70-84,
  85 → 85-100; nenhuma faixa vazia recebe valor.
- **Relatório e API pela mesma via**: `tools/evaluate.ps1` e o painel usam a
  mesma função; novo teste compara os dois com a mesma fixture e exige amostra,
  inválidos, erro e as quatro faixas idênticos.

## 8.8 — confidence inválido fora das estatísticas

Mesmo contrato 8.0. Correção de robustez na leitura do confidence; nada muda para
registro válido.

- **Sem zero silencioso**: `tools/evaluate.ps1` e `GET /api/calibration`
  classificavam por faixa com `[int]$row.confidence`. Confidence nulo virava 0 e
  caía na faixa 0-54; confidence textual (ou fora de 0..100) derrubava a API.
  Agora a leitura passa por `ConvertTo-ZnxConfidenceNumber`, que devolve `null`
  em vez de zero, e o registro fica fora das estatísticas que dependem do campo.
- **Nome honesto**: `ConvertTo-ZnxConfidenceProbability` virou
  `ConvertTo-ZnxNormalizedConfidence` — o índice do contrato não é probabilidade.
- **Uma fórmula só continua**: `Get-ZnxConfidenceOutcomeError` usa a mesma
  leitura e a mesma normalização, então relatório e API seguem com a mesma
  amostra, os mesmos inválidos, o mesmo erro e as mesmas quatro faixas.
- **Testes isolados**: `ZNX_OUTCOMES_PATH` permite que a suíte use desfechos de
  fixture temporária; os testes cobrem confidence nulo, textual, faixa 0-54 e
  zero amostra (`null`).

## 8.7 — cartões de moedas e cripto com a mesma estrutura

Mesmo contrato 8.0. Ajuste visual do painel de mercado; nenhum dado mudou.

- **Sem linha extra no cartão de cripto**: a nota “Investidor10 · cotação em R$ e
  variação 24h” saiu de dentro do cartão. Ela empurrava as linhas para baixo
  (25 px a mais que o cartão de moedas) e deixava os dois cartões desalinhados.
  Agora os dois começam as linhas na mesma altura, com a mesma altura de linha e
  o mesmo ritmo.
- **Atribuição honesta**: a fonte só aparece no `title` do cartão quando alguma
  linha realmente vem do Investidor10. Antes a nota afirmava R$/24h mesmo com as
  linhas mostrando variação em “DIA” da TradingView.

## 8.6 — botão "Atualizar" do radar sem toque fantasma

Mesmo contrato 8.0. Correção de interação: nenhuma regra de dado, prompt ou
análise foi tocada.

- **Botão que piscava e comia cliques**: o ciclo automático chamava `loadMarket`
  com `silent`, mas o `disabled` do botão era ligado/desligado a cada leitura
  (~500 ms). Resultado: o botão tremia entre habilitado e desabilitado e os
  cliques que caíam no intervalo eram descartados pelo navegador — o "toque
  fantasma". Agora o ciclo automático não mexe em `disabled`; o estado de
  carregando continua barrado pelo guarda `marketLoading`.
- **Clique durante a leitura não se perde**: se o pedido chegar com uma leitura
  em andamento, ele é guardado (`marketRefreshQueued`) e atendido assim que ela
  termina, com aviso no status — em vez de sumir sem resposta.

## 8.5 — erro de consistência entre confidence e desfecho

Mesmo contrato 8.0 (schema, prompt, rubrica e travas intactos). Entra uma métrica
diagnóstica dos desfechos já registrados, sem mudar o significado do confidence.

- **`confidenceOutcomeError`**: média de `(p - o)^2` sobre desfechos reais, com
  `p = confidence/100` limitado a 0..1 e `o = 1`/`0` para favorable/adverse. Só
  entram BUY/SELL com desfecho favorable/adverse; NEUTRAL, WAIT e `neutral` ficam
  fora, e registro sem confidence numérico válido entre 0 e 100 é contado como
  inválido em vez de virar amostra.
- **Diagnóstico, não probabilidade**: o número mede discrepância entre o índice
  técnico e o desfecho. Não é Brier score probabilístico, nem taxa de acerto, nem
  vantagem operacional, e não ajusta nenhuma decisão da IA.
- **Por faixa**: `sampleCount`, `confidenceMean`, `favorableRate` e
  `averageSquaredError` nas mesmas faixas (0-54 a 85-100). Faixa vazia fica nula.
- **Sem amostra, nulo**: com zero desfechos o erro é `null` e `sampleCount` é 0.
- **Uma fórmula só**: `Get-ZnxConfidenceOutcomeError` em `market.psm1`, usada por
  `tools/evaluate.ps1` e por `GET /api/calibration`.

## 8.4 — radar sem erro fantasma e animações por estado

Mesmo contrato 8.0. Ciclo de UI: corrige o painel de mercado e dá animação
própria a cada estado, sem tocar em prompt, contrato ou análise de print.

- **Falha por ativo não derruba o painel**: ativo sem preço em tempo real sai da
  lista e é apenas contado (“N ativos sem preço em tempo real ficaram fora
  agora”), sem pintar a tela de vermelho. O estado de erro global ficou reservado
  ao caso de **zero** ativos em tempo real — aí o painel fica vazio e explica.
- **Fim do texto fantasma**: “Varrendo o mercado…” só aparece na primeira carga
  ou no clique em “Atualizar”. O ciclo automático mantém o selo em “Tempo real”
  com um indicador discreto, em vez de alternar o rótulo a cada segundo.
- **Falha isolada não vira erro**: a primeira leitura que falha apenas tenta de
  novo; só depois de três falhas seguidas a fonte é declarada fora do ar, sempre
  com a hora da última leitura real.
- **Requisição com teto**: o fetch do radar aborta em 12 s, para o ciclo de 1 s
  não ficar pendurado parecendo atualização.
- **Animações por estado**: `is-scanning` (varredura circular no dial e no
  painel), `is-refreshing` (ponto respirando na leitura de fundo), `is-live`
  (ping no selo tempo real), `is-ok` e `is-error`. O cone só gira com
  `is-scanning`; sem requisição em andamento nada anima.
- **Microinterações**: selo “tempo real” de cada ativo pulsando, sheen nos
  botões do radar, entrada escalonada das linhas do varredor. Tudo desligado em
  `prefers-reduced-motion: reduce`.
- **Máquina do tempo com animação própria**: faixa ciano (`#38bdf8`) com linha de
  leitura horizontal e brilho na barra preenchida, via classe `is-running` —
  linguagem visual distinta do radar verde.
- **Letreiro honesto**: quando a lista de ativos muda, o letreiro é remontado em
  vez de remendar por índice (índice deslocado trocava preço de ativo).
- **Servidor**: `Get-ZnxMarketSnapshot` agora exige preço numérico positivo e
  `live = true` antes de incluir o ativo, e a lista `failed` não repete símbolo.
- **Cliente que desiste não derruba o servidor**: quando o navegador recarrega a
  página ou fecha a aba no meio do polling, a escrita no socket morto lançava
  `"O nome da rede especificado não está mais disponível"`; o catch da rota tentava
  escrever uma segunda resposta no mesmo socket, estourava em `ContentLength64` e
  o `Write-Error` encerrava o processo inteiro. Agora toda escrita passa por
  `Send-ResponseBytes`, que descarta a conexão morta em silêncio e fecha a resposta
  no `finally`; `EndGetContext` protegido (preconnect/requisição pela metade) e o
  catch geral loga `Warning` em vez de erro fatal. Teste `10.18` reproduz o caso.
- **Ritmo**: o painel consulta a cada ~500 ms depois que a resposta anterior
  termina (o cache do servidor continua em 1 s).

## 8.3 — tempo real visível, progresso honesto e leitura visual calibrada

Mesmo contrato 8.0. O ciclo é de produto, percepção e qualidade da leitura — sem
soltar a regra de dado real nem afrouxar travas.

- **Radar com varredura real**: indicador circular no topo do radar e no
  varredor que só gira durante uma requisição de verdade. Terminada a busca ele
  vira “Tempo real”/“Varredura concluída”; em falha para de girar e fica vermelho
  com o motivo. Nada de animação fingindo trabalho.
- **Mercado em ~1 s**: `/api/market` passou a ter cache de 1 s para a cotação do
  TradingView (era 15 s) e o painel consulta em ritmo de 1 s, sempre esperando a
  resposta anterior (sem empilhar pedidos) e pausando com a aba escondida. A
  lista é atualizada no lugar — preço, variação, faixa e fonte — com um flash
  curto quando o preço muda, em vez de reconstruir a tela a cada segundo.
- **Falha de fonte é explícita**: a tela mostra a hora da última leitura real e
  o estado “Fonte sem resposta”. Preço antigo nunca é reapresentado como atual.
- **Máquina do tempo com progresso real**: o backtest roda em runspace separado
  e publica em `/api/backtest/progress` os candles já processados, os trades
  encontrados e as reamostragens concluídas. A UI usa linha do tempo horizontal
  (linguagem diferente do radar), fica indeterminada durante o download e mostra
  contadores reais. O rodapé do resultado reforça que é simulação educativa.
- **Notícias a cada minuto**: verificação de 60 s, horário da última atualização e
  contagem para a próxima; quando a fonte falha, a lista anterior permanece com o
  horário dela e o erro é mostrado.
- **Preparo de imagem v2**: `ConvertTo-PreparedImageBytes` recorta apenas bordas
  uniformes (limite de 12% por lado, guarda de 60% da imagem) e mede o contraste
  no miolo antes de realçar. O tag (`crop`, `contrast`, `crop+contrast`) entra na
  chave de cache, no log e no cabeçalho `X-ZNX-Preprocess`. `ZNX_IMAGE_ENHANCE`
  continua controlando o modo.
- **Overlay dos níveis**: as linhas são desenhadas sobre o print com a escala de
  preço lida (`price_axis_min/max`), com legenda por tipo e botão para esconder.
  Sem escala legível, o overlay fica desligado e explica o motivo.
- **Calibração real**: `GET /api/calibration` cruza `logs/analyses.jsonl`,
  `logs/feedback.jsonl` e `data/outcomes.jsonl` em faixas de confidence e o
  painel mostra a taxa ao lado do número da IA. Sem amostra, diz que não há
  amostra; o confidence do modelo não é alterado.
- **Diagnóstico na tela**: `X-ZNX-Reread` e `X-ZNX-Preprocess` aparecem no
  contexto do resultado (imagem preparada, releitura melhorou/confirmou/falhou).
- Testes: 19.6 (crop de borda uniforme) e 19.7 (imagem sem borda uniforme e com
  contraste não é alterada), além das suítes de mercado e servidor existentes.

## 8.2 — releitura quando a primeira passada não vê gráfico (mesmo contrato 8.0)

Sintoma relatado: captura de gráfico real voltou como `image_class: D`
(“Não foi possível identificar um gráfico financeiro”), sem erro de rede nem de
contrato. O modelo errou a classe e o servidor devolvia a recusa direto.

- **Releitura automática** (`analysis-contract.psm1` + `server.ps1`): quando a
  primeira leitura aprovada é classe C ou D, o servidor repete a análise **uma
  única vez** com a imagem original (sem realce) e uma instrução que pede
  verificação de eixos, candles/linha, volume/indicador e ativo/timeframe, sem
  autorizar invenção. A resposta só substitui a primeira se a classe melhorar
  (`Get-ImageClassRank`: A > B > C > D); falha ou resposta pior mantém a
  primeira leitura, então a releitura nunca transforma uma resposta válida em
  erro. `ZNX_REREAD=off` desliga; o banner mostra o estado.
- **Diagnóstico**: `logs/analyses.jsonl` ganhou o campo `reread`
  (`improved|kept|failed`) e a captura recusada é gravada em
  `logs/last-refused-image.<ext>` para reproduzir o caso localmente.
- Contagem de tokens do console soma as duas chamadas quando houve releitura.
- Testes: 20.1–20.3 (ordem das classes, gatilho só em C/D, texto da instrução).

## 8.1 — ciclo de verdade de mercado (mesmo contrato 8.0)

O prompt e o schema não mudaram. O que mudou é o que o projeto consegue medir
depois da análise.

- **Registro de análises**: cada resposta aprovada grava uma linha em
  `logs/analyses.jsonl` (id, direção, ação, confidence, classe, modelo, contrato,
  realce aplicado e hash da imagem) e devolve `X-ZNX-Analysis-Id` no cabeçalho.
  O id é a chave para juntar feedback, desfecho e métricas.
- **Feedback humano**: botões “Acertou / Errou / Nível inventado” no painel,
  `POST /api/feedback` com checagem de origem e veredito em lista fechada,
  gravando `logs/feedback.jsonl`. Sem isso o sistema nunca sabia onde errou.
- **Desfecho real**: `tools/record-outcome.ps1` registra
  `favorable|adverse|neutral`, horizonte e preços em `data/outcomes.jsonl`.
- **Métricas**: `tools/evaluate.ps1` calcula taxa de acerto direcional (BUY/SELL
  com desfecho definido), taxa de WAIT, contagem de feedback e calibração por
  faixa de confidence, com relatório em `evaluation/report.json`. Sem desfechos,
  reporta zero em vez de estimar.
- **Realce adaptativo de imagem**: quando o contraste medido da captura é baixo,
  o servidor aplica contraste 1,25 e envia a versão realçada (`X-ZNX-Preprocess:
  contrast-v1`). `ZNX_IMAGE_ENHANCE=auto|on|off` controla; WEBP e imagens já
  contrastadas seguem intactas; falha do GDI+ cai para o original. O modo entra
  na chave de cache, então imagem realçada e original não se misturam.
- **Suíte viva comparável**: `live-suite.ps1` grava `meta.json` (modelo, contrato,
  realce, cache hits), inclui `id`/`cache`/`realce` no CSV e avisa quando um
  resultado veio do cache.
- `ZNX_LOG_DIR` permite apontar logs para pasta temporária (usado pelos testes).
- Testes: 19.1–19.5 (realce PNG/JPEG, contraste alto, WEBP, imagem pequena),
  18.5 (realce na chave de cache) e 10.10–10.13 (rotas e gravação do feedback).
  Total: 121 de contrato + 13 de servidor.

## 8.0

- Prompt mestre V8.0: fluxo de 11 passos, etapa de falsificação e rubrica
  determinística de confidence; o raciocínio da seção 2.1 fica interno.
- Prefixo `possível:` em observações ambíguas, com destaque visual no painel.
- `response_format: json_schema` strict como autoridade do contrato; o servidor
  remove um eventual bloco `<thinking>` antes de validar.
- Schema reordenado (evidência antes da decisão) sem adicionar ou omitir chaves.

### Robustez pós-auditoria (mesma versão de contrato)

- Servidor confere a assinatura real do arquivo (magic bytes PNG/JPG/WEBP); MIME
  declarado e base64 sintático deixam de ser suficientes.
- Limite local de 10 análises por minuto com janela deslizante (`Retry-After` +
  HTTP 429), configurável por `ZNX_RATE_LIMIT_PER_MINUTE`.
- Leitura do corpo da requisição limitada a 30 segundos (`ZNX_READ_TIMEOUT_SECONDS`),
  respondendo 408 em cliente lento.
- `maxItems` no schema strict para todas as listas que o prompt já limitava,
  evitando tokens gastos em itens que seriam truncados na validação.
- Prompt: instrução explícita para registrar tentativa de prompt injection em
  `risk`; formato fixo de `trend.structure`; cenário 77 (preço no meio do range)
  no Atlas; âncoras do componente Confirmação na rubrica.
- Validação do navegador (`analysis-format.js`) dividida em checagens nomeadas:
  a falha agora aponta o campo (`Campo inválido: trend.main`) ou a regra violada,
  em vez de duas expressões de 60+ condições com mensagem genérica.
- Trava de lateralização no validador: `trend.main = lateralização` com os dois
  scores abaixo de 70 força NEUTRAL/WAIT mesmo que o modelo devolva um viés. A
  regra do prompt (preço no meio do range, cenário 77) deixa de depender só da
  obediência do modelo; testes 3.13 e 3.14 cobrem os dois caminhos.
- Quatro fixtures novas: lateralização no meio do range, `conflict_notes`
  forçando NEUTRAL, classe D sem gráfico e viés BUY com vela possivelmente aberta.
- Seletor de timeframe do painel inclui 1h, 4h e 1d, já aceitos pelo backend.
- Testes 2.9–2.15 e 18.1–18.4 cobrem os reparos de score e a chave do cache local.

### Respostas que não falham mais por score

- `buy_status`/`sell_status` `supported` com score abaixo de 70 deixam de derrubar
  a análise: o status é rebaixado para `weak` e a direção cai para NEUTRAL/WAIT.
- Score decimal é arredondado, score fora de 0..100 é limitado à faixa e score
  numérico em texto é convertido — tudo antes da validação, sem nova chamada de API.
- Lado avaliado (classe A/B) sem evidência listada também deixa de ser rejeitado:
  o campo recebe a nota "Nenhuma evidência visual específica foi registrada…" e
  a limitação entra em `risk`, mantendo a análise visível e honesta.
- Erros de forma de verdade (campo ausente, tipo impossível de ler, enum inválido)
  continuam rejeitados com mensagem específica.

### Custo, latência e requests

- `OPENAI_MAX_TOKENS` padrão 8000 → 4000 (o JSON cabe com folga; o retry por
  truncamento deixa de ser o caminho comum).
- `OPENAI_MAX_RETRIES` padrão 2 → 1: uma retentativa cobre 429/5xx sem multiplicar
  o consumo da chave quando o provedor está fora do ar.
- `OPENAI_STATUS_TTL_SECONDS` padrão 30 → 600: o painel consulta `/api/status` a
  cada 5 s e o cache antigo pingava a OpenAI cerca de duas vezes por minuto.
- Cache local de análises idênticas (imagem + contexto + modelo + versão do
  contrato), TTL de 15 min e 8 entradas, com `X-ZNX-Cache: hit`; configurável por
  `ZNX_CACHE_TTL_SECONDS` e `ZNX_CACHE_MAX_ENTRIES`.
- Console passa a mostrar o consumo real: `tokens: X entrada / Y saida`.

## 7.0

- Prompt renomeado e versionado em `prompts/chart-analysis-v7.0.txt`.
- `ContractVersion` e mensagens de falha padronizadas; servidor separado em
  `server.ps1` e contrato em `analysis-contract.psm1`.
- Suíte de replay (`tools/live-suite.ps1`) para capturas reais.

## 6.2

- Versão de segurança preservada em `_backup/v6.2/` antes da evolução do
  contrato e do prompt.
