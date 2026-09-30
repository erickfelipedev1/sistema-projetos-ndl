// Regras de apresentação de status — um só lugar para todas as telas
import type { EtapaAtual } from "./types";

export type StatusTipo = "atrasado" | "atencao" | "em_dia" | "sem_prazo" | "concluido" | "cancelado" | "pendente" | "aguardando" | "cobrar";

export const STATUS_LABEL: Record<StatusTipo, string> = {
  atrasado: "Atrasado",
  atencao: "Atenção",
  em_dia: "Em dia",
  sem_prazo: "Sem prazo",
  concluido: "Concluído",
  cancelado: "Cancelado",
  pendente: "Próximo",
  aguardando: "Aguardando cliente",
  cobrar: "Cobrar cliente",
};

/** etapa parada esperando o cliente (prazo pausado) */
export type Espera = { aguardando_cliente?: boolean | null; cobrar_hoje?: boolean | null };

export function statusPrazo(dias: number | null, atrasada: boolean, espera?: Espera): StatusTipo {
  if (espera?.aguardando_cliente) return espera.cobrar_hoje ? "cobrar" : "aguardando";
  if (atrasada) return "atrasado";
  if (dias === null) return "sem_prazo";
  if (dias <= 1) return "atencao";
  return "em_dia";
}

export function du(n: number) {
  return `${n} ${n === 1 ? "dia útil" : "dias úteis"}`;
}

/** "Vence hoje", "Em 6 dias úteis", "3 dias úteis em atraso" */
export function prazoTexto(dias: number | null, atrasada: boolean, espera?: Espera) {
  if (espera?.aguardando_cliente) return espera.cobrar_hoje ? "Cobrar cliente" : "Aguardando cliente";
  if (dias === null) return "Sem prazo";
  if (atrasada) return `${du(Math.abs(dias))} em atraso`;
  if (dias === 0) return "Vence hoje";
  if (dias === 1) return "Vence amanhã";
  return `Em ${du(dias)}`;
}

/** Explica POR QUE o processo está onde está. */
export function motivo(e: Pick<EtapaAtual, "situacao" | "atrasada" | "dias_restantes" | "proxima_acao"> & Partial<Pick<EtapaAtual, "aguardando_cliente" | "aguardando_desde" | "cobrar_hoje">>) {
  if (e.situacao) return e.situacao;
  if (e.aguardando_cliente) {
    const dias = e.aguardando_desde ? Math.floor((Date.now() - new Date(e.aguardando_desde).getTime()) / 86400000) : 0;
    const base = e.proxima_acao ? limparPasso(e.proxima_acao).split(" — ")[0] : "Aguardando cliente";
    return `${base} · ${dias === 0 ? "desde hoje" : dias === 1 ? "há 1 dia" : `há ${dias} dias`}${e.cobrar_hoje ? " · cobrar esta semana" : ""}`;
  }
  if (e.atrasada && e.dias_restantes !== null) return `${du(Math.abs(e.dias_restantes))} acima do prazo`;
  if (e.proxima_acao) return `próximo: ${limparPasso(e.proxima_acao)}`;
  if (e.dias_restantes === 0) return "vence hoje";
  return "em andamento";
}

/** remove o prefixo "3º " dos passos do manual */
export function limparPasso(t: string) {
  return t.replace(/^\d+º\s*/, "");
}

const CURTOS: Record<string, string> = {
  "Apresentação / Montagem do projeto (planilha)": "Apresentação",
  "Onboarding": "Onboarding",
  "Projeto (Flex / Premium / Full)": "Projeto",
  "Estimativa de custo": "Estimativa",
  "Apresentação da estimativa": "Apres. estimativa",
  "Processo / Ordem / Pagamento": "CX · Ordem",
  "Booking + Coleta + Estufagem": "Booking",
};
export function nomeCurto(nome: string) {
  return CURTOS[nome] ?? nome;
}

export function iniciais(nome: string | null | undefined) {
  if (!nome) return "?";
  const p = nome.trim().split(/\s+/);
  return ((p[0]?.[0] ?? "") + (p.length > 1 ? p[p.length - 1][0] : "")).toUpperCase();
}

export function saudacao(d = new Date()) {
  const h = Number(d.toLocaleString("en-US", { hour: "numeric", hour12: false, timeZone: "America/Sao_Paulo" }));
  return h < 12 ? "Bom dia" : h < 18 ? "Boa tarde" : "Boa noite";
}

export function relativo(ts: string | null | undefined) {
  if (!ts) return "—";
  const diff = (Date.now() - new Date(ts).getTime()) / 60000;
  if (diff < 1) return "agora";
  if (diff < 60) return `há ${Math.round(diff)} min`;
  const d = new Date(ts);
  const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  const dia = d.toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  const hora = d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit", timeZone: "America/Sao_Paulo" });
  if (dia === hoje) return `Hoje ${hora}`;
  const ontem = new Date(Date.now() - 86400000).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  if (dia === ontem) return `Ontem ${hora}`;
  return d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit", timeZone: "America/Sao_Paulo" }) + ` ${hora}`;
}
