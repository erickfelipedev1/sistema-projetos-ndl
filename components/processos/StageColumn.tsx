import type { Etapa } from "@/lib/types";
import { metaCurta } from "@/lib/format";
import { nomeCurto } from "@/lib/status";

export default function StageColumn({ etapa, total, atrasados, children }: { etapa: Pick<Etapa, "ordem" | "nome" | "area" | "tipo" | "prazo_dias_uteis" | "prazo_flex" | "prazo_full" | "prazo_premium" | "prazo_com_certificacao" | "responsaveis_label">; total: number; atrasados: number; children: React.ReactNode }) {
  return (
    <section className="flex w-[244px] shrink-0 flex-col rounded-lg border border-line bg-sunken">
      <header className="border-b border-line px-3 py-2.5">
        <div className="flex items-center justify-between gap-2">
          <p className="flex min-w-0 items-center gap-2">
            <span className="num flex h-5 w-5 shrink-0 items-center justify-center rounded bg-primary text-[10.5px] font-semibold text-white">{etapa.ordem}</span>
            <span className="truncate text-[13px] font-semibold text-ink" title={etapa.nome}>{nomeCurto(etapa.nome)}</span>
          </p>
          <span className="num text-[12px] font-semibold text-ink">{total}</span>
        </div>
        <p className="mt-1 flex items-center justify-between text-[11px] text-muted">
          <span className="truncate">{etapa.area}{etapa.responsaveis_label ? ` · ${etapa.responsaveis_label}` : ""}</span>
          <span className="shrink-0">{etapa.tipo === "tarefa" ? metaCurta(etapa) : etapa.tipo === "marco" ? "marco" : "fim"}</span>
        </p>
        {atrasados > 0 && <p className="mt-1 text-[11px] font-medium text-bad-ink">{atrasados} em atraso</p>}
      </header>
      <div className="flex flex-1 flex-col gap-2 p-2">{children}</div>
    </section>
  );
}
