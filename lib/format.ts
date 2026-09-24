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

export function nomesResponsaveis(ids: string[], label: string | null, perfis: Map<string, Profile>) {
  const nomes = ids.map((id) => perfis.get(id)?.nome).filter(Boolean) as string[];
  if (nomes.length) return nomes.join(" / ");
  return label ?? "Sem responsável";
}

export function prazoTexto(dias: number | null, atrasada: boolean) {
  if (dias === null) return "Sem prazo";
  if (atrasada) return `${Math.abs(dias)} d.u. atrasado`;
  if (dias === 0) return "Vence hoje";
  if (dias === 1) return "Vence amanhã";
  return `${dias} d.u. restantes`;
}

export function prazoCor(dias: number | null, atrasada: boolean) {
  if (dias === null) return "bg-slate-100 text-slate-600";
  if (atrasada) return "bg-red-100 text-red-700";
  if (dias <= 1) return "bg-amber-100 text-amber-800";
  return "bg-emerald-100 text-emerald-700";
}

export const PLANO_COR: Record<string, string> = {
  Flex: "bg-sky-100 text-sky-800",
  Premium: "bg-violet-100 text-violet-800",
  Full: "bg-indigo-100 text-indigo-800",
};

export function mapaPerfis(perfis: Profile[] | null) {
  return new Map((perfis ?? []).map((p) => [p.id, p]));
}
