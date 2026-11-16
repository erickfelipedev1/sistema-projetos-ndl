import Link from "next/link";
import { Route } from "lucide-react";
import { base } from "@/lib/dados";
import type { EtapaAtual } from "@/lib/types";
import { dataBR, nomeExibicao } from "@/lib/format";
import { normaliza } from "@/lib/login";
import { prazoTexto, statusPrazo } from "@/lib/status";
import PageHeader from "@/components/ui/PageHeader";
import EmptyState from "@/components/ui/EmptyState";
import StatusBadge from "@/components/ui/StatusBadge";
import SubmitButton from "@/components/ui/SubmitButton";
import { PlanoTag } from "@/components/processos/ProcessCard";
import { direcionarProjeto } from "@/app/actions";

export const dynamic = "force-dynamic";

const PROJETO = "Projeto (Flex / Premium / Full)";
const DISTRIBUICAO = "Distribuição";

export default async function Distribuicao({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const { erro } = await searchParams;
  const { supabase, etapas, perfis, mapaPerfis } = await base();
  const { data } = await supabase.from("v_etapas_atuais").select("*").in("nome", [DISTRIBUICAO, PROJETO])
    .order("prazo_em", { ascending: true, nullsFirst: false });
  const lista = (data ?? []) as EtapaAtual[];

  // quem pode conduzir: o time da área do Projeto (Projetos)
  const area = etapas.find((e) => e.nome === PROJETO)?.area ?? "Projetos";
  let analistas = perfis.filter((p) => p.cargo && normaliza(p.cargo) === normaliza(area));
  if (!analistas.length) analistas = perfis;

  // aguardando: tudo o que está na Distribuição + projetos antigos que ainda estão com mais de uma pessoa
  const aguardando = lista.filter((e) => e.nome === DISTRIBUICAO || e.responsaveis.length !== 1);
  const conduzindo = lista.filter((e) => e.nome === PROJETO && e.responsaveis.length === 1);

  const porAnalista = new Map<string, EtapaAtual[]>();
  for (const e of conduzindo) porAnalista.set(e.responsaveis[0], [...(porAnalista.get(e.responsaveis[0]) ?? []), e]);
  const resumo = [...porAnalista.entries()]
    .map(([id, itens]) => ({ id, nome: nomeExibicao(mapaPerfis.get(id)?.nome ?? mapaPerfis.get(id)?.email), itens, atrasados: itens.filter((i) => i.atrasada).length }))
    .sort((a, b) => b.itens.length - a.itens.length);

  const Linha = ({ e }: { e: EtapaAtual }) => {
    const naDistribuicao = e.nome === DISTRIBUICAO;
    const atual = !naDistribuicao && e.responsaveis.length === 1 ? e.responsaveis[0] : "";
    return (
      <tr>
        <td className="whitespace-nowrap">
          <Link prefetch={false} href={`/processos/${e.processo_id}`} className="font-medium text-ink hover:text-primary-2">{e.cliente}</Link>
          <div className="text-[11px] text-subtle">{e.codigo}{e.contato ? ` · ${e.contato}` : ""}</div>
        </td>
        <td><PlanoTag plano={e.plano} /></td>
        <td className="whitespace-nowrap">
          <StatusBadge tipo={statusPrazo(e.dias_restantes, e.atrasada, e)} texto={prazoTexto(e.dias_restantes, e.atrasada, e)} />
          <div className="num mt-0.5 text-[11px] text-subtle">{dataBR(e.prazo_em)}</div>
        </td>
        <td className="text-muted">{naDistribuicao ? "Distribuição" : `Projeto · ${e.checklist_total ? `${e.checklist_feitos}/${e.checklist_total}` : "—"}`}</td>
        <td>
          <form action={direcionarProjeto} className="flex items-center gap-2">
            <input type="hidden" name="processo_id" value={e.processo_id} />
            <input type="hidden" name="voltar" value="/distribuicao" />
            <select name="responsavel" required defaultValue={atual} className="input h-8 w-auto! min-w-[150px]" aria-label={`Quem conduz ${e.cliente}`}>
              <option value="" disabled>Escolher…</option>
              {analistas.map((p) => <option key={p.id} value={p.id}>{nomeExibicao(p.nome ?? p.email)}</option>)}
            </select>
            <SubmitButton className="btn-primary h-8 text-xs" pendente="Direcionando…">{atual ? "Trocar" : "Direcionar"}</SubmitButton>
          </form>
        </td>
      </tr>
    );
  };

  const Tabela = ({ itens }: { itens: EtapaAtual[] }) => (
    <div className="scroll-x">
      <table className="table-base min-w-[820px]">
        <thead><tr><th>Cliente</th><th>Plano</th><th>Prazo</th><th>Etapa</th><th>Quem conduz</th></tr></thead>
        <tbody>{itens.map((e) => <Linha key={e.id} e={e} />)}</tbody>
      </table>
    </div>
  );

  return (
    <div className="space-y-5">
      {erro && <p role="alert" className="rounded-md border border-bad/40 bg-bad-soft px-3 py-2 text-[13px] text-bad-ink"><strong className="font-semibold">Não foi possível direcionar:</strong> {erro}</p>}
      <PageHeader titulo="Distribuição" subtitulo="Depois do onboarding, escolha UMA pessoa para conduzir cada projeto: Gabriella ou Giovanna nos projetos de sourcing (Premium, Full ou Flex) e Alycia nos de estimativa de custos. A pessoa recebe uma demanda no chat e o projeto segue para ela." />

      <section className="grid grid-cols-2 gap-3 md:grid-cols-4" aria-label="Resumo">
        <div className="card px-4 py-3.5"><p className="text-[11px] font-medium text-muted">Aguardando distribuição</p><p className={`num mt-1 text-2xl font-semibold ${aguardando.length ? "text-warn-ink" : "text-ink"}`}>{aguardando.length}</p></div>
        <div className="card px-4 py-3.5"><p className="text-[11px] font-medium text-muted">Em condução</p><p className="num mt-1 text-2xl font-semibold text-ink">{conduzindo.length}</p></div>
        <div className="card px-4 py-3.5"><p className="text-[11px] font-medium text-muted">Atrasados</p><p className={`num mt-1 text-2xl font-semibold ${lista.some((e) => e.atrasada) ? "text-bad-ink" : "text-ink"}`}>{lista.filter((e) => e.atrasada).length}</p></div>
        <div className="card px-4 py-3.5"><p className="text-[11px] font-medium text-muted">Projetos no total</p><p className="num mt-1 text-2xl font-semibold text-ink">{lista.length}</p></div>
      </section>

      <section className="card overflow-hidden">
        <div className="card-header">
          <div>
            <h2 className="card-title">Aguardando distribuição</h2>
            <p className="card-sub">Ao direcionar, a etapa Distribuição é concluída e o Projeto começa com a pessoa escolhida</p>
          </div>
        </div>
        {aguardando.length ? <Tabela itens={aguardando} /> : <EmptyState compacto titulo="Nada para distribuir" texto="Todos os projetos já têm quem conduza." />}
      </section>

      <section className="card overflow-hidden">
        <div className="card-header">
          <div>
            <h2 className="card-title">Em condução</h2>
            <p className="card-sub">Projetos já distribuídos — dá para trocar a pessoa</p>
          </div>
          <Route size={15} className="text-subtle" />
        </div>
        {resumo.length > 0 && (
          <div className="flex flex-wrap gap-2 border-b border-line px-4 py-3">
            {resumo.map((r) => (
              <span key={r.id} className="chip border border-line bg-surface text-ink">
                {r.nome} · {r.itens.length}{r.atrasados ? <span className="text-bad-ink"> ({r.atrasados} atrasado{r.atrasados > 1 ? "s" : ""})</span> : null}
              </span>
            ))}
          </div>
        )}
        {conduzindo.length ? <Tabela itens={conduzindo} /> : <EmptyState compacto titulo="Nenhum projeto em condução" />}
      </section>

      <p className="text-[11px] text-muted">Quem pode distribuir: administradores e o time de {area}.</p>
    </div>
  );
}
