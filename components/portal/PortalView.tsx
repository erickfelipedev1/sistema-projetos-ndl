"use client";

import { useEffect, useMemo, useState } from "react";
import { Check, PackageCheck, Search, Ship, X } from "lucide-react";
import type { PortalDados, PortalProcesso } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { paraDataBR } from "@/lib/diasUteis";
import { nomeCurto } from "@/lib/status";
import EmptyState from "@/components/ui/EmptyState";

/* Visão do cliente no estilo "follow-up": indicadores, tabela resumo e painel lateral com a linha do tempo.
   O cliente vê só etapas e datas — sem responsáveis, checklist, comentários ou arquivos internos. */

const dia = (ts: string | null) => (ts ? paraDataBR(ts) : null);
const dBR = (ts: string | null) => (ts ? dataBR(dia(ts)) : "—");
const curta = (ts: string | null) => (ts ? dBR(ts).slice(0, 5) : "—");
const diasEntre = (a: string, b: string) => Math.max(0, Math.round((+new Date(dia(b)!) - +new Date(dia(a)!)) / 864e5));
const fmtD = (v: number | null) => (v == null ? "—" : `${(Math.round(v * 10) / 10).toLocaleString("pt-BR")} d`);

type Grupo = "" | "andamento" | "aguardando" | "concluido";

const atualDe = (p: PortalProcesso) => p.etapas.find((e) => e.status === "em_andamento");
const feitasDe = (p: PortalProcesso) => p.etapas.filter((e) => e.status === "concluida").length;
const concluidoDe = (p: PortalProcesso) => p.status === "concluido";
const aguardando = (p: PortalProcesso) => !!atualDe(p)?.aguardando_cliente;

function grupoDe(p: PortalProcesso): Grupo {
  if (concluidoDe(p)) return "concluido";
  if (aguardando(p)) return "aguardando";
  return "andamento";
}

function mediasPorEtapa(procs: PortalProcesso[]) {
  const acc = new Map<number, { nome: string; soma: number; n: number }>();
  procs.forEach((p) => p.etapas.forEach((e) => {
    if (e.status !== "concluida" || !e.iniciado_em || !e.concluido_em) return;
    const x = acc.get(e.ordem) ?? { nome: e.nome, soma: 0, n: 0 };
    x.soma += diasEntre(e.iniciado_em, e.concluido_em); x.n += 1; acc.set(e.ordem, x);
  }));
  return [...acc.entries()].sort((a, b) => a[0] - b[0]).map(([ordem, x]) => ({ ordem, nome: x.nome, n: x.n, media: x.soma / x.n }));
}

function Pill({ p }: { p: PortalProcesso }) {
  if (p.status === "pausado") return <span className="chip bg-sunken text-muted">Pausado</span>;
  if (concluidoDe(p)) return <span className="chip bg-ok-soft text-ok-ink"><PackageCheck size={13} /> Entregue</span>;
  const atual = atualDe(p);
  return (
    <span className="flex flex-wrap items-center gap-1.5">
      <span className="chip bg-primary-soft text-primary"><Ship size={13} /> {atual ? nomeCurto(atual.nome) : "Em andamento"}</span>
      {aguardando(p) && <span className="chip bg-warn-soft text-warn-ink">Aguardando você</span>}
    </span>
  );
}

function Kpi({ label, valor, sub, cor, ativo, onClick }: { label: string; valor: string | number; sub: string; cor: string; ativo?: boolean; onClick?: () => void }) {
  const Tag = onClick ? "button" : "div";
  return (
    <Tag type={onClick ? "button" : undefined} onClick={onClick}
      className={`relative grid gap-1 overflow-hidden rounded-xl border bg-surface px-4 py-3 text-left ${onClick ? "cursor-pointer hover:border-primary-2" : ""} ${ativo ? "border-primary-2 ring-2 ring-primary-soft" : "border-line"}`}>
      <span aria-hidden className="absolute top-0 bottom-0 left-0 w-1" style={{ background: cor }} />
      <span className="text-xs font-medium text-muted">{label}</span>
      <span className="num text-[26px] leading-none font-bold text-ink">{valor}</span>
      <span className="text-xs text-muted">{sub}</span>
    </Tag>
  );
}

function Barra({ pct, cor }: { pct: number; cor: string }) {
  return <div className="h-2.5 overflow-hidden rounded-md bg-sunken"><div className="h-full rounded-md" style={{ width: `${pct}%`, background: cor }} /></div>;
}

