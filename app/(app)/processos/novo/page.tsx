import Link from "next/link";
import { ChevronRight } from "lucide-react";
import { base } from "@/lib/dados";
import NovoProcessoWizard from "@/components/processos/NovoProcessoWizard";

export const dynamic = "force-dynamic";

export default async function NovoProcesso({ searchParams }: { searchParams: Promise<{ cliente?: string }> }) {
  const { cliente } = await searchParams;
  const { supabase, etapas, mapaPerfis, feriados, hoje } = await base();
  const [{ data: itens }, { data: clientes }] = await Promise.all([
    supabase.from("checklist_modelo").select("etapa_id,condicao").eq("ativo", true),
    supabase.from("clientes").select("id,nome,contato").order("nome"),
  ]);
  const ativas = etapas.filter((e) => e.ativo);
  return (
    <div>
      <nav className="mb-2 flex items-center gap-1 text-xs text-muted" aria-label="Trilha">
        <Link href="/processos" className="hover:text-ink">Processos</Link><ChevronRight size={12} /><span className="text-ink">Novo processo</span>
      </nav>
      <h1 className="mb-5 text-xl font-semibold tracking-tight">Novo processo</h1>
      <NovoProcessoWizard
        hoje={hoje}
        clientes={clientes ?? []}
        clienteInicial={cliente}
        feriados={[...feriados]}
        itens={(itens ?? []) as { etapa_id: number; condicao: string | null }[]}
        etapas={ativas.map((e) => ({
          id: e.id, ordem: e.ordem, nome: e.nome, area: e.area, tipo: e.tipo,
          prazo: e.prazo_dias_uteis, flex: e.prazo_flex, full: e.prazo_full, premium: e.prazo_premium, cert: e.prazo_com_certificacao,
          responsaveis: e.responsaveis_padrao.map((id) => mapaPerfis.get(id)?.nome).filter(Boolean) as string[],
          label: e.responsaveis_label,
        }))}
      />
    </div>
  );
}
