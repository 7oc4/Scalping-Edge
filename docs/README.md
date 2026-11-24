# Scalping Edge — análise visual com OpenAI

O Scalping Edge envia a imagem do gráfico à API da OpenAI para uma análise visual
conforme o prompt V8.0 em `prompts\chart-analysis-v8.0.txt`. O servidor valida o
JSON estruturado, aplica as travas de classe/confiança e devolve tendência,
avaliações independentes de BUY/SELL, Price Action, níveis, indicadores,
evidências, timing hipotético e limitações.
As últimas 25 análises e miniaturas ficam salvas no armazenamento local do navegador.

## Estrutura

```
znx-market-analyzer/
├─ pages/index.html            Interface (pt-BR, acessível)
├─ pages/radar.html            Radar de mercado e gráfico
├─ pages/historico.html        Histórico local das análises
├─ pages/noticias.html         Notícias de mercado
├─ src/server.ps1              HTTP local, estáticos, cliente OpenAI e retry
├─ src/analysis-contract.psm1  Schema JSON + validação e travas de decisão
├─ src/market.psm1             Cotações em tempo real, candles, varredor e backtest
├─ assets/css/style.css        Estilos e design tokens
├─ assets/ts/app.ts            Fonte TypeScript do painel (typecheck em build)
├─ assets/js/app.js            Saída compilada do TypeScript (não editar)
├─ assets/js/analysis-format.js Normalização/formatação do payload (função pura)
├─ prompts/                    Prompt mestre versionado (v8.0)
├─ tests/                      Suítes Pester do contrato e das rotas HTTP
├─ tests/fixtures/             Payloads sintéticos (prefixo synthetic-) para replay
├─ tools/                      Replay, suíte viva, registro de desfecho e métricas
├─ docs/                       README.md e CHANGELOG.md
├─ logs/                       analyses.jsonl, feedback.jsonl e última falha (gerado)
├─ data/                       outcomes.jsonl com o resultado real (gerado)
├─ start.bat                  Entrada (duplo clique): pede a chave e inicia
├─ src/start.ps1               Laço que reinicia o servidor quando pedido
├─ tools/setup.ps1             Diagnóstico do ambiente
└─ package.json                Checagem de sintaxe JS e execução dos testes
```

Camadas: o navegador conversa com `/api/status`, `/api/analyze`, `/api/feedback`,
`/api/calibration`, `/api/market`, `/api/news`, `/api/chart`, `/api/scanner`,
`/api/backtest` (inclusive `/api/backtest/start` e `/api/backtest/progress`) e
`/api/plan`. Toda regra de negócio e validação do JSON de análise é aplicada em
`analysis-contract.psm1`; a matemática de mercado fica em `market.psm1`.

## Regra de dados: só tempo real

O projeto não exibe dado atrasado, estimado, simulado ou inventado. Só entra no
radar o ativo que a fonte entrega em tempo real (`delaySeconds = 0`): hoje são
4 criptos (Binance) e 3 pares de moedas (FX) no radar, com DOGE no varredor.
Índices, ações e commodities ficam de fora porque o scanner público do
TradingView os entrega com 10/15 min de atraso — aparecer com preço velho seria
mentir. Quando a fonte não responde, a tela mostra a hora da última leitura real
em vez de fingir atualização. A mesma regra está registrada em `AGENTS.md`.

## Radar, gráfico e Máquina do tempo

- **Mercado ao vivo**: `/api/market` é consultado a cada ~500 ms depois que a
  requisição anterior termina (nunca empilha requisições). O servidor mantém
  cache de 1 s para a cotação do TradingView e de 90/180 s apenas para o
  histórico de candles e a referência em R$. A lista é atualizada no lugar
  (só o preço muda), sem reconstruir a tela. O indicador de radar gira apenas
  durante uma busca real; terminada a leitura ele fica em “Tempo real”, e em
  “Fonte sem resposta” só quando três leituras seguidas falham (ou não há
  nenhuma ainda).
- **Falha por ativo, não do painel**: ativo sem preço ao vivo sai da lista e é
  apenas contado; o vermelho de erro é reservado a zero ativos em tempo real,
  quando o painel fica vazio e explica o motivo.
- **Animação = estado**: `is-scanning` liga a varredura circular, `is-live` o
  ping do selo, `is-error` o estado de falha. Sem requisição em andamento não
  existe `is-scanning`, então nada gira “de enfeite”.
