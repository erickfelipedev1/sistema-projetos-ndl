import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { Etapa, Profile } from "./types";
import { addDiasUteis, diasUteisEntre, hojeBR, paraDataBR } from "./diasUteis";
import { nomesResponsaveis } from "./format";

export async function base() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const [{ data: etapas }, { data: perfis }, { data: feriados }] = await Promise.all([
    supabase.from("etapas").select("*").order("ordem"),
    supabase.from("profiles").select("id,nome,email,cargo,usuario").eq("tipo", "equipe").order("nome"),
    supabase.from("feriados").select("data"),
  ]);
  const listaPerfis = (perfis ?? []) as Profile[];
  return {
    supabase,
    user: user!,
    etapas: (etapas ?? []) as Etapa[],
    perfis: listaPerfis,
    mapaPerfis: new Map(listaPerfis.map((p) => [p.id, p])),
    feriados: new Set((feriados ?? []).map((f: { data: string }) => f.data)),
    hoje: hojeBR(),
  };
}

export type EtapaMin = {
  processo_id: string; ordem: number; status: string; tipo: string;
  prazo_dias_uteis: number | null; prazo_em: string | null;
};

/** previsão de chegada = prazo da etapa atual (ou hoje) + prazos padrão das etapas seguintes */
export function previsaoChegada(etapas: EtapaMin[], feriados: Set<string>, hoje: string) {
  const ord = [...etapas].sort((a, b) => a.ordem - b.ordem);
  const idx = ord.findIndex((e) => e.status === "em_andamento");
  if (idx < 0) return null;
  const atual = ord[idx];
  const baseData = atual.prazo_em && atual.prazo_em > hoje ? atual.prazo_em : hoje;
  const resto = ord.slice(idx + 1).reduce((s, e) => s + (e.prazo_dias_uteis ?? 0), 0);
  return addDiasUteis(baseData, resto, feriados);
}

export function agruparPor<T, K>(lista: T[], chave: (t: T) => K) {
  const m = new Map<K, T[]>();
  for (const i of lista) {
    const k = chave(i);
    m.set(k, [...(m.get(k) ?? []), i]);
  }
  return m;
}

export function duracaoUteis(ini: string | null, fim: string | null, feriados: Set<string>) {
  if (!ini || !fim) return null;
  return diasUteisEntre(paraDataBR(ini), paraDataBR(fim), feriados);
}

export function responsavelTexto(ids: string[], label: string | null, mapa: Map<string, Profile>) {
  return nomesResponsaveis(ids, label, mapa);
}

export function media(nums: number[]) {
  return nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : null;
}

export function fmt1(n: number | null | undefined) {
  if (n === null || n === undefined) return "—";
  return n.toLocaleString("pt-BR", { maximumFractionDigits: 1, minimumFractionDigits: n % 1 === 0 ? 0 : 1 });
}