function Detalhe({ p, medias, onClose }: { p: PortalProcesso; medias: Map<number, number>; onClose: () => void }) {
  const atual = atualDe(p);
  const total = p.etapas.length;
  const feitas = feitasDe(p);
  const concl = concluidoDe(p);
  return (
    <>
      <div className="fixed inset-0 z-20 bg-[#0a141a]/40" onClick={onClose} aria-hidden />
      <aside className="fixed top-0 right-0 bottom-0 z-30 flex w-[min(560px,100%)] flex-col bg-surface shadow-[-8px_0_30px_rgba(0,0,0,.18)]" aria-label="Detalhe do processo">
        <div className="flex items-start justify-between gap-3 border-b border-line px-5 py-4">
          <div className="min-w-0">
            <p className="num text-xs text-primary-2">{p.codigo}{p.plano ? ` · Plano ${p.plano}` : ""}</p>
            <h3 className="mt-0.5 text-[17px] font-semibold text-ink">{p.descricao || "Processo de importação"}</h3>
            <div className="mt-1.5"><Pill p={p} /></div>
          </div>
          <button onClick={onClose} aria-label="Fechar" className="rounded p-1.5 text-muted hover:bg-sunken"><X size={18} /></button>
        </div>
        <div className="grid gap-5 overflow-y-auto px-5 pt-4 pb-8">
          <div className="border-b border-line pb-4">
            <p className={`text-[22px] leading-tight font-semibold ${concl ? "text-ok-ink" : "text-primary"}`}>
              {concl ? `Chegou em ${dBR(p.concluido_em)}` : p.previsao ? `Previsão de chegada: ${dataBR(p.previsao)}` : "Previsão de chegada a definir"}
            </p>
            <p className="mt-1 text-[13px] text-muted">{feitas} de {total} etapas concluídas · aberto em {dBR(p.aberto_em)}</p>
          </div>
          {atual?.aguardando_cliente && (
            <p className="rounded-md border border-warn/40 bg-warn-soft/60 px-3 py-2 text-[13px] text-warn-ink">
              <strong className="font-semibold">Estamos aguardando {atual.aguardando_o_que ?? "o seu retorno"}.</strong> Assim que recebermos, seguimos com o processo.
            </p>
          )}
          <section>
            <h4 className="mb-3 text-[12px] font-bold tracking-wider text-muted uppercase">Etapas do processo</h4>
            <ol>
              {p.etapas.map((e, i) => {
                const feita = e.status === "concluida", em = e.status === "em_andamento";
                const dur = feita && e.iniciado_em && e.concluido_em ? diasEntre(e.iniciado_em, e.concluido_em) : null;
                const media = medias.get(e.ordem) ?? null;
                const cls = dur == null || media == null ? "bg-sunken text-muted" : dur > media * 1.25 + 1 ? "bg-bad-soft text-bad-ink" : dur > media ? "bg-warn-soft text-warn-ink" : "bg-ok-soft text-ok-ink";
                return (
                  <li key={e.ordem} className="relative grid grid-cols-[28px_1fr] gap-3 pb-5 last:pb-0">
                    {i < p.etapas.length - 1 && <span aria-hidden className={`absolute top-[26px] -bottom-0.5 left-[13px] border-l-[3px] ${feita ? "border-solid border-ok" : "border-dashed border-line-strong"}`} />}
                    <span className={`relative z-10 grid h-[26px] w-[26px] place-items-center rounded border-2 ${feita ? "border-ok bg-ok text-white" : em ? "border-primary bg-primary text-white ring-4 ring-primary-soft" : "border-line-strong bg-surface"}`}>
                      {feita ? <Check size={14} strokeWidth={3.5} /> : em ? <span className="num text-[11px] font-semibold">{e.ordem}</span> : null}
                    </span>
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1">
                        <span className={`text-[14px] ${feita ? "font-bold text-ink" : em ? "font-bold text-primary" : "font-medium text-muted"}`}>{nomeCurto(e.nome)}</span>
                        {feita && <span className="num text-xs text-ink">{dBR(e.concluido_em)}</span>}
                        {em && <span className="num text-xs text-muted">desde {dBR(e.iniciado_em)}</span>}
                        {dur != null && <span className={`num rounded-full px-2 py-0.5 text-[11px] font-semibold ${cls}`} title={media != null ? `Média das suas importações: ${fmtD(media)}` : undefined}>{dur} d{media != null ? ` · média ${fmtD(media)}` : ""}</span>}
                        {em && e.aguardando_cliente && <span className="rounded-full bg-warn-soft px-2 py-0.5 text-[11px] font-semibold text-warn-ink">aguardando você</span>}
                      </div>
                    </div>
                  </li>
                );
              })}
            </ol>
          </section>
        </div>
      </aside>
    </>
  );
}