- **Gráfico**: candles reais da API pública de charts do Yahoo Finance com o
  preço ao vivo do TradingView; as duas fontes aparecem na tela. Nenhum valor é
  interpolado ou estimado.
- **Máquina do tempo**: o backtest roda em um runspace separado e publica o
  progresso real (candles processados, trades encontrados e reamostragens
  concluídas) em `/api/backtest/progress`. A tela tem animação própria — faixa
  ciano com linha de leitura horizontal e brilho na barra, ligada por
  `is-running` —, sem varredura de radar: quando o total ainda é desconhecido
  (download dos candles), a barra fica **indeterminada** em vez de fingir
  percentual. O resultado é apresentado como simulação educativa, não
  recomendação.
- **Notícias**: `/api/news` é verificado a cada 1 minuto, com horário da última
  atualização e contagem para a próxima verificação. Se a fonte falhar, a lista
  anterior permanece com o horário dela e o erro é explícito — nenhum card é
  inventado.

## Configuração no Windows

1. Crie uma chave secreta em <https://platform.openai.com/api-keys>.
2. Na pasta do projeto, execute `.\start.bat` no PowerShell.
3. Cole a chave quando o servidor solicitar. A entrada fica oculta e a chave
   é mantida na memória do processo, sem ser escrita nos arquivos do projeto.
   - Prefixos `Bearer ` colados por engano são removidos automaticamente.
4. Acesse <http://127.0.0.1:8765/> e mantenha a janela do servidor aberta.

## Testes

```powershell
npm test          # sintaxe JS + contrato + rotas HTTP
npm run replay -- -FixturePath tests/fixtures/synthetic-analysis-b-neutral.json
```

`tests/AnalysisContract.Tests.ps1` roda sem chave da OpenAI e cobre as travas de
decisão, a coerência entre o schema JSON e o validador, o alinhamento entre versão
do contrato e arquivo de prompt e o replay das fixtures. `tests/Server.Tests.ps1`
sobe o servidor na porta 8799 (`ZNX_PORT`) e verifica `/api/status`, estáticos,
403 de origem, 405, 415, 503 sem chave, 413 de corpo grande e o registro de
feedback em JSONL (com `ZNX_LOG_DIR` temporário), o início e o progresso real do
backtest e a rota de calibração. A validação do preparo de imagem fica no
describe 19 do contrato (19.1–19.7). Também é possível
executar `tests/run-tests.bat` (com pausa no final) ou `.\tools\setup.ps1` para o
diagnóstico completo do ambiente.

O comando `replay` valida a fixture no contrato e imprime o mesmo texto que o
painel mostraria — útil para revisar a redação da análise sem chamar a OpenAI.

### Suíte viva (consome créditos)

`tools/live-suite.ps1` envia uma pasta de capturas reais para o servidor em execução,
salva a resposta validada de cada imagem e grava um CSV com classe, direção, ação,
confidence, cobertura, número de limitações e de níveis:

```powershell
./tools/live-suite.ps1 -ImageDir "./capturas" -OutDir "live-results"
```

Fica fora do `npm test` de propósito: depende da `OPENAI_API_KEY` e de gráficos
reais. Sem esse lote, nenhuma mudança de prompt pode ser chamada de melhoria.
Cada rodada grava também `meta.json` com modelo, versão do contrato, modo de
realce e quantas respostas vieram do cache. O CSV ganhou `id` (o mesmo
`X-ZNX-Analysis-Id` da resposta), `cache` e `realce`. Se houver cache hit, a
suíte avisa: reinicie o servidor antes de comparar prompt ou modelo.

## Medição de acerto e calibração

O servidor grava toda análise aprovada em `logs/analyses.jsonl` com um id estável,
direção, ação, confidence, classe e hash da imagem. O painel mostra três botões
(Acertou / Errou / Nível inventado) na resposta e envia o veredito para
`/api/feedback`, que grava `logs/feedback.jsonl`. O resultado real do mercado é
registrado manualmente depois:

```powershell
./tools/record-outcome.ps1 -AnalysisId <id> -Outcome favorable|adverse|neutral `
  -HorizonMinutes 30 -PriceAtSignal 1700 -PriceAfter 1720

