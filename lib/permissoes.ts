// Regras de permissão (espelham as travas do banco — SQL 011)
import { normaliza, primeiroNome } from "./login";
import type { Profile } from "./types";

export type Eu = { id: string; cargo?: string | null; admin?: boolean | null };

/** admin, responsável da etapa ou cargo = área da etapa */
export function podeEditarEtapa(eu: Eu | undefined, pe: { responsaveis: string[]; area: string } | undefined | null) {
  if (!eu || !pe) return false;
  if (eu.admin) return true;
  if (pe.responsaveis.includes(eu.id)) return true;
  return !!eu.cargo && normaliza(eu.cargo) === normaliza(pe.area);
}

/** quem recebe/pode marcar um item com responsável próprio (ids do modelo; senão, pelos nomes do rótulo) */
export function responsaveisDoItem(m: { responsaveis?: string[] | null; responsaveis_label?: string | null } | undefined, perfis: Profile[]) {
  if (!m) return [];
  if (m.responsaveis?.length) return m.responsaveis;
  if (!m.responsaveis_label) return [];
  const nomes = m.responsaveis_label.split(/\s*[\/,;&]\s*|\s+e\s+/).map((n) => primeiroNome(n)).filter(Boolean);
  return perfis.filter((p) => nomes.includes(primeiroNome(p.nome ?? ""))).map((p) => p.id);
}

export function podeMarcarItem(eu: Eu | undefined, respItem: string[], pe: { responsaveis: string[]; area: string } | undefined) {
  if (!eu) return false;
  if (eu.admin) return true;
  if (respItem.length) return respItem.includes(eu.id);
  return podeEditarEtapa(eu, pe);
}
