const fs = require("fs");
const path = require("path");
const { normalizeAnalysisPayload, getAnalysisPresentation } = require("../assets/js/analysis-format.js");

const fixturePath = process.argv[2];
if (!fixturePath) {
  console.error("Uso: node tools/render-analysis.js <payload-validado.json>");
  process.exit(2);
}

const payload = JSON.parse(fs.readFileSync(fixturePath, "utf8").replace(/^\uFEFF/, ""));
const result = normalizeAnalysisPayload(payload);
const section = (title, value) => {
  console.log(`\n=== ${title} ===`);
  console.log(value);
};

console.log(`Fixture: ${process.argv[3] || path.basename(fixturePath)}`);
const presentation = getAnalysisPresentation(result);
section("TITULO", presentation.title);
section("SELO", presentation.badge);
section("RESUMO", result.summary);
section("TENDENCIA", result.trend);
section("PRICE ACTION", result.price_action);
section("NIVEIS", result.levels.length > 0 ? result.levels.join(" | ") : "Nenhuma região registrada na leitura.");
section("CONTEXTO", result.signal_timing_text);
section("EVIDENCIAS", result.reasons.map((reason) => `- ${reason}`).join("\n"));
section("RISCO", `Risco e limitações: ${result.risk}${result.conflict_notes ? ` Conflito: ${result.conflict_notes}` : ""}`);
