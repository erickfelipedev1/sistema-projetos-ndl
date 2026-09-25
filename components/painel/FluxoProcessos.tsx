import Link from "next/link";
import {
  Activity, AlertTriangle, ArrowRight, CalendarDays, Calculator, CircleCheck, CircleDot, Clock, ClipboardList, FileText,
  Flag, Gauge, Ship, ShieldCheck, Truck, UserRound,
} from "lucide-react";
import { nomeCurto } from "@/lib/status";
import { fmt1 } from "@/lib/dados";
import PeriodoSelect from "./PeriodoSelect";

export type Tom = "ok" | "warn" | "bad" | "neutro";
export type EtapaFluxo = {
  id: number; ordem: number; nome: string; area: string; tipo: string;
  emAndamento: number; atrasadas: number; atencao: number; mediaReal: number | null; meta: number | null; passagens: number;
};
export type ResumoFluxo = {
  noPrazo: number; atencao: number; atrasado: number; aguardando: number;
  total: number; tempoMedio: number | null; concluidos: number; metaFluxo: number;
};

/** situação da etapa: cinza = ninguém passou no período; vermelho = média acima da meta; laranja = há atraso/atenção agora */
export function tomEtapa(e: EtapaFluxo): Tom {
  if (e.emAndamento === 0 && e.passagens === 0) return "neutro";
  if (e.tipo === "tarefa" && e.mediaReal !== null && e.meta && e.mediaReal > e.meta * 1.15) return "bad";
  if (e.atrasadas > 0 || e.atencao > 0 || (e.tipo === "tarefa" && e.mediaReal !== null && e.meta && e.mediaReal > e.meta)) return "warn";
  return "ok";
}

const TOM = {
  ok: { topo: "bg-ok", bola: "bg-ok text-white", chip: "bg-ok-soft text-ok-ink", ponto: "bg-ok", rotulo: "No prazo" },
  warn: { topo: "bg-warn", bola: "bg-warn text-white", chip: "bg-warn-soft text-warn-ink", ponto: "bg-warn", rotulo: "Atenção" },
  bad: { topo: "bg-bad", bola: "bg-bad text-white", chip: "bg-bad-soft text-bad-ink", ponto: "bg-bad", rotulo: "Atrasado" },
  neutro: { topo: "bg-line-strong", bola: "bg-subtle text-white", chip: "bg-sunken text-muted", ponto: "bg-subtle", rotulo: "Não iniciado" },
} as const;

function iconeDa(e: { nome: string; area: string }) {
  const n = e.nome.toLowerCase();
  if (n.includes("onboarding") || n.includes("apresentação /")) return UserRound;
  if (n.includes("estimativa")) return Calculator;
  if (n.includes("projeto")) return FileText;
  if (n.includes("ordem") || n.includes("processo")) return ClipboardList;
  if (n.includes("booking")) return CalendarDays;
  if (n.includes("viagem")) return Ship;
  if (n.includes("desembara")) return ShieldCheck;
  if (n.includes("liberado")) return CircleCheck;
  if (n.includes("transporte")) return Truck;
  if (n.includes("chegou")) return Flag;
  return CircleDot;
}

const d = (n: number | null) => (n === null ? "—" : `${fmt1(n)} d`);

function Bola({ tom, n, grande = false }: { tom: Tom; n: number; grande?: boolean }) {
  return (
    <span className={`num inline-flex shrink-0 items-center justify-center rounded-full font-semibold ${TOM[tom].bola} ${grande ? "h-8 w-8 text-[13px]" : "h-5 w-5 text-[10.5px]"}`}>{n}</span>
  );
}

