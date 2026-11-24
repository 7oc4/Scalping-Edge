/* Normalizacao e formatacao do payload de analise. Função pura: usada no navegador e nos testes Node. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.AnalysisFormat = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
function getAnalysisPresentation(payload) {
  const directionLabels = {
    BUY: "COMPRAR",
    SELL: "VENDER",
    NEUTRAL: "AGUARDAR",
  };
  const hasDirection = payload.direction !== "NEUTRAL";
  const pendingEntry = hasDirection && payload.signal_timing.action === "WAIT";
  const directionalLabel = payload.direction === "BUY" ? "comprador" : "vendedor";
  return {
    pendingEntry,
    title: pendingEntry
      ? `Viés ${directionalLabel} · entrada aguardando confirmação`
      : `Conclusão visual: ${directionLabels[payload.direction]}`,
    badge: pendingEntry
      ? `${directionLabels[payload.direction]} (viés)`
      : directionLabels[payload.direction],
  };
}

function normalizeAnalysisPayload(payload) {
  const isStringArray = (value) => Array.isArray(value) &&
    value.every((item) => typeof item === "string");
  const isNullableString = (value) => value === null || typeof value === "string";
  const isNullableNumber = (value) => value === null ||
    (typeof value === "number" && Number.isFinite(value));
  const isStatus = (value) =>
    ["supported", "weak", "contradicted", "unavailable"].includes(value);
  const isTrendValue = (value) =>
    ["alta", "baixa", "lateralização", "indefinida"].includes(value);
  const isCandleStatus = (value) =>
    ["closed", "possibly_open", "unknown"].includes(value);

  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("A IA retornou uma análise incompleta. Campo inválido: conteúdo (não é um objeto).");
  }

  // Cada checagem nomeia o campo que falhou. Antes eram 60+ condicoes em uma
  // unica expressao e o erro so dizia "analise incompleta", sem indicar qual
  // delas quebrou. A ordem importa: um campo pai precisa passar antes dos
  // filhos, porque as checagens seguintes assumem a estrutura validada.
  const directional = payload.directional_assessment;
  const structureChecks = [
    ["image_class", () => ["A", "B", "C", "D"].includes(payload.image_class)],
    ["chart_type", () => payload.chart_type === null || typeof payload.chart_type === "string"],
    ["price_axis_readable", () => typeof payload.price_axis_readable === "boolean"],
    ["price_axis_min", () => isNullableNumber(payload.price_axis_min)],
    ["price_axis_max", () => isNullableNumber(payload.price_axis_max)],
    ["price_axis_min/price_axis_max (eixo legível)", () => !payload.price_axis_readable ||
      (payload.price_axis_min !== null && payload.price_axis_max !== null &&
        payload.price_axis_min < payload.price_axis_max)],
    ["price_axis_min/price_axis_max (eixo ilegível)", () => payload.price_axis_readable ||
      (payload.price_axis_min === null && payload.price_axis_max === null)],
    ["asset_visible", () => isNullableString(payload.asset_visible)],
    ["timeframe_visible", () => isNullableString(payload.timeframe_visible)],
    ["direction", () => ["BUY", "SELL", "NEUTRAL"].includes(payload.direction)],
    ["directional_assessment", () => Boolean(directional) && typeof directional === "object"],
    ["directional_assessment.buy_score", () => Number.isInteger(directional.buy_score)],
    ["directional_assessment.sell_score", () => Number.isInteger(directional.sell_score)],
    ["directional_assessment.buy_score/sell_score (faixa 0..100)", () =>
      [directional.buy_score, directional.sell_score]
        .every((score) => score >= 0 && score <= 100)],
    ["directional_assessment.buy_status", () => isStatus(directional.buy_status)],
    ["directional_assessment.sell_status", () => isStatus(directional.sell_status)],
    ["directional_assessment.buy_evidence", () => isStringArray(directional.buy_evidence)],
    ["directional_assessment.sell_evidence", () => isStringArray(directional.sell_evidence)],
    ["directional_assessment.selected_reason", () =>
      typeof directional.selected_reason === "string" &&
      directional.selected_reason.trim().length > 0],
    ["directional_assessment (status supported exige score >= 70)", () =>
      !(directional.buy_status === "supported" && directional.buy_score < 70) &&
      !(directional.sell_status === "supported" && directional.sell_score < 70)],
    ["trend.main", () => isTrendValue(payload.trend?.main)],
    ["trend.micro", () => isTrendValue(payload.trend?.micro)],
    ["trend.structure", () => isStringArray(payload.trend?.structure)],
    ["trend.explanation", () => typeof payload.trend?.explanation === "string"],
    ["visual_quality", () => Number.isInteger(payload.visual_quality)],
    ["analysis_coverage", () => Number.isInteger(payload.analysis_coverage)],
    ["confidence", () => Number.isInteger(payload.confidence)],
    ["visual_quality/analysis_coverage/confidence (faixa 0..100)", () =>
      [payload.visual_quality, payload.analysis_coverage, payload.confidence]
        .every((value) => value >= 0 && value <= 100)],
    ["last_candle_status", () => isCandleStatus(payload.last_candle_status)],
    ["summary", () => typeof payload.summary === "string"],
    ["evidence_for", () => isStringArray(payload.evidence_for)],
    ["evidence_against", () => isStringArray(payload.evidence_against)],
    ["conflict_notes", () => isStringArray(payload.conflict_notes)],
    ["risk", () => isStringArray(payload.risk)],
    ["levels", () => Array.isArray(payload.levels) &&
      payload.levels.every((level) =>
        level && ["support", "resistance", "breakout", "retest", "other"].includes(level.type) &&
        (level.value === null || typeof level.value === "number") &&
        typeof level.region === "string" && typeof level.reason === "string")],
    ["patterns", () => Array.isArray(payload.patterns) &&
      payload.patterns.every((pattern) =>
        pattern && typeof pattern.name === "string" &&
        ["incomplete", "visually_confirmed", "invalidated"].includes(pattern.status) &&
        isStringArray(pattern.evidence) &&
        typeof pattern.confirmation === "string" &&
        typeof pattern.invalidation === "string")],
    ["indicators", () => Array.isArray(payload.indicators) &&
      payload.indicators.every((indicator) =>
        indicator && typeof indicator.name === "string" &&
        typeof indicator.visible === "boolean" &&
        isStringArray(indicator.observations) &&
        typeof indicator.interpretation === "string" &&
        typeof indicator.conflict === "string")],
    ["volume", () => Boolean(payload.volume) && typeof payload.volume === "object"],
    ["volume.visible", () => typeof payload.volume.visible === "boolean"],
    ["volume.observations", () => isStringArray(payload.volume.observations)],
    ["volume.interpretation", () => typeof payload.volume.interpretation === "string"],
    ["price_action.observations", () => isStringArray(payload.price_action?.observations)],
    ["price_action.interpretations", () => isStringArray(payload.price_action?.interpretations)],
    ["price_action.conditions", () => isStringArray(payload.price_action?.conditions)],
    ["signal_timing", () => Boolean(payload.signal_timing) &&
      typeof payload.signal_timing === "object"],
    ["signal_timing.action", () => ["BUY", "SELL", "WAIT"].includes(payload.signal_timing.action)],
    ["signal_timing.signal_candle", () =>
      isCandleStatus(payload.signal_timing.signal_candle)],
    ["signal_timing.entry_timing", () => typeof payload.signal_timing.entry_timing === "string"],
    ["signal_timing.exit_plan", () => typeof payload.signal_timing.exit_plan === "string"],
    ["signal_timing.holding_horizon", () =>
      typeof payload.signal_timing.holding_horizon === "string"],
    ["signal_timing.confirmation_required", () =>
      isStringArray(payload.signal_timing.confirmation_required)],
    ["signal_timing.invalidation", () => isStringArray(payload.signal_timing.invalidation)],
  ];
  for (const [field, isValid] of structureChecks) {
    if (!isValid()) {
      throw new Error(`A IA retornou uma análise incompleta. Campo inválido: ${field}.`);
    }
  }

  const assessment = directional;
  const candidate = payload.direction === "BUY"
    ? { status: assessment.buy_status, score: assessment.buy_score, other: assessment.sell_score }
    : { status: assessment.sell_status, score: assessment.sell_score, other: assessment.buy_score };
  const confirmedEntry = payload.signal_timing.action !== "WAIT";
  // Mesmo tratamento: cada regra de segurança tem nome, para o erro dizer qual
  // coerência falhou em vez de "campos contraditórios".
  const safetyChecks = [
    ["viés direcional só é aceito na classe A",
      () => payload.image_class === "A" || payload.direction === "NEUTRAL"],
    ["classe B limita a confiança a 60",
      () => payload.image_class !== "B" || payload.confidence <= 60],
    ["confidence precisa ser múltiplo de 5",
      () => payload.confidence % 5 === 0],
    ["cobertura < 40 limita a confiança a 45",
      () => payload.analysis_coverage >= 40 || payload.confidence <= 45],
    ["cobertura 40..59 limita a confiança a 60",
      () => payload.analysis_coverage < 40 || payload.analysis_coverage >= 60 ||
        payload.confidence <= 60],
    ["cobertura 60..79 limita a confiança a 80",
      () => payload.analysis_coverage < 60 || payload.analysis_coverage >= 80 ||
        payload.confidence <= 80],
    ["cobertura >= 80 limita a confiança a 95",
      () => payload.analysis_coverage < 80 || payload.confidence <= 95],
    ["classes C/D exigem confiança 0, tendência indefinida e nenhum nível",
      () => !["C", "D"].includes(payload.image_class) ||
        (payload.confidence === 0 && payload.trend.main === "indefinida" &&
          payload.trend.micro === "indefinida" && payload.levels.length === 0)],
    ["NEUTRAL exige ação WAIT",
      () => payload.direction !== "NEUTRAL" || payload.signal_timing.action === "WAIT"],
    ["ação confirmada precisa coincidir com a direção",
      () => !confirmedEntry || payload.signal_timing.action === payload.direction],
    ["ação confirmada exige velas fechadas e nenhuma confirmação pendente",
      () => !confirmedEntry ||
        (payload.signal_timing.signal_candle === "closed" &&
          payload.last_candle_status === "closed" &&
          payload.signal_timing.confirmation_required.length === 0)],
    ["viés exige classe A, status supported, score >= 70, margem >= 10, invalidação e nenhum conflito",
      () => payload.direction === "NEUTRAL" ||
        (payload.image_class === "A" &&
          candidate.status === "supported" &&
          candidate.score >= 70 &&
          candidate.score - candidate.other >= 10 &&
          payload.signal_timing.invalidation.length > 0 &&
          payload.conflict_notes.length === 0)],
    ["scores a menos de 10 pontos não sustentam viés",
      () => payload.direction === "NEUTRAL" ||
        !(assessment.buy_score >= 70 && assessment.sell_score >= 70 &&
          Math.abs(assessment.buy_score - assessment.sell_score) < 10)],
  ];
  for (const [rule, isRespected] of safetyChecks) {
    if (!isRespected()) {
      throw new Error(
        `A IA retornou campos que contradizem as regras de segurança da análise. Regra violada: ${rule}.`
      );
    }
  }

  const levelLabels = {
    support: "Suporte",
    resistance: "Resistência",
    breakout: "Rompimento",
    retest: "Reteste",
    other: "Outra região",
  };
  const trendLabels = {
    alta: "alta",
    baixa: "baixa",
    lateralização: "lateral",
    indefinida: "indefinida",
  };
  const candleLabels = {
    closed: "fechada visualmente",
    possibly_open: "possivelmente em formação",
    unknown: "não foi possível determinar",
  };
  const actionLabels = {
    BUY: "viés comprador condicional",
    SELL: "viés vendedor condicional",
    WAIT: "aguardar",
  };
  const timing = payload.signal_timing;
  const timingText = [
    `Ação: ${actionLabels[timing.action]}`,
    `Vela de sinal: ${candleLabels[timing.signal_candle]}`,
    timing.entry_timing,
    timing.exit_plan,
    timing.holding_horizon,
  ].filter(Boolean).join(" · ");
  const indicatorEvidence = payload.indicators.map((indicator) =>
    `${indicator.name}: ${indicator.visible
      ? [...indicator.observations, indicator.interpretation].filter(Boolean).join("; ") || "visível, sem leitura conclusiva"
      : "não visível ou ilegível"}${indicator.conflict ? ` (conflito: ${indicator.conflict})` : ""}`);
  const patternEvidence = payload.patterns.map((pattern) =>
    `Padrão ${pattern.name} (${pattern.status}): ${[
      ...pattern.evidence,
      pattern.confirmation,
      pattern.invalidation,
    ].filter(Boolean).join("; ")}`);
  const directionalEvidenceText = (side, score, status, evidence) => {
    const sideLabel = side === "BUY" ? "compradora" : "vendedora";
    const oppositeTrend = side === "BUY" ? "baixa" : "alta";
    const trendContext = payload.trend.main === oppositeTrend
      ? `A tendência principal registrada é de ${oppositeTrend}, o que contraria a hipótese ${sideLabel}.`
      : payload.trend.main === "indefinida"
        ? `A tendência principal foi classificada como indefinida; não há confirmação estrutural registrada para a hipótese ${sideLabel}.`
        : "";
    const evidenceText = evidence.length > 0
      ? evidence.join("; ")
      : ["A", "B"].includes(payload.image_class)
        ? `O relatório não registrou evidências direcionais específicas para a hipótese ${sideLabel}.`
        : "A imagem não permite avaliar este lado.";
    const statusLabels = {
      supported: "sustentado",
      weak: "fraco",
      contradicted: "contradito",
      unavailable: ["A", "B"].includes(payload.image_class)
        ? "sem avaliação direcional suficiente"
        : "indisponível",
    };
    const scoreLabel = `${score}/100`;
    return `${side} (${scoreLabel}, ${statusLabels[status]}): ${[evidenceText, trendContext]
      .filter(Boolean).join(" ")}`;
  };
  const directionalEvidence = [
    directionalEvidenceText("BUY", directional.buy_score, directional.buy_status, directional.buy_evidence),
    directionalEvidenceText("SELL", directional.sell_score, directional.sell_status, directional.sell_evidence),
    `Comparação BUY/SELL: ${directional.selected_reason}`,
  ];

  return {
    ...payload,
    asset_assumed: payload.asset_visible,
    timeframe_assumed: payload.timeframe_visible,
    trend: `${trendLabels[payload.trend.main]} (micro: ${trendLabels[payload.trend.micro]})${payload.trend.explanation ? `. ${payload.trend.explanation}` : ""}`,
    price_action: [
      ...payload.price_action.observations,
      ...payload.price_action.interpretations,
      ...payload.price_action.conditions,
    ].join(" "),
    levels: payload.levels.map((level) => {
      const location = level.value === null ? level.region : level.value;
      return `${levelLabels[level.type] || level.type}: ${location}${level.reason ? ` — ${level.reason}` : ""}`;
    }),
    // Valores numericos preservados (os textos acima sao para leitura). O
    // overlay no print usa apenas nivel com preco real e eixo legivel.
    level_marks: payload.levels.map((level) => ({
      type: level.type,
      typeLabel: levelLabels[level.type] || level.type,
      value: typeof level.value === "number" ? level.value : null,
      region: level.region,
      reason: level.reason,
    })),
    reasons: [
      ...directionalEvidence,
      ...payload.evidence_for,
      ...payload.evidence_against.map((evidence) => `Contra-hipótese: ${evidence}`),
      ...indicatorEvidence,
      ...patternEvidence,
      ...payload.volume.observations.map((observation) => `Volume: ${observation}`),
      ...payload.signal_timing.confirmation_required.map((condition) => `Confirmação pendente: ${condition}`),
      ...payload.signal_timing.invalidation.map((condition) => `Invalidação: ${condition}`),
    ],
    risk: payload.risk.join(" "),
    conflict_notes: payload.conflict_notes.join(" "),
    signal_timing_text: timingText,
  };
}
  return { normalizeAnalysisPayload, getAnalysisPresentation };
});
