import Link from "next/link";
import { Columns3, List } from "lucide-react";
import { base, duracaoUteis } from "@/lib/dados";
import type { EtapaAtual, Processo } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { motivo, nomeCurto, prazoTexto, statusPrazo, relativo } from "@/lib/status";
import PageHeader from "@/components/ui/PageHeader";
import Tabs, { Segmented } from "@/components/ui/Tabs";
import FilterBar from "@/components/ui/FilterBar";
import StatusBadge from "@/components/ui/StatusBadge";
import ProgressBar from "@/components/ui/ProgressBar";
import EmptyState from "@/components/ui/EmptyState";
import { Responsavel } from "@/components/ui/Avatar";
import ProcessCard, { PlanoTag } from "@/components/processos/ProcessCard";
import StageColumn from "@/components/processos/StageColumn";

export const dynamic = "force-dynamic";

type SP = Promise<Record<string, string | undefined>>;

export default async function Processos({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const visao = sp.visao ?? "ativos";
  const view = sp.view ?? "kanban";
  const { supabase, user, etapas, perfis, mapaPerfis, feriados } = await base();

  const [{ data: atuaisData }, { count: nConc }, { count: nCanc }] = await Promise.all([
    supabase.from("v_etapas_atuais").select("*").order("prazo_em", { ascending: true, nullsFirst: false }),
    supabase.from("processos").select("id", { count: "exact", head: true }).eq("status", "concluido"),
    supabase.from("processos").select("id", { count: "exact", head: true }).eq("status", "cancelado"),
  ]);
  const todos = (atuaisData ?? []) as EtapaAtual[];

  const q = (sp.q ?? "").trim().toLowerCase();
  const filtrados = todos.filter((e) => {
    if (q && !`${e.cliente} ${e.contato ?? ""} ${e.codigo}`.toLowerCase().includes(q)) return false;
    if (sp.resp && !e.responsaveis.includes(sp.resp === "me" ? user.id : sp.resp)) return false;
    if (sp.plano && e.plano !== sp.plano) return false;
    if (sp.cert && (sp.cert === "sim") !== e.certificacao) return false;
    if (sp.etapa && String(e.etapa_id) !== sp.etapa) return false;
    if (sp.status) {
      const st = statusPrazo(e.dias_restantes, e.atrasada, e);
      if (sp.status === "hoje" && !(e.dias_restantes === 0 && !e.atrasada)) return false;
      if (sp.status === "amanha" && !(e.dias_restantes === 1 && !e.atrasada)) return false;
      if (["atrasado", "atencao", "em_dia"].includes(sp.status) && st !== sp.status) return false;
      if (sp.status === "aguardando" && !e.aguardando_cliente) return false;
      if (sp.status === "cobrar" && !e.cobrar_hoje) return false;
    }
    return true;
  });

  const qs = (extra: Record<string, string | undefined>) => {
    const u = new URLSearchParams();
    for (const [k, v] of Object.entries({ ...sp, ...extra })) if (v) u.set(k, v);
    return `/processos?${u.toString()}`;
  };

  const filtros = [
    { nome: "resp", rotulo: "Responsável", valor: sp.resp ?? "", opcoes: [{ valor: "me", rotulo: "Eu" }, ...perfis.map((p) => ({ valor: p.id, rotulo: p.nome ?? p.email ?? "" }))] },
    { nome: "plano", rotulo: "Plano", valor: sp.plano ?? "", opcoes: ["Flex", "Full", "Premium"].map((p) => ({ valor: p, rotulo: p })) },
    { nome: "cert", rotulo: "Certificação", valor: sp.cert ?? "", opcoes: [{ valor: "sim", rotulo: "Com certificação" }, { valor: "nao", rotulo: "Sem certificação" }] },
    { nome: "status", rotulo: "Status", valor: sp.status ?? "", opcoes: [
      { valor: "atrasado", rotulo: "Atrasado" }, { valor: "hoje", rotulo: "Vence hoje" }, { valor: "amanha", rotulo: "Vence amanhã" },
      { valor: "atencao", rotulo: "Atenção (≤ 1 dia)" }, { valor: "em_dia", rotulo: "Em dia" },
      { valor: "aguardando", rotulo: "Aguardando cliente" }, { valor: "cobrar", rotulo: "Cobrar cliente" }] },
    { nome: "etapa", rotulo: "Etapa", valor: sp.etapa ?? "", opcoes: etapas.filter((e) => e.ativo && e.tipo !== "final").map((e) => ({ valor: String(e.id), rotulo: `${e.ordem}. ${nomeCurto(e.nome)}` })) },
  ];

  const abas = (
    <Tabs ativo={visao} itens={[
      { chave: "ativos", rotulo: "Ativos", href: "/processos?visao=ativos", contagem: todos.length },
      { chave: "concluido", rotulo: "Concluídos", href: "/processos?visao=concluido", contagem: nConc ?? 0 },
      { chave: "cancelado", rotulo: "Cancelados", href: "/processos?visao=cancelado", contagem: nCanc ?? 0 },
    ]} />
  );

  const header = (
    <PageHeader titulo="Processos" subtitulo="Todos os processos por etapa, com prazo, responsável e próxima ação." />
  );

  // ---------------- concluídos / cancelados ----------------
  if (visao !== "ativos") {
    let query = supabase.from("processos").select("*").eq("status", visao).order(visao === "concluido" ? "concluido_em" : "created_at", { ascending: false }).limit(300);
    if (sp.plano) query = query.eq("plano", sp.plano);
    const { data } = await query;
    const lista = ((data ?? []) as Processo[]).filter((p) => !q || `${p.cliente} ${p.contato ?? ""} ${p.codigo}`.toLowerCase().includes(q));
    return (
      <div>
        {header}
        {abas}
        <div className="mt-4 mb-3">
          <FilterBar busca={sp.q} ocultos={{ visao }} limparHref={`/processos?visao=${visao}`} filtros={[filtros[1]]} />
        </div>
        <div className="card overflow-hidden">
          {lista.length ? (
            <div className="scroll-x">
              <table className="table-base min-w-[860px]">
                <thead><tr><th>Código</th><th>Empresa</th><th>Contato</th><th>Plano</th><th>Tipo de ordem</th><th>Aberto em</th>
                  {visao === "concluido" && <><th>Chegou em</th><th className="text-right">Duração</th></>}</tr></thead>
                <tbody>
                  {lista.map((p) => (
                    <tr key={p.id}>
                      <td className="text-xs text-muted">{p.codigo}</td>
                      <td><Link href={`/processos/${p.id}`} className="font-medium text-ink hover:text-primary-2">{p.cliente}</Link></td>
                      <td className="text-muted">{p.contato ?? "—"}</td>
                      <td><PlanoTag plano={p.plano} /></td>
                      <td className="text-muted">{p.gerenciamento === "ntl" ? "Gerenciamento NTL" : p.gerenciamento === "proprio" ? "Próprio NLG" : "—"}</td>
                      <td className="num">{dataBR(p.created_at)}</td>
                      {visao === "concluido" && <>
                        <td className="num">{dataBR(p.concluido_em)}</td>
                        <td className="num text-right">{duracaoUteis(p.created_at, p.concluido_em, feriados) ?? "—"} d.u.</td>
                      </>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <EmptyState titulo={visao === "concluido" ? "Nenhum processo concluído" : "Nenhum processo cancelado"} />}
        </div>
      </div>
    );
  }

  // ---------------- ativos ----------------
  const colunas = etapas.filter((e) => e.ativo);
  const idsColunas = new Set(colunas.map((c) => c.id));
  const orfaos = filtrados.filter((e) => !e.etapa_id || !idsColunas.has(e.etapa_id));
  const { data: chegaram } = await supabase.from("processos").select("id,codigo,cliente,plano,concluido_em").eq("status", "concluido")
    .gte("concluido_em", new Date(Date.now() - 30 * 86400000).toISOString()).order("concluido_em", { ascending: false });

  return (
    <div>
      {header}
      {abas}
      <div className="mt-4 mb-4 flex flex-wrap items-center justify-between gap-3">
        <FilterBar busca={sp.q} ocultos={{ visao, view }} limparHref={`/processos?view=${view}`} filtros={filtros} />
        <div className="flex items-center gap-3">
          <span className="text-xs text-muted"><strong className="num text-ink">{filtrados.length}</strong> de {todos.length}</span>
          <Segmented ativo={view} itens={[
            { chave: "kanban", rotulo: <><Columns3 size={13} /> Kanban</>, href: qs({ view: "kanban" }) },
            { chave: "lista", rotulo: <><List size={13} /> Lista</>, href: qs({ view: "lista" }) },
          ]} />
        </div>
      </div>

      {view === "lista" ? (
        <div className="card overflow-hidden">
          {filtrados.length ? (
            <div className="scroll-x">
              <table className="table-base min-w-[1100px]">
                <thead><tr><th>Empresa</th><th>Plano</th><th>Etapa · situação</th><th>Responsável</th><th>Prazo</th><th>Checklist</th><th>Atualização</th></tr></thead>
                <tbody>
                  {filtrados.map((e) => (
                    <tr key={e.id}>
                      <td className="whitespace-nowrap">
                        <Link href={`/processos/${e.processo_id}`} className="font-medium text-ink hover:text-primary-2">{e.cliente}</Link>
                        <div className="text-[11px] text-subtle">{e.codigo}{e.contato ? ` · ${e.contato}` : ""}</div>
                      </td>
                      <td><PlanoTag plano={e.plano} /></td>
                      <td className="max-w-[320px]">
                        <div className="text-ink"><span className="num text-subtle">{e.ordem}.</span> {nomeCurto(e.nome)}</div>
                        <div className="truncate text-[11px] text-muted">{motivo(e)}</div>
                      </td>
                      <td><Responsavel ids={e.responsaveis} label={e.responsaveis_label} mapa={mapaPerfis} /></td>
                      <td className="whitespace-nowrap">
                        <StatusBadge tipo={statusPrazo(e.dias_restantes, e.atrasada, e)} texto={prazoTexto(e.dias_restantes, e.atrasada, e)} />
                        <div className="num mt-0.5 text-[11px] text-subtle">{dataBR(e.prazo_em)}</div>
                      </td>
                      <td className="w-36">{e.checklist_total ? <ProgressBar valor={e.checklist_feitos} total={e.checklist_total} /> : <span className="text-xs text-subtle">—</span>}</td>
                      <td className="text-xs whitespace-nowrap text-muted">{relativo(e.ultima_atualizacao)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <EmptyState titulo="Nenhum processo encontrado" texto="Ajuste os filtros para ver mais processos." />}
        </div>
      ) : (
        <div className="scroll-x -mx-5 px-5 pb-3 xl:-mx-7 xl:px-7">
          <div className="flex items-start gap-3">
            {colunas.map((c) => {
              const cards = filtrados.filter((e) => e.etapa_id === c.id);
              if (c.tipo === "final") {
                const lista = (chegaram ?? []) as { id: string; codigo: string; cliente: string; plano: string | null; concluido_em: string }[];
                return (
                  <StageColumn key={c.id} etapa={c} total={lista.length} atrasados={0}>
                    <p className="px-1 text-[11px] text-muted">Chegaram nos últimos 30 dias</p>
                    {lista.map((p) => (
                      <Link key={p.id} href={`/processos/${p.id}`} className="flex items-center justify-between rounded-md border border-line bg-surface px-2.5 py-2 hover:border-primary-2/50">
                        <span className="truncate text-[12.5px] font-medium text-ink">{p.cliente}</span>
                        <span className="num shrink-0 text-[11px] text-ok-ink">{dataBR(p.concluido_em).slice(0, 5)}</span>
                      </Link>
                    ))}
                    {!lista.length && <p className="px-1 py-4 text-center text-[11px] text-subtle">Nenhuma chegada recente</p>}
                  </StageColumn>
                );
              }
              return (
                <StageColumn key={c.id} etapa={c} total={cards.length} atrasados={cards.filter((e) => e.atrasada).length}>
                  {cards.map((e) => <ProcessCard key={e.id} e={e} mapa={mapaPerfis} />)}
                  {!cards.length && <p className="py-6 text-center text-[11px] text-subtle">Nenhum processo</p>}
                </StageColumn>
              );
            })}
            {orfaos.length > 0 && (
              <StageColumn etapa={{ ordem: 0, nome: "Etapas removidas", area: "Configuração", tipo: "tarefa", prazo_dias_uteis: null, prazo_flex: null, prazo_full: null, prazo_premium: null, prazo_com_certificacao: null, responsaveis_label: null }} total={orfaos.length} atrasados={0}>
                {orfaos.map((e) => <ProcessCard key={e.id} e={e} mapa={mapaPerfis} />)}
              </StageColumn>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
