import { AlertTriangle, CheckCircle2, CircleAlert } from "lucide-react";
import { nomeCurto } from "@/lib/status";
import { fmt1 } from "@/lib/dados";

export type LinhaGargalo = { id: number; nome: string; realizado: number; planejado: number; amostra: number };

/**
 * Tempo médio realizado × prazo, em % do prazo (uma escala só: 100% = no prazo).
 * Barras horizontais finas, linha de referência em 100%, status com ícone + texto.
 */
export default function BottleneckChart({ linhas }: { linhas: LinhaGargalo[] }) {
  if (!linhas.length) return <p className="py-8 text-center text-xs text-muted">Ainda não há etapas concluídas para comparar.</p>;
  const pcts = linhas.map((l) => (l.planejado > 0 ? (l.realizado / l.planejado) * 100 : 0));
  const max = Math.max(150, Math.ceil(Math.max(...pcts) / 25) * 25);
  const pos = (v: number) => `${(v / max) * 100}%`;
  const ordenadas = linhas.map((l, i) => ({ ...l, pct: pcts[i] })).sort((a, b) => b.pct - a.pct);

  return (
    <figure>
      <div className="relative">
        {/* grade e referência */}
        <div className="pointer-events-none absolute inset-y-0 right-[92px] left-[132px]" aria-hidden>
          {[0, 50, 100, 150, 200, 250, 300].filter((t) => t <= max).map((t) => (
            <span key={t} className={`absolute inset-y-0 w-px ${t === 100 ? "bg-ink/50" : "bg-line"}`} style={{ left: pos(t) }} />
          ))}
        </div>
        <ul className="relative space-y-1">
          {ordenadas.map((l) => {
            const tom = l.pct > 115 ? "bad" : l.pct > 100 && l.realizado - l.planejado >= 0.3 ? "warn" : "ok";
            const cor = { ok: "bg-ok", warn: "bg-warn", bad: "bg-bad" }[tom];
            const Icone = tom === "bad" ? CircleAlert : tom === "warn" ? AlertTriangle : CheckCircle2;
            const corIcone = { ok: "text-ok", warn: "text-warn", bad: "text-bad" }[tom];
            return (
              <li key={l.id} className="group relative grid h-7 grid-cols-[132px_1fr_92px] items-center">
                <span className="truncate pr-3 text-right text-xs text-ink" title={l.nome}>{nomeCurto(l.nome)}</span>
                <span className="relative h-full">
                  <span className={`absolute top-1/2 left-0 h-2.5 -translate-y-1/2 rounded-r ${cor}`} style={{ width: pos(Math.min(l.pct, max)) }} />
                  {/* tooltip */}
                  <span className="pointer-events-none absolute -top-9 z-10 hidden rounded-md border border-line bg-surface px-2.5 py-1.5 text-[11px] whitespace-nowrap shadow-[var(--shadow-pop)] group-hover:block"
                    style={{ left: pos(Math.min(l.pct, max)) }}>
                    <strong className="text-ink">{l.nome}</strong>
                    <span className="text-muted"> · {fmt1(l.realizado)} de {fmt1(l.planejado)} d.u. ({Math.round(l.pct)}%) · {l.amostra} concluídas</span>
                  </span>
                </span>
                <span className="num flex items-center justify-end gap-1 text-xs text-ink">
                  <Icone size={12} className={corIcone} aria-hidden />
                  <span>{fmt1(l.realizado)}<span className="text-muted"> / {fmt1(l.planejado)}</span></span>
                </span>
              </li>
            );
          })}
        </ul>
        {/* eixo */}
        <div className="relative mt-1 ml-[132px] mr-[92px] h-4 text-[10px] text-subtle" aria-hidden>
          {[0, 50, 100, 150, 200, 250, 300].filter((t) => t <= max).map((t) => (
            <span key={t} className={`num absolute -translate-x-1/2 ${t === 100 ? "font-semibold text-ink" : ""}`} style={{ left: pos(t) }}>{t}%</span>
          ))}
        </div>
      </div>
      <figcaption className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-muted">
        <span className="inline-flex items-center gap-1.5"><span className="h-3 w-px bg-ink/50" /> 100% = prazo</span>
        <span className="inline-flex items-center gap-1"><CheckCircle2 size={12} className="text-ok" /> dentro do prazo</span>
        <span className="inline-flex items-center gap-1"><AlertTriangle size={12} className="text-warn" /> até 15% acima</span>
        <span className="inline-flex items-center gap-1"><CircleAlert size={12} className="text-bad" /> mais de 15% acima</span>
        <span className="ml-auto">realizado/prazo em dias úteis · média das etapas concluídas</span>
      </figcaption>
    </figure>
  );
}