function Chip({ tom }: { tom: Tom }) {
  return (
    <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium whitespace-nowrap ${TOM[tom].chip}`}>
      <span className={`h-1.5 w-1.5 rounded-full ${TOM[tom].ponto}`} />{TOM[tom].rotulo}
    </span>
  );
}

function CardEtapa({ e }: { e: EtapaFluxo }) {
  const tom = tomEtapa(e);
  const Icone = iconeDa(e);
  return (
    <Link href={`/processos?etapa=${e.id}`}
      className="group relative flex h-full flex-col overflow-hidden rounded-lg border border-line bg-surface px-3.5 pt-4 pb-3 shadow-[var(--shadow-card)] transition hover:-translate-y-0.5 hover:border-primary-2/40">
      <span className={`absolute inset-x-0 top-0 h-[3px] ${TOM[tom].topo}`} aria-hidden />
      <div className="flex items-center gap-2.5">
        <Bola tom={tom} n={e.ordem} grande />
        <Icone size={17} strokeWidth={1.8} className="text-muted" aria-hidden />
      </div>
      <p className="mt-3 line-clamp-2 min-h-[38px] text-[14px] leading-[19px] font-semibold text-ink group-hover:text-primary" title={e.nome}>{nomeCurto(e.nome).replace(" · ", " / ")}</p>
      <p className="num mt-2 text-[20px] leading-none font-semibold text-ink">{e.emAndamento}</p>
      <p className="text-[12px] text-muted">{e.emAndamento === 1 ? "processo" : "processos"}</p>
      <div className="mt-3 grid grid-cols-2 divide-x divide-line rounded-md bg-sunken/70 py-1.5 text-center whitespace-nowrap">
        <div className="leading-tight"><span className="num inline-flex items-center gap-1 text-[12px] font-medium text-ink"><Clock size={11} className="text-subtle" aria-hidden />{e.tipo === "tarefa" ? d(e.mediaReal) : "—"}</span><span className="block text-[10px] text-subtle">média</span></div>
        <div className="leading-tight"><span className="num block text-[12px] font-medium text-ink">{e.tipo === "tarefa" ? d(e.meta) : e.tipo === "marco" ? "marco" : "—"}</span><span className="block text-[10px] text-subtle">meta</span></div>
      </div>
      <p className={`mt-2 flex min-h-4 items-center gap-1 text-[11.5px] font-medium ${e.atrasadas ? "text-bad-ink" : "text-warn-ink"}`}>
        {e.atrasadas > 0 ? <><AlertTriangle size={12} /> {e.atrasadas} atrasado{e.atrasadas > 1 ? "s" : ""}</>
          : e.atencao > 0 ? <><Clock size={12} /> {e.atencao} em atenção</> : null}
      </p>
    </Link>
  );
}

function TabelaEtapas({ linhas }: { linhas: EtapaFluxo[] }) {
  return (
    <table className="w-full text-[12.5px]">
      <thead>
        <tr className="text-left text-[11px] text-muted">
          <th className="py-1.5 font-medium">Etapa</th><th className="py-1.5 text-right font-medium">Processos</th>
          <th className="py-1.5 text-right font-medium whitespace-nowrap">Média (dias)</th><th className="py-1.5 text-right font-medium whitespace-nowrap">Meta (dias)</th>
          <th className="py-1.5 pl-3 font-medium">Status</th>
        </tr>
      </thead>
      <tbody className="divide-y divide-line">
        {linhas.map((e) => {
          const tom = tomEtapa(e);
          return (
            <tr key={e.id}>
              <td className="py-1.5"><Link href={`/processos?etapa=${e.id}`} className="flex items-center gap-2 text-ink hover:text-primary-2"><Bola tom={tom} n={e.ordem} /><span className="truncate">{nomeCurto(e.nome).replace(" · ", " / ")}</span></Link></td>
              <td className="num py-1.5 text-right">{e.emAndamento}</td>
              <td className="num py-1.5 text-right">{e.tipo === "tarefa" && e.mediaReal !== null ? fmt1(e.mediaReal) : "—"}</td>
              <td className="num py-1.5 text-right">{e.tipo === "tarefa" && e.meta ? fmt1(e.meta) : "—"}</td>
              <td className="py-1.5 pl-3"><Chip tom={tom} /></td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

export default function FluxoProcessos({ etapas, resumo, periodo }: { etapas: EtapaFluxo[]; resumo: ResumoFluxo; periodo: string }) {
  const metade = Math.ceil(etapas.length / 2);
  const atencao = etapas.filter((e) => e.atrasadas > 0 || tomEtapa(e) === "bad").sort((a, b) => b.atrasadas - a.atrasadas);
  const totalBarra = resumo.noPrazo + resumo.atencao + resumo.atrasado + resumo.aguardando || 1;
  const seg = (n: number) => `${(n / totalBarra) * 100}%`;

  return (
    <section className="space-y-4" aria-labelledby="fluxo-titulo">
      {/* cabeçalho */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="flex h-11 w-11 items-center justify-center rounded-lg bg-primary-soft text-primary-2"><Activity size={22} /></span>
          <div>
            <h2 id="fluxo-titulo" className="text-[18px] font-semibold tracking-tight text-ink">Fluxo dos processos</h2>
            <p className="text-[13px] text-muted">Acompanhe o andamento dos processos em cada etapa, com tempo médio, meta e volume.</p>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-4">
          <div className="hidden items-center gap-4 text-[12px] text-muted lg:flex">
            {(["ok", "warn", "bad", "neutro"] as Tom[]).map((t) => (
              <span key={t} className="inline-flex items-center gap-1.5"><span className={`h-2 w-2 rounded-full ${TOM[t].ponto}`} />{t === "ok" ? "Dentro do prazo" : TOM[t].rotulo}</span>
            ))}
          </div>
          <PeriodoSelect valor={periodo} />
        </div>
      </div>

      {/* etapas */}
      <ol className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5 lg:gap-5 3xl:grid-cols-10">
        {etapas.map((e, i) => (
          <li key={e.id} className="relative">
            <CardEtapa e={e} />
            {i < etapas.length - 1 && (
              <ArrowRight size={14} aria-hidden
                className={`absolute top-1/2 -right-[17px] hidden -translate-y-1/2 text-subtle lg:block ${(i + 1) % 5 === 0 ? "lg:hidden 3xl:block" : ""}`} />
            )}
          </li>
        ))}
      </ol>

      <div className="grid gap-4 lg:grid-cols-2 3xl:grid-cols-[minmax(0,1fr)_minmax(0,1.75fr)_minmax(0,0.8fr)]">
        {/* resumo */}
        <div className="card px-5 py-4">
          <h3 className="text-[14px] font-semibold text-ink">Resumo do fluxo</h3>
          <div className="mt-4 grid grid-cols-2 gap-y-3 sm:grid-cols-4 sm:divide-x sm:divide-line">
            {[
              { n: resumo.noPrazo, t: "no prazo", c: "bg-ok" },
              { n: resumo.atencao, t: "com atenção", c: "bg-warn" },
              { n: resumo.atrasado, t: resumo.atrasado === 1 ? "atrasado" : "atrasados", c: "bg-bad" },
              { n: resumo.aguardando, t: "aguardando cliente", c: "bg-subtle" },
            ].map((k, i) => (
              <div key={k.t} className={i ? "sm:pl-3" : ""}>
                <p className="num text-[24px] leading-none font-semibold text-ink">{k.n}</p>
                <p className="mt-1.5 flex items-center gap-1.5 text-[11.5px] leading-tight text-muted"><span className={`h-2 w-2 shrink-0 rounded-full ${k.c}`} />{k.t}</p>
              </div>
            ))}
          </div>
          <div className="mt-4 flex h-2 overflow-hidden rounded-full bg-sunken" role="img"
            aria-label={`${resumo.noPrazo} no prazo, ${resumo.atencao} com atenção, ${resumo.atrasado} atrasados, ${resumo.aguardando} aguardando cliente`}>
            <span className="bg-ok" style={{ width: seg(resumo.noPrazo) }} />
            <span className="bg-warn" style={{ width: seg(resumo.atencao) }} />
            <span className="bg-bad" style={{ width: seg(resumo.atrasado) }} />
            <span className="bg-subtle/60" style={{ width: seg(resumo.aguardando) }} />
          </div>
          <div className="mt-4 grid gap-3 border-t border-line pt-3 sm:grid-cols-3 sm:gap-0 sm:divide-x sm:divide-line">
            <div><p className="text-[11px] text-muted">Processos ativos</p><p className="num mt-1 text-[16px] font-semibold text-ink">{resumo.total}</p></div>
            <div className="sm:pl-3"><p className="text-[11px] text-muted">Tempo médio de conclusão</p><p className="num mt-1 flex items-center gap-1.5 text-[14px] font-semibold text-ink"><Clock size={14} className="text-subtle" />{resumo.tempoMedio === null ? "—" : `${fmt1(resumo.tempoMedio)} dias úteis`}</p>{resumo.concluidos > 0 && <p className="text-[10.5px] text-subtle">{resumo.concluidos} concluído{resumo.concluidos > 1 ? "s" : ""} no período</p>}</div>
            <div className="sm:pl-3"><p className="text-[11px] text-muted">Meta do fluxo</p><p className="num mt-1 flex items-center gap-1.5 text-[14px] font-semibold text-ink"><Gauge size={14} className="text-subtle" />{resumo.metaFluxo} dias úteis</p></div>
          </div>
        </div>

        {/* detalhamento */}
        <div className="card px-5 py-4">
          <h3 className="text-[14px] font-semibold text-ink">Detalhamento por etapa</h3>
          <div className="mt-2 grid gap-x-8 3xl:grid-cols-2">
            <div className="scroll-x"><div className="min-w-[440px]"><TabelaEtapas linhas={etapas.slice(0, metade)} /></div></div>
            <div className="scroll-x"><div className="min-w-[440px]"><TabelaEtapas linhas={etapas.slice(metade)} /></div></div>
          </div>
          <Link href="/processos" className="mt-3 inline-flex items-center gap-1 text-[12px] text-primary-2 hover:underline">Ver todas as etapas <ArrowRight size={12} /></Link>
        </div>

        {/* atenção necessária */}
        <div className={`rounded-lg border px-4 py-4 lg:col-span-2 3xl:col-span-1 ${atencao.length ? "border-bad/20 bg-bad-soft/50" : "border-ok/20 bg-ok-soft/50"}`}>
          <div className="flex items-center justify-between gap-2">
            <h3 className={`flex items-center gap-2 text-[14px] font-semibold ${atencao.length ? "text-bad-ink" : "text-ok-ink"}`}>
              {atencao.length ? <AlertTriangle size={17} /> : <CircleCheck size={17} />} Atenção necessária
            </h3>
            {atencao.length > 0 && <span className="num flex h-5 min-w-5 items-center justify-center rounded-full bg-bad px-1.5 text-[11px] font-semibold text-white">{atencao.length}</span>}
          </div>
          {atencao.length ? (
            <ul className="mt-3 grid gap-2 sm:grid-cols-2 xl:grid-cols-4 3xl:grid-cols-1">
              {atencao.slice(0, 4).map((e) => (
                <li key={e.id}>
                  <Link href={`/processos?etapa=${e.id}${e.atrasadas ? "&status=atrasado" : ""}`} className="flex gap-3 rounded-md bg-surface px-3 py-2.5 shadow-[var(--shadow-card)] hover:ring-1 hover:ring-bad/30">
                    <Bola tom={tomEtapa(e)} n={e.ordem} grande />
                    <span className="min-w-0">
                      <span className="block truncate text-[13px] font-semibold text-ink">{nomeCurto(e.nome)}</span>
                      <span className="block text-[12px] text-muted">{e.emAndamento} {e.emAndamento === 1 ? "processo" : "processos"}</span>
                      {e.atrasadas > 0
                        ? <span className="mt-1 flex items-center gap-1 text-[12px] font-medium text-bad-ink"><Clock size={12} /> {e.atrasadas} atrasado{e.atrasadas > 1 ? "s" : ""}</span>
                        : <span className="mt-1 block text-[12px] font-medium text-bad-ink">média {d(e.mediaReal)} · meta {d(e.meta)}</span>}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          ) : <p className="mt-3 text-[13px] text-ok-ink">Nenhuma etapa com atraso agora.</p>}
          <Link href="/processos?status=atrasado" className="mt-3 inline-flex items-center gap-1 text-[12px] text-muted hover:text-ink">Ver processos <ArrowRight size={12} /></Link>
        </div>
      </div>
    </section>
  );
}