./tools/evaluate.ps1
```

`favorable` significa que o preço andou na direção indicada; `adverse`, o
contrário; `neutral`, sem movimento claro. `evaluate.ps1` calcula taxa de acerto
direcional (só BUY/SELL com desfecho definido), taxa de WAIT, contagem de
feedback e calibração por faixa de confidence (`viés = acerto - confidence`, com
positivo indicando que a IA se subestima). O relatório sai em `evaluation/`.

Sem esses arquivos preenchidos, o projeto continua sem saber se acerta — ele só
sabe que o JSON está correto. Nenhum número de acerto é inventado: com zero
desfechos, o relatório diz zero.

O **erro quadrático de consistência** compara o índice de confidence técnico — que
mede força, clareza e consistência das evidências, não chance de acerto — com o
desfecho real registrado: cada desfecho pontuado vira `(p - o)^2`, com
`p = confidence/100` limitado a 0..1, `o = 1` para `favorable` e `0` para `adverse`,
e o resultado é a média (`confidenceOutcomeError`, 4 casas). **Menor erro significa
menor discrepância numérica** entre o índice e o que o mercado fez. Não é
probabilidade de acerto, não é Brier score probabilístico, não é skill contra chute
de moeda e não comprova vantagem operacional: é diagnóstico do próprio índice. Por
faixa saem `sampleCount`, `confidenceMean`, `favorableRate` e
`averageSquaredError`; faixa sem amostra fica nula. Sem desfechos reais de BUY/SELL
(NEUTRAL, WAIT e `neutral` não contam), o campo fica nulo e `sampleCount` é 0;
registro sem confidence numérico válido entre 0 e 100 é contado como inválido e
nunca vira amostra.

## Configuração de desempenho e qualidade

Todas as variáveis são opcionais. Definir antes de iniciar o servidor:

```powershell
# Modelo (gpt-4o-mini = rápido e barato; gpt-4o = preciso e ~10-15x mais caro)
$env:OPENAI_MODEL = "gpt-4o-mini"

# Máximo de tokens de saída (padrão 4000; se truncar, o servidor tenta novamente com até 16000)
$env:OPENAI_MAX_TOKENS = "4000"

# Detalhe da imagem: "low" (~85 tokens), "high" (~500-2000 tokens), "auto"
$env:OPENAI_IMAGE_DETAIL = "high"

# Timeout em segundos para chamada à OpenAI
$env:OPENAI_TIMEOUT_SECONDS = "180"

# Cache do /api/status em segundos (padrão 600: o painel consulta a cada 5 s)
$env:OPENAI_STATUS_TTL_SECONDS = "600"

# Número de retries automáticos para 429/5xx transitórios (padrão 1)
$env:OPENAI_MAX_RETRIES = "1"

# Cache de análises idênticas, em segundos (padrão 900; 0 desativa)
$env:ZNX_CACHE_TTL_SECONDS = "900"

# Máximo de análises guardadas no cache local (padrão 8)
$env:ZNX_CACHE_MAX_ENTRIES = "8"

# Limite local de análises por minuto (padrão 10; 0 desativa)
$env:ZNX_RATE_LIMIT_PER_MINUTE = "10"

# Tempo máximo de leitura do corpo da requisição, em segundos (padrão 30)
$env:ZNX_READ_TIMEOUT_SECONDS = "30"

# Preparo da imagem antes do envio: "auto", "on" ou "off"
$env:ZNX_IMAGE_ENHANCE = "auto"

# Releitura automática quando a 1ª leitura responde classe C/D: "on" ou "off"
$env:ZNX_REREAD = "on"

# Pasta de logs/feedback (padrão: logs\; útil para testes isolados)
$env:ZNX_LOG_DIR = ""

