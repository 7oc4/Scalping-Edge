/* Tipos compartilhados do painel. O modulo de formatacao continua em
   assets/js/analysis-format.js porque o replay em Node tambem o consome. */

type AnalysisDirection = "BUY" | "SELL" | "NEUTRAL";

interface AnalysisLevelMark {
  type: "support" | "resistance" | "breakout" | "retest" | "other";
  typeLabel: string;
  value: number | null;
  region: string;
  reason: string;
}

interface NormalizedAnalysis {
  image_class: string;
  chart_type: string | null;
  price_axis_readable: boolean;
  price_axis_min: number | null;
  price_axis_max: number | null;
  asset_visible: string | null;
  timeframe_visible: string | null;
  asset_assumed: string | null;
  timeframe_assumed: string | null;
  last_candle_status: "closed" | "possibly_open" | "unknown";
  visual_quality: number;
  analysis_coverage: number;
  confidence: number;
  direction: AnalysisDirection;
  trend: string;
  price_action: string;
  levels: string[];
  level_marks: AnalysisLevelMark[];
  reasons: string[];
  risk: string;
  conflict_notes: string;
  summary: string;
  signal_timing: { action: "BUY" | "SELL" | "WAIT" };
  signal_timing_text: string;
}

interface AnalysisPresentation {
  pendingEntry: boolean;
  title: string;
  badge: string;
}

interface AnalysisFormatApi {
  normalizeAnalysisPayload(payload: unknown): NormalizedAnalysis;
  getAnalysisPresentation(payload: NormalizedAnalysis): AnalysisPresentation;
}

interface Window {
  AnalysisFormat: AnalysisFormatApi;
}
