import { Check, PackageCheck, Ship } from "lucide-react";
import type { PortalDados, PortalProcesso } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { paraDataBR } from "@/lib/diasUteis";
import { nomeCurto } from "@/lib/status";
import EmptyState from "@/components/ui/EmptyState";

const d = (ts: string | null) => (ts ? dataBR(paraDataBR(ts)) : "—");

function Etapas({ p }: { p: PortalProcesso }) {
  return (
    <ol className="grid gap-0 md:flex md:overflow-x-auto md:pb-1 lg:overflow-visible">
      {p.etapas.map((e, i) => {
        const feita = e.status === "concluida";
        const atual = e.status === "em_andamento";
        return (
          <li key={e.ordem} className="relative flex gap-3 pb-4 last:pb-0 md:min-w-[76px] md:flex-1 md:flex-col md:items-center md:gap-0 md:pb-0 md:text-center">
            {i < p.etapas.length - 1 && (
              <span aria-hidden className={`absolute top-6 bottom-0 left-[11px] w-0.5 md:top-[11px] md:bottom-auto md:left-1/2 md:h-0.5 md:w-full ${feita ? "bg-ok" : "bg-line-strong"}`} />
            )}
            <span className={`num relative z-10 flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2 text-[10.5px] font-semibold ${
              feita ? "border-ok bg-ok text-white" : atual ? "border-primary bg-primary text-white ring-4 ring-primary-soft" : "border-line-strong bg-surface text-subtle"}`}>
              {feita ? <Check size={12} strokeWidth={3} /> : e.ordem}
            </span>
            <div className="min-w-0 md:mt-2 md:px-1">
              <p className={`text-[12.5px] leading-tight ${atual ? "font-semibold text-ink" : feita ? "text-ink" : "text-muted"}`}>{nomeCurto(e.nome)}</p>
              <p className="num mt-0.5 text-[11px] text-subtle">
                {feita ? `concluída ${d(e.concluido_em).slice(0, 5)}` : atual ? `desde ${d(e.iniciado_em).slice(0, 5)}` : ""}
              </p>
              {atual && e.aguardando_cliente && <p className="mt-0.5 text-[11px] font-medium text-warn-ink">aguardando você</p>}
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function CardProcesso({ p }: { p: PortalProcesso }) {
  const total = p.etapas.length;
  const feitas = p.etapas.filter((e) => e.status === "concluida").length;
  const atual = p.etapas.find((e) => e.status === "em_andamento");
  const concluido = p.status === "concluido";
  const pct = total ? Math.round((feitas / total) * 100) : 0;
  const espera = atual?.aguardando_cliente ? atual.aguardando_o_que : null;
  return (
    <article className="card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-line px-4 py-3.5">
        <div className="min-w-0">
          <p className="text-xs text-subtle">{p.codigo}{p.plano ? ` · Plano ${p.plano}` : ""} · aberto em {d(p.aberto_em)}</p>
          <h2 className="mt-0.5 text-[15px] font-semibold text-ink">{p.descricao || "Processo de importação"}</h2>
        </div>
        <div className="text-right">
          <p className="text-[11px] text-muted">{concluido ? "Chegou em" : "Previsão de chegada"}</p>
          <p className="num text-[18px] leading-tight font-semibold text-ink">{concluido ? d(p.concluido_em) : dataBR(p.previsao)}</p>
        </div>
      </header>
      <div className="flex flex-wrap items-center gap-3 px-4 pt-3">
        {p.status === "pausado"
          ? <span className="chip bg-sunken text-muted">Pausado</span>
          : concluido
          ? <span className="chip bg-ok-soft text-ok-ink"><PackageCheck size={13} /> Entregue</span>
          : <span className="chip bg-primary-soft text-primary"><Ship size={13} /> {atual ? `Etapa atual: ${nomeCurto(atual.nome)}` : "Em andamento"}</span>}
        <div className="flex min-w-[160px] flex-1 items-center gap-2">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-sunken"><div className="h-full rounded-full bg-ok" style={{ width: `${pct}%` }} /></div>
          <span className="num text-xs text-muted">{feitas}/{total} etapas</span>
        </div>
      </div>
      {atual?.aguardando_cliente && (
        <p className="mx-4 mt-3 rounded-md border border-warn/40 bg-warn-soft/60 px-3 py-2 text-[13px] text-warn-ink">
          <strong className="font-semibold">Estamos aguardando {espera ?? "o seu retorno"}.</strong> Assim que recebermos, seguimos com o processo.
        </p>
      )}
      <div className="px-4 py-4"><Etapas p={p} /></div>
    </article>
  );
}

/** o que o cliente vê: só etapas e datas — sem responsáveis, checklist, comentários ou arquivos internos */
export default function PortalView({ dados }: { dados: PortalDados }) {
  if (!dados) return <EmptyState titulo="Acesso sem cliente vinculado" texto="Fale com a equipe NDL para liberar o seu acesso." />;
  const ativos = dados.processos.filter((p) => p.status === "ativo" || p.status === "pausado");
  const concluidos = dados.processos.filter((p) => p.status !== "ativo");
  return (
    <div className="space-y-6">
      <div>
        <p className="eyebrow">Acompanhamento</p>
        <h1 className="text-xl font-semibold tracking-tight text-ink">{dados.cliente.nome}</h1>
        <p className="mt-0.5 text-[13px] text-muted">
          {ativos.length === 1 ? "1 processo em andamento" : `${ativos.length} processos em andamento`}
          {concluidos.length ? ` · ${concluidos.length} concluído${concluidos.length > 1 ? "s" : ""}` : ""}
        </p>
      </div>
      {ativos.length ? <div className="space-y-4">{ativos.map((p) => <CardProcesso key={p.id} p={p} />)}</div>
        : <section className="card"><EmptyState titulo="Nenhum processo em andamento" /></section>}
      {concluidos.length > 0 && (
        <div>
          <h2 className="mb-2 text-[13px] font-semibold text-muted">Concluídos</h2>
          <div className="space-y-4">{concluidos.map((p) => <CardProcesso key={p.id} p={p} />)}</div>
        </div>
      )}
    </div>
  );
}