.\start.bat
```

## Limitações conhecidas

- O servidor é local, single-thread e síncrono: atende uma requisição por vez.
  A Máquina do tempo roda em runspace separado e não bloqueia o radar; já uma
  chamada de análise à OpenAI ocupa o atendimento até responder.
- Cliente que desiste da requisição (reload da página, aba fechada, preconnect do
  navegador) não encerra mais o servidor: a falha de escrita/conexão é descartada
  e o laço continua atendendo. Teste `10.18` cobre esse caso.
- Reparos determinísticos antes da rejeição: score decimal é arredondado, score
  fora de 0..100 é limitado e `status supported` sem o piso de 70 vira `weak`
  (a direção correspondente cai para NEUTRAL/WAIT). Um erro de forma nesses
  campos não descarta mais a análise inteira nem exige nova chamada de API;
  estruturas realmente quebradas continuam sendo rejeitadas.
- Trava de lateralização no código: com `trend.main = lateralização` e os dois
  scores abaixo de 70, a direção cai para NEUTRAL/WAIT mesmo que o modelo tenha
  devolvido um viés. A trava só enxerga os scores — o contrato não registra a
  posição do preço dentro da faixa, então uma lateralização com score alto em um
  dos lados (rejeição alegada em um extremo) continua passando.
- Reenviar a mesma imagem com o mesmo contexto dentro do TTL devolve a análise
  guardada em memória, sem chamar a OpenAI (resposta com `X-ZNX-Cache: hit`).
- O endpoint confere a assinatura real do arquivo (magic bytes PNG/JPG/WEBP) e
  aplica limite local de análises por minuto; nenhum dos dois substitui a
  autenticação da OpenAI, que continua sendo a única barreira de custo.
- As regras do contrato existem em três camadas (schema JSON, validador PowerShell
  e validação defensiva no `app.js`). A suíte Pester garante que schema e validador
  não divirjam; o `app.js` valida de novo por segurança, mas o servidor é a
  autoridade final.
- O prompt V8.0 tem ~52 KB (≈15 mil tokens) e é enviado inteiro em cada análise.
  O prefixo é estável, então a OpenAI aplica cache automático de prompt e o custo
  dominante por requisição passa a ser a imagem em `detail: high`. O consumo real
  de cada chamada aparece no console do servidor (`tokens: entrada / saida`).
- As fixtures em `tests/fixtures/` são sintéticas (prefixo `synthetic-`):
  reproduzem os formatos de saída observados, não são capturas reais da OpenAI e
  nunca são enviadas ao painel do usuário.
- O raciocínio estruturado da V8.0 é interno: o `response_format` strict aceita
  apenas o JSON do schema, então o modelo não escreve o bloco `<thinking>` na
  resposta. Ainda assim o servidor remove esse bloco, caso uma configuração não
  estrita o emita.
- O preparo de imagem é adaptativo e conservador: recorta **somente** bordas
  comprovadamente uniformes (limite de 12% por lado, nunca sobrando menos de 60%
  da imagem) e aplica 1,25 de contraste só quando o miolo do gráfico está lavado.
  Sidebar, volume e eixo não são cortados porque não são uniformes. WEBP não é
  reprocessado (GDI+ não decodifica o formato) e qualquer falha do GDI+ devolve a
  imagem original. O modo entra na chave de cache e no cabeçalho
  `X-ZNX-Preprocess`; o ganho ainda precisa ser medido com `record-outcome`/
  `evaluate`.
- Recusa de leitura (classe C/D) não é erro de servidor: é o modelo dizendo que
  não encontrou gráfico. Nesse caso o servidor faz **uma** releitura automática
  com a imagem original (sem realce) e um checklist visual, e só troca a resposta
  se a classe melhorar (A > B > C > D); se a releitura falhar, a primeira leitura
  é mantida. `ZNX_REREAD=off` desliga. O campo `reread` em `logs/analyses.jsonl`
  registra `improved`, `kept` ou `failed`, e a captura recusada fica em
  `logs/last-refused-image.<ext>` para reproduzir o caso sem gastar nova chamada.
  Isso custa no máximo uma chamada extra, e só quando a primeira já falhou.
- O overlay dos níveis no print é **aproximado e declarado como tal**: as linhas
  usam a escala `price_axis_min`/`max` que a IA leu, limitadas a níveis com preço
  numérico dentro dessa faixa. Se o eixo não foi legível, o overlay fica desligado
  em vez de estimar posição; ele não substitui o pixel exato da plataforma.
- A calibração de confidence é exposta em `/api/calibration` e mostrada ao lado do
  número da IA (acertos do feedback e desfechos reais por faixa). O servidor não
  altera o confidence devolvido pelo modelo: sem amostra, a faixa aparece como
  “sem amostra suficiente” em vez de receber um ajuste inventado.
- A trava de escala usa `price_axis_min`/`max` declarados pela IA; todo nível
  numérico é conferido contra essa faixa e o que estiver fora dela é descartado.
  Preços citados em texto livre (summary, evidências) continuam dependendo de
  conferência visual.