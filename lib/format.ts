import type { Profile } from "./types";

export function dataBR(d: string | null | undefined) {
  if (!d) return "—";
  const [y, m, day] = d.slice(0, 10).split("-");
  return `${day}/${m}/${y}`;
}

export function dataHoraBR(d: string | null | undefined) {
  if (!d) return "—";
  return new Date(d).toLocaleString("pt-BR", {
    timeZone: "America/Sao_Paulo",
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** perfil sem nome costuma ter o e-mail no lugar: mostra só a parte antes do @, com iniciais maiúsculas */
export function nomeExibicao(nome: string | null | undefined) {
  const n = (nome ?? "").trim();
  if (!n.includes("@")) return n;
  return n.split("@")[0].split(/[._-]+/).filter(Boolean).map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join(" ");
}

export function bytesTexto(b: number | null) {
  if (b == null) return "";
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${Math.round(b / 1024)} KB`;
  return `${(b / 1024 / 1024).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} MB`;
}

export function nomesResponsaveis(ids: string[], label: string | null, perfis: Map<string, Profile>) {
  const nomes = ids.map((id) => nomeExibicao(perfis.get(id)?.nome)).filter(Boolean) as string[];
  if (nomes.length) return nomes.join(" / ");
  return label ?? "Sem responsável";
}

export function mapaPerfis(perfis: Profile[] | null) {
  return new Map((perfis ?? []).map((p) => [p.id, p]));
}

type PrazosEtapa = {
  tipo: string;
  prazo_dias_uteis: number | null;
  prazo_flex: number | null;
  prazo_full: number | null;
  prazo_premium: number | null;
  prazo_simulacao?: number | null;
  prazo_com_certificacao: number | null;
};

// texto curto dos prazos de uma etapa: "Flex 10 · Full 15 · Premium 25 d.u." / "1 d.u. (2 c/ certificação)"
export function prazoEtapaTexto(e: PrazosEtapa) {
  if (e.tipo === "marco") return "Marco";
  if (e.tipo === "final") return "Fim";
  if (e.prazo_flex !== null || e.prazo_full !== null || e.prazo_premium !== null) {
    const p = (v: number | null) => v ?? e.prazo_dias_uteis ?? "—";
    return `Flex ${p(e.prazo_flex)} · Full ${p(e.prazo_full)} · Premium ${p(e.prazo_premium)}${e.prazo_simulacao != null ? ` · Simulação ${e.prazo_simulacao}` : ""} d.u.`;
  }
  if (e.prazo_dias_uteis === null) return "Sem prazo";
  const base = `${e.prazo_dias_uteis} d.u.`;
  return e.prazo_com_certificacao !== null ? `${base} (${e.prazo_com_certificacao} c/ certificação)` : base;
}

// Tipo de ordem — sem nome de empresa terceira (o parceiro pode mudar).
// "proprio": a ordem é gerenciada pela Jornada 4S; a NLG presta o serviço aos clientes da Jornada.
export const GERENCIAMENTO_LABEL: Record<string, string> = {
  proprio: "Gerenciamento próprio",
  ntl: "Gerenciamento terceirizado",
};
export const GERENCIAMENTO_CURTO: Record<string, string> = { proprio: "Próprio", ntl: "Terceirizado" };

// Encerrar sem ordem: resultado e motivos (para os filtros dos Concluídos)
export const RESULTADO_LABEL: Record<string, string> = {
  ordem: "Virou ordem",
  deu_preco: "Deu preço, não virou ordem",
  nao_deu_preco: "Não deu preço",
};
export const MOTIVOS_ENCERRAMENTO = [
  "Preço acima do esperado pelo cliente",
  "Cliente desistiu da importação",
  "Cliente parou de responder",
  "Sem fornecedor viável",
  "Prazo de produção ou entrega não atende",
  "Quantidade mínima (MOQ) não atende",
  "Outro",
];

// preenche as variáveis dos modelos de e-mail
export function preencherModelo(
  texto: string,
  v: { empresa?: string | null; contato?: string | null; plano?: string | null; meu_nome?: string | null; codigo?: string | null; gerenciamento?: string | null }
) {
  return texto
    .replaceAll("{empresa}", v.empresa || "XXX")
    .replaceAll("{contato}", v.contato || "XXX")
    .replaceAll("{plano}", v.plano || "XXX")
    .replaceAll("{meu_nome}", v.meu_nome || "XXX")
    .replaceAll("{codigo}", v.codigo || "")
    .replaceAll("{x_ntl}", v.gerenciamento === "ntl" ? "X" : " ")
    .replaceAll("{x_proprio}", v.gerenciamento === "proprio" ? "X" : " ");
}

/** meta compacta: "10/15/25" por plano, "1 d.u." ou "1–2 d.u." com certificação */
export function metaCurta(e: { tipo: string; prazo_dias_uteis: number | null; prazo_flex?: number | null; prazo_full?: number | null; prazo_premium?: number | null; prazo_com_certificacao?: number | null }) {
  if (e.tipo !== "tarefa") return "—";
  if (e.prazo_flex != null || e.prazo_full != null || e.prazo_premium != null) {
    const p = (v: number | null | undefined) => v ?? e.prazo_dias_uteis ?? "—";
    return `${p(e.prazo_flex)}/${p(e.prazo_full)}/${p(e.prazo_premium)} d.u.`;
  }
  if (e.prazo_dias_uteis == null) return "sem prazo";
  if (e.prazo_com_certificacao != null) return `${e.prazo_dias_uteis}–${e.prazo_com_certificacao} d.u.`;
  return `${e.prazo_dias_uteis} d.u.`;
}