export default function PortalView({ dados }: { dados: PortalDados }) {
  const [filtro, setFiltro] = useState<Grupo>("");
  const [q, setQ] = useState("");
  const [plano, setPlano] = useState("");
  const [aberto, setAberto] = useState<string | null>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setAberto(null); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const procs = dados?.processos ?? [];
  const concluidos = useMemo(() => procs.filter(concluidoDe), [procs]);
  const mediasArr = useMemo(() => mediasPorEtapa(procs), [procs]);
  const medias = useMemo(() => new Map(mediasArr.map((m) => [m.ordem, m.media])), [mediasArr]);
  const planos = useMemo(() => [...new Set(procs.map((p) => p.plano).filter(Boolean) as string[])].sort(), [procs]);

  if (!dados) return <EmptyState titulo="Acesso sem cliente vinculado" texto="Fale com a equipe NowTrace para liberar o seu acesso." />;

  const nAnd = procs.filter((p) => grupoDe(p) === "andamento").length;
  const nAg = procs.filter((p) => grupoDe(p) === "aguardando").length;
  const nCon = concluidos.length;
  const tempos = concluidos.filter((p) => p.concluido_em).map((p) => diasEntre(p.aberto_em, p.concluido_em!));
  const tempoMedio = tempos.length ? tempos.reduce((a, b) => a + b, 0) / tempos.length : null;
  const maxMedia = Math.max(1, ...mediasArr.map((m) => m.media));

  const termo = q.trim().toLowerCase();
  const visiveis = procs.filter((p) => {
    if (filtro && grupoDe(p) !== filtro) return false;
    if (plano && p.plano !== plano) return false;
    if (termo && ![p.codigo, p.descricao, p.plano].join(" ").toLowerCase().includes(termo)) return false;
    return true;
  });
  const sel = procs.find((p) => p.id === aberto) ?? null;

  const hoje = new Date();
  const dow = hoje.toLocaleDateString("pt-BR", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "America/Sao_Paulo" });

  // distribuição pela etapa atual
  const etapasNomes = procs[0]?.etapas ?? [];
  const porEtapa = etapasNomes.map((e) => ({ nome: nomeCurto(e.nome), n: procs.filter((p) => !concluidoDe(p) && atualDe(p)?.ordem === e.ordem).length }));
  const maxEtapa = Math.max(1, ...porEtapa.map((x) => x.n));

  return (
    <div className="space-y-5">
      <div>
        <p className="eyebrow">Acompanhamento</p>
        <h1 className="text-xl font-semibold tracking-tight text-ink">{dados.cliente.nome}</h1>
        <p className="mt-0.5 text-[13px] text-muted">Posição de {dow} · {procs.length} {procs.length === 1 ? "processo" : "processos"}</p>
      </div>

      <section className="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-3" aria-label="Indicadores">
        <Kpi label="Total de processos" valor={procs.length} sub="importações cadastradas" cor="#172033" ativo={filtro === ""} onClick={() => setFiltro("")} />
        <Kpi label="Em andamento" valor={nAnd} sub="seguindo o fluxo" cor="#2f6b9a" ativo={filtro === "andamento"} onClick={() => setFiltro(filtro === "andamento" ? "" : "andamento")} />
        <Kpi label="Aguardando você" valor={nAg} sub={nAg ? "precisamos do seu retorno" : "nada pendente"} cor="#d99a21" ativo={filtro === "aguardando"} onClick={() => setFiltro(filtro === "aguardando" ? "" : "aguardando")} />
        <Kpi label="Concluídos" valor={nCon} sub="entregues" cor="#16a36a" ativo={filtro === "concluido"} onClick={() => setFiltro(filtro === "concluido" ? "" : "concluido")} />
        <Kpi label="Tempo médio total" valor={fmtD(tempoMedio)} sub={tempos.length ? `média de ${tempos.length} processo${tempos.length > 1 ? "s" : ""}` : "sem processos concluídos"} cor="#123b63" />
      </section>

      <section className="grid gap-5 lg:grid-cols-2">
        <div className="card px-[18px] py-4">
          <h2 className="text-[15px] font-bold text-ink">Tempo médio por etapa</h2>
          <p className="mt-1 mb-3 text-xs text-muted">Média de dias corridos das etapas já concluídas nas suas importações.</p>
          <div className="grid gap-2">
            {mediasArr.length ? mediasArr.map((m) => (
              <div key={m.ordem} className="grid grid-cols-[minmax(110px,190px)_1fr_64px] items-center gap-2.5 text-[13px]">
                <span className="truncate text-ink" title={m.nome}>{nomeCurto(m.nome)} <small className="text-muted">(n={m.n})</small></span>
                <Barra pct={Math.max(2, (m.media / maxMedia) * 100)} cor="#2f6b9a" />
                <span className="num text-right">{fmtD(m.media)}</span>
              </div>
            )) : <p className="text-[13px] text-muted">Ainda não há etapas concluídas para calcular.</p>}
          </div>
        </div>
        <div className="card px-[18px] py-4">
          <h2 className="text-[15px] font-bold text-ink">Processos por etapa</h2>
          <p className="mt-1 mb-3 text-xs text-muted">Em qual etapa está cada processo em andamento.</p>
          <div className="grid gap-2">
            {porEtapa.map((x) => (
              <div key={x.nome} className="grid grid-cols-[minmax(110px,150px)_1fr_28px] items-center gap-2.5 text-[13px]">
                <span className="truncate">{x.nome}</span>
                <Barra pct={(x.n / maxEtapa) * 100} cor="#16a36a" />
                <span className="num text-right">{x.n}</span>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section>
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <label className="relative min-w-[240px] flex-1">
            <Search size={15} className="absolute top-1/2 left-3 -translate-y-1/2 text-muted" />
            <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Buscar por código ou descrição…" aria-label="Buscar"
              className="w-full rounded-lg border border-line bg-surface py-2 pr-3 pl-9 text-[13.5px]" />
          </label>
          {planos.length > 1 && (
            <select value={plano} onChange={(e) => setPlano(e.target.value)} aria-label="Filtrar por plano" className="rounded-lg border border-line bg-surface px-3 py-2 text-[13.5px]">
              <option value="">Todos os planos</option>
              {planos.map((x) => <option key={x}>{x}</option>)}
            </select>
          )}
          {filtro && <button onClick={() => setFiltro("")} className="chip bg-primary-soft text-primary">Filtro ativo ✕</button>}
        </div>
        <div className="overflow-hidden rounded-xl border border-line bg-surface">
          <table className="hidden w-full border-collapse text-left md:table">
            <thead>
              <tr className="text-[11px] tracking-wider text-muted uppercase">
                {["Processo", "Plano", "Aberto em", "Etapa atual", "Progresso", "Previsão / chegada"].map((h) => <th key={h} className="border-b border-line px-3 py-2.5 font-semibold">{h}</th>)}
              </tr>
            </thead>
            <tbody>
              {visiveis.length ? visiveis.map((p) => {
                const pct = p.etapas.length ? (feitasDe(p) / p.etapas.length) * 100 : 0;
                return (
                  <tr key={p.id} tabIndex={0} onClick={() => setAberto(p.id)} onKeyDown={(e) => e.key === "Enter" && setAberto(p.id)}
                    className="cursor-pointer border-b border-line last:border-0 hover:bg-primary-soft/40">
                    <td className="max-w-[280px] px-3 py-2.5"><span className="num block text-[11px] text-primary-2">{p.codigo}</span><b className="line-clamp-2 text-[13.5px] font-semibold text-ink">{p.descricao || "Processo de importação"}</b></td>
                    <td className="px-3 py-2.5 text-[13px]">{p.plano ?? "—"}</td>
                    <td className="num px-3 py-2.5 text-[13px]">{dBR(p.aberto_em)}</td>
                    <td className="px-3 py-2.5"><Pill p={p} /></td>
                    <td className="min-w-[120px] px-3 py-2.5">
                      <Barra pct={pct} cor="#16a36a" />
                      <span className="num mt-1 block text-[11px] text-muted">{feitasDe(p)}/{p.etapas.length} etapas</span>
                    </td>
                    <td className="num px-3 py-2.5 text-[13px]">{concluidoDe(p) ? dBR(p.concluido_em) : p.previsao ? dataBR(p.previsao) : "—"}</td>
                  </tr>
                );
              }) : <tr><td colSpan={6} className="p-10 text-center text-muted">Nenhum processo com esses filtros.</td></tr>}
            </tbody>
          </table>
          <ul className="md:hidden">
            {visiveis.length ? visiveis.map((p) => (
              <li key={p.id} className="border-b border-line last:border-0">
                <button onClick={() => setAberto(p.id)} className="grid w-full gap-2 p-4 text-left">
                  <span className="num text-[11px] text-primary-2">{p.codigo}{p.plano ? ` · ${p.plano}` : ""}</span>
                  <b className="text-[14px] font-semibold text-ink">{p.descricao || "Processo de importação"}</b>
                  <Pill p={p} />
                  <span className="num text-xs text-muted">{concluidoDe(p) ? `Chegou em ${dBR(p.concluido_em)}` : `Previsão: ${p.previsao ? dataBR(p.previsao) : "—"}`} · {feitasDe(p)}/{p.etapas.length} etapas</span>
                </button>
              </li>
            )) : <li className="p-10 text-center text-muted">Nenhum processo com esses filtros.</li>}
          </ul>
        </div>
        <p className="mt-2 text-xs text-muted">Clique em um processo para ver a linha do tempo, com as datas de cada etapa.</p>
      </section>

      {sel && <Detalhe p={sel} medias={medias} onClose={() => setAberto(null)} />}
    </div>
  );
}
