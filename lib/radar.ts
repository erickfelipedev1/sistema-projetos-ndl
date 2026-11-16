// Habilitação de Radar (Siscomex) — rótulos e resumo do limite
import type { ClienteRadar } from "./types";
import { dataBR } from "./format";

export const RADAR_STATUS: Record<ClienteRadar["status"], string> = {
  documentos: "Aguardando documentos do cliente",
  em_analise: "Em análise na Receita Federal",
  habilitado: "Habilitado",
  indeferido: "Indeferido",
  inativo: "Inativo",
};

/** ex.: "Limitada · US$ 150.000 por semestre · validade 07/08/2027" */
export function radarResumo(r: ClienteRadar | null | undefined) {
  if (!r) return null;
  const partes: string[] = [];
  if (r.modalidade) partes.push(r.modalidade);
  if (r.limite_usd != null) {
    partes.push(`US$ ${Number(r.limite_usd).toLocaleString("pt-BR", { maximumFractionDigits: 2 })}${r.limite_periodo ? ` por ${r.limite_periodo}` : ""}`);
  }
  if (r.validade_ate) partes.push(`validade ${dataBR(r.validade_ate)}`);
  return partes.length ? partes.join(" · ") : null;
}
