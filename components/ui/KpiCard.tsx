import { ArrowDownRight, ArrowUpRight, Minus } from "lucide-react";

type Tendencia = { texto: string; direcao: "sobe" | "desce" | "igual"; bom: boolean } | null;

/** KPI: rótulo, número, contexto e tendência (só quando há dado real para comparar) */
export default function KpiCard({ rotulo, valor, unidade, contexto, tendencia, tom = "neutro", href }: {
  rotulo: string; valor: string | number; unidade?: string; contexto?: string; tendencia?: Tendencia;
  tom?: "neutro" | "bad" | "warn" | "ok"; href?: string;
}) {
  const corValor = { neutro: "text-ink", bad: "text-bad-ink", warn: "text-warn-ink", ok: "text-ok-ink" }[tom];
  const barra = { neutro: "bg-transparent", bad: "bg-bad", warn: "bg-warn", ok: "bg-ok" }[tom];
  const Icone = tendencia?.direcao === "sobe" ? ArrowUpRight : tendencia?.direcao === "desce" ? ArrowDownRight : Minus;
  const conteudo = (
    <>
      <span className={`absolute inset-y-3 left-0 w-0.5 rounded-r ${barra}`} aria-hidden />
      <p className="text-xs font-medium text-muted">{rotulo}</p>
      <p className={`num mt-1.5 text-[26px] leading-none font-semibold tracking-tight ${corValor}`}>
        {valor}
        {unidade && <span className="ml-1 text-sm font-medium text-muted">{unidade}</span>}
      </p>
      <div className="mt-2 flex min-h-4 flex-wrap items-center gap-x-2 text-[11px] text-muted">
        {tendencia && (
          <span className={`inline-flex items-center gap-0.5 font-medium ${tendencia.bom ? "text-ok-ink" : "text-bad-ink"}`}>
            <Icone size={12} strokeWidth={2.5} aria-hidden />
            {tendencia.texto}
          </span>
        )}
        {contexto && <span>{contexto}</span>}
      </div>
    </>
  );
  const cls = "card relative block px-4 py-3.5";
  return href ? <a href={href} className={`${cls} transition-colors hover:border-line-strong`}>{conteudo}</a> : <div className={cls}>{conteudo}</div>;
}
