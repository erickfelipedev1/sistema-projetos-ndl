import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { base, previsaoChegada, media, duracaoUteis, agruparPor, fmt1, type EtapaMin } from "@/lib/dados";
import type { EtapaAtual } from "@/lib/types";
import { dataBR, metaCurta } from "@/lib/format";
import { diasUteisEntre } from "@/lib/diasUteis";
import { motivo, nomeCurto, relativo, statusPrazo, du } from "@/lib/status";
import PageHeader from "@/components/ui/PageHeader";
import KpiCard from "@/components/ui/KpiCard";
import StatusBadge from "@/components/ui/StatusBadge";
import { Responsavel } from "@/components/ui/Avatar";
import EmptyState from "@/components/ui/EmptyState";
import ActivityTimeline from "@/components/ui/ActivityTimeline";
import FluxoProcessos, { type EtapaFluxo, type ResumoFluxo } from "@/components/painel/FluxoProcessos";
import BottleneckChart, { type LinhaGargalo } from "@/components/painel/BottleneckChart";

export const dynamic = "force-dynamic";

export default async function Painel({ searchParams }: { searchParams: Promise<{ periodo?: string }> }) {
  const sp = await searchParams;
  const periodo = ["30", "90", "180"].includes(sp.periodo ?? "") ? sp.periodo! : "30";
  const inicioPeriodo = Date.now() - Number(periodo) * 86400000;
  const { supabase, etapas, mapaPerfis, feriados, hoje } = await base();
  const desde = new Date(Date.now() - 180 * 86400000).toISOString();

  const [{ data: atuaisData }, { data: pendData }, { data: procData }, { data: histData }, { data: evData }] = await Promise.all([
    supabase.from("v_etapas_atuais").select("*"),
    supabase.from("processo_etapas").select("processo_id,ordem,status,tipo,prazo_dias_uteis,prazo_em,processos!inner(status)").eq("processos.status", "ativo"),
    supabase.from("processos").select("id,status,created_at,concluido_em"),
    supabase.from("processo_etapas").select("etapa_id,iniciado_em,concluido_em,prazo_dias_uteis,prazo_em,tipo").eq("status", "concluida").gte("concluido_em", desde),
    supabase.from("processo_eventos").select("id,tipo,texto,created_at,autor,processo_id,processos(cliente)").order("created_at", { ascending: false }).limit(9),
  ]);

  const atuais = (atuaisData ?? []) as EtapaAtual[];
  const processos = (procData ?? []) as { id: string; status: string; created_at: string; concluido_em: string | null }[];

  // ---------- previsões ----------
  const porProcesso = agruparPor((pendData ?? []) as unknown as EtapaMin[], (e) => e.processo_id);
  const previsao = new Map<string, string | null>();
  for (const [pid, lista] of porProcesso) previsao.set(pid, previsaoChegada(lista, feriados, hoje));

  // ---------- KPIs ----------
  const atrasados = atuais.filter((e) => e.atrasada);
  const venceHoje = atuais.filter((e) => !e.atrasada && e.dias_restantes === 0);
  const venceAmanha = atuais.filter((e) => !e.atrasada && e.dias_restantes === 1);

  const t30 = Date.now() - 30 * 86400000;
  const ativos30 = processos.filter((p) => p.status !== "cancelado" && new Date(p.created_at).getTime() <= t30 &&
    (!p.concluido_em || new Date(p.concluido_em).getTime() > t30)).length;
  const variacaoAtivos = ativos30 > 0 ? Math.round(((atuais.length - ativos30) / ativos30) * 100) : null;

  const concluidos = processos.filter((p) => p.status === "concluido" && p.concluido_em);
  const dur = (p: (typeof concluidos)[number]) => duracaoUteis(p.created_at, p.concluido_em, feriados) ?? 0;
  const t45 = Date.now() - 45 * 86400000, t90 = Date.now() - 90 * 86400000;
  const recentes = concluidos.filter((p) => new Date(p.concluido_em!).getTime() > t45).map(dur);
  const anteriores = concluidos.filter((p) => { const t = new Date(p.concluido_em!).getTime(); return t <= t45 && t > t90; }).map(dur);
  const tempoMedio = media(concluidos.map(dur));
  const tmRec = media(recentes), tmAnt = media(anteriores);

  const prevs = atuais.map((e) => previsao.get(e.processo_id)).filter(Boolean) as string[];
  const prevMediaMs = prevs.length ? prevs.reduce((s, d) => s + new Date(d + "T12:00:00").getTime(), 0) / prevs.length : null;
  const prevMedia = prevMediaMs ? new Date(prevMediaMs).toISOString().slice(0, 10) : null;

  // ---------- fluxo + gargalos ----------
  const hist = (histData ?? []) as { etapa_id: number | null; iniciado_em: string | null; concluido_em: string | null; prazo_dias_uteis: number | null; tipo: string }[];
  const histPorEtapa = agruparPor(hist.filter((h) => h.etapa_id && h.concluido_em && new Date(h.concluido_em).getTime() >= inicioPeriodo), (h) => h.etapa_id as number);
  const ativas = etapas.filter((e) => e.ativo);
  const fluxo: EtapaFluxo[] = ativas.map((e) => {
    const h = histPorEtapa.get(e.id) ?? [];
    const reais = h.map((x) => duracaoUteis(x.iniciado_em, x.concluido_em, feriados)).filter((n): n is number => n !== null);
    const metas = h.map((x) => x.prazo_dias_uteis).filter((n): n is number => n !== null);
    const aqui = atuais.filter((a) => a.etapa_id === e.id);
    return {
      id: e.id, ordem: e.ordem, nome: e.nome, area: e.area, tipo: e.tipo,
      emAndamento: aqui.length, atrasadas: aqui.filter((a) => a.atrasada).length,
      atencao: aqui.filter((a) => !a.atrasada && !a.aguardando_cliente && a.dias_restantes !== null && a.dias_restantes <= 1).length,
      mediaReal: e.tipo === "tarefa" ? media(reais) : null,
      meta: media(metas) ?? e.prazo_full ?? e.prazo_dias_uteis,
      passagens: h.length,
    };
  });
  const concluidosPeriodo = concluidos.filter((p) => new Date(p.concluido_em!).getTime() >= inicioPeriodo);
  const resumo: ResumoFluxo = {
    atrasado: atrasados.length,
    aguardando: atuais.filter((a) => !a.atrasada && a.aguardando_cliente).length,
    atencao: atuais.filter((a) => !a.atrasada && !a.aguardando_cliente && a.dias_restantes !== null && a.dias_restantes <= 1).length,
    noPrazo: atuais.filter((a) => !a.atrasada && !a.aguardando_cliente && (a.dias_restantes === null || a.dias_restantes > 1)).length,
    total: atuais.length,
    tempoMedio: media(concluidosPeriodo.map(dur)),
    concluidos: concluidosPeriodo.length,
    metaFluxo: ativas.filter((e) => e.tipo === "tarefa").reduce((s, e) => s + (e.prazo_full ?? e.prazo_dias_uteis ?? 0), 0),
  };
  const gargalos: LinhaGargalo[] = fluxo
    .filter((f) => f.tipo === "tarefa" && f.mediaReal !== null && f.meta)
    .map((f) => ({ id: f.id, nome: f.nome, realizado: f.mediaReal!, planejado: f.meta!, amostra: (histPorEtapa.get(f.id) ?? []).length }));
  const acima = gargalos.filter((g) => g.realizado - g.planejado >= 0.3).sort((a, b) => b.realizado / b.planejado - a.realizado / a.planejado);

  // ---------- tabelas ----------
  const maiorAtraso = [...atrasados].sort((a, b) => (a.dias_restantes ?? 0) - (b.dias_restantes ?? 0)).slice(0, 6);
  const proximas = [...atuais]
    .map((e) => ({ e, prev: previsao.get(e.processo_id) ?? null }))
    .filter((x) => x.prev)
    .sort((a, b) => (a.prev! < b.prev! ? -1 : 1))
    .slice(0, 6);

  const atividades = (evData ?? []).map((a: any) => ({
    id: a.id, tipo: a.tipo, texto: a.texto, created_at: a.created_at,
    autor: a.autor ? mapaPerfis.get(a.autor)?.nome ?? null : null,
    processo_id: a.processo_id, processo: a.processos?.cliente ?? null,
  }));


  return (
    <div className="space-y-5">
      <PageHeader titulo="Visão geral" subtitulo="Acompanhe o andamento dos processos e identifique gargalos." />

      {/* KPIs */}
      <section className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6" aria-label="Indicadores">
        <KpiCard rotulo="Processos ativos" valor={atuais.length} href="/processos"
          tendencia={variacaoAtivos !== null ? { texto: `${variacaoAtivos > 0 ? "+" : ""}${variacaoAtivos}%`, direcao: variacaoAtivos > 0 ? "sobe" : variacaoAtivos < 0 ? "desce" : "igual", bom: true } : null}
          contexto={variacaoAtivos !== null ? "vs. 30 dias atrás" : "sem histórico para comparar"} />
        <KpiCard rotulo="Em atraso" valor={atrasados.length} tom={atrasados.length ? "bad" : "neutro"} href="/processos?status=atrasado"
          contexto={atuais.length ? `${Math.round((atrasados.length / atuais.length) * 100)}% dos ativos` : undefined} />
        <KpiCard rotulo="Vencem hoje" valor={venceHoje.length} tom={venceHoje.length ? "warn" : "neutro"} href="/processos?status=hoje"
          contexto="etapas com prazo hoje" />
        <KpiCard rotulo="Vencem amanhã" valor={venceAmanha.length} href="/processos?status=amanha" contexto="próximo dia útil" />
        <KpiCard rotulo="Tempo médio" valor={fmt1(tempoMedio)} unidade={tempoMedio !== null ? "d.u." : undefined}
          tendencia={tmRec !== null && tmAnt !== null ? { texto: `${tmRec <= tmAnt ? "" : "+"}${fmt1(tmRec - tmAnt)} d.u.`, direcao: tmRec > tmAnt ? "sobe" : tmRec < tmAnt ? "desce" : "igual", bom: tmRec <= tmAnt } : null}
          contexto={concluidos.length ? `por processo · ${concluidos.length} concluído${concluidos.length > 1 ? "s" : ""}${tmRec !== null && tmAnt !== null ? " · últimos 45 dias" : ""}` : "nenhum processo concluído ainda"} />
        <KpiCard rotulo="Previsão média" valor={prevMedia ? dataBR(prevMedia) : "—"}
          contexto={prevMedia ? `de chegada · em ${du(diasUteisEntre(hoje, prevMedia, feriados))}` : undefined} />
      </section>

      {/* Fluxo */}
      <FluxoProcessos etapas={fluxo} resumo={resumo} periodo={periodo} />

      <div className="grid gap-5 xl:grid-cols-[1.35fr_1fr]">
        {/* Gargalos */}
        <section className="card">
          <div className="card-header">
            <div>
              <h2 className="card-title">Análise de gargalos</h2>
              <p className="card-sub">Tempo médio realizado × prazo, por etapa ({periodo === "180" ? "últimos 6 meses" : `últimos ${periodo} dias`})</p>
            </div>
          </div>
          <div className="px-4 pt-4 pb-3">
            {acima.length > 0 && (
              <p className="mb-3 rounded-md bg-sunken px-3 py-2 text-xs text-muted">
                <strong className="font-semibold text-ink">{nomeCurto(acima[0].nome)}</strong> é o maior gargalo:
                leva em média <strong className="num text-bad-ink">{fmt1(acima[0].realizado)} d.u.</strong> para um prazo de {fmt1(acima[0].planejado)}.
                {acima.length > 1 && <> Também acima do prazo: {acima.slice(1, 4).map((a) => nomeCurto(a.nome)).join(", ")}.</>}
              </p>
            )}
            <BottleneckChart linhas={gargalos} />
          </div>
        </section>

        {/* Atividades */}
        <section className="card">
          <div className="card-header">
            <h2 className="card-title">Atividades recentes</h2>
          </div>
          <div className="px-4 py-4">
            {atividades.length ? <ActivityTimeline itens={atividades} /> : <EmptyState compacto titulo="Nenhuma atividade ainda" />}
          </div>
        </section>
      </div>

      <div className="grid gap-5 2xl:grid-cols-2">
        {/* Maior atraso */}
        <section className="card overflow-hidden">
          <div className="card-header">
            <div>
              <h2 className="card-title">Processos com maior atraso</h2>
              <p className="card-sub">{atrasados.length} etapa{atrasados.length === 1 ? "" : "s"} fora do prazo</p>
            </div>
            <Link href="/processos?status=atrasado" className="btn-quiet h-7 text-xs">Ver todos <ArrowRight size={13} /></Link>
          </div>
          {maiorAtraso.length ? (
            <div className="scroll-x">
              <table className="table-base min-w-[560px]">
                <thead><tr><th>Empresa</th><th>Etapa</th><th>Responsável</th><th className="text-right">Atraso</th><th>Atualização</th></tr></thead>
                <tbody>
                  {maiorAtraso.map((e) => (
                    <tr key={e.id}>
                      <td>
                        <Link href={`/processos/${e.processo_id}`} className="font-medium whitespace-nowrap text-ink hover:text-primary-2">{e.cliente}</Link>
                        <div className="text-[11px] text-subtle">{e.codigo}</div>
                      </td>
                      <td className="max-w-[240px]">
                        <div className="text-ink">{nomeCurto(e.nome)}</div>
                        <div className="truncate text-[11px] text-muted" title={motivo(e)}>{motivo(e)}</div>
                      </td>
                      <td><Responsavel ids={e.responsaveis} label={e.responsaveis_label} mapa={mapaPerfis} /></td>
                      <td className="text-right"><StatusBadge tipo="atrasado" texto={du(Math.abs(e.dias_restantes ?? 0))} /></td>
                      <td className="text-xs whitespace-nowrap text-muted">{relativo(e.ultima_atualizacao)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <EmptyState compacto titulo="Nenhum processo atrasado" texto="Todas as etapas estão dentro do prazo." />}
        </section>

        {/* Próximas entregas */}
        <section className="card overflow-hidden">
          <div className="card-header">
            <div>
              <h2 className="card-title">Próximas entregas</h2>
              <p className="card-sub">Previsão de chegada dos processos ativos</p>
            </div>
          </div>
          {proximas.length ? (
            <div className="scroll-x">
              <table className="table-base min-w-[520px]">
                <thead><tr><th>Empresa</th><th>Etapa atual</th><th>Previsão</th><th>Responsável</th><th>Status</th></tr></thead>
                <tbody>
                  {proximas.map(({ e, prev }) => (
                    <tr key={e.id}>
                      <td className="whitespace-nowrap"><Link href={`/processos/${e.processo_id}`} className="font-medium text-ink hover:text-primary-2">{e.cliente}</Link></td>
                      <td className="whitespace-nowrap text-ink">{nomeCurto(e.nome)}</td>
                      <td className="num whitespace-nowrap">{dataBR(prev)}</td>
                      <td><Responsavel ids={e.responsaveis} label={e.responsaveis_label} mapa={mapaPerfis} /></td>
                      <td><StatusBadge tipo={statusPrazo(e.dias_restantes, e.atrasada, e)} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <EmptyState compacto titulo="Sem previsões" />}
        </section>
      </div>
    </div>
  );
}
