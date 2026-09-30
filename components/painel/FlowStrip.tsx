import Link from "next/link";
import { nomeCurto } from "@/lib/status";
import { fmt1 } from "@/lib/dados";

export type EtapaFluxo = {
  id: number; ordem: number; nome: string; area: string; tipo: string;
  emAndamento: number; atrasadas: number; mediaReal: number | null; meta: number | null; metaTexto: string;
};

function tomDe(e: EtapaFluxo): "ok" | "warn" | "bad" | "neutro" {
  if (e.mediaReal === null || !e.meta) return e.atrasadas > 0 ? "warn" : "neutro";
  const r = e.mediaReal / e.meta;
  if (r > 1.15) return "bad";
  if ((r > 1 && e.mediaReal - e.meta >= 0.3) || e.atrasadas > 0) return "warn";
  return "ok";
}
const COR = {
  ok: { anel: "border-ok bg-ok-soft text-ok-ink", linha: "bg-ok" },
  warn: { anel: "border-warn bg-warn-soft text-warn-ink", linha: "bg-warn" },
  bad: { anel: "border-bad bg-bad-soft text-bad-ink", linha: "bg-bad" },
  neutro: { anel: "border-line-strong bg-surface text-muted", linha: "bg-line-strong" },
};

/** Fluxo horizontal das 12 etapas: quantidade, média realizada e meta */
export default function FlowStrip({ etapas }: { etapas: EtapaFluxo[] }) {
  return (
    <div className="scroll-x">
      <ol className="grid min-w-[1080px] grid-cols-12">
        {etapas.map((e, i) => {
          const tom = tomDe(e);
          return (
            <li key={e.id} className="relative px-1.5">
              {i < etapas.length - 1 && <span className="absolute top-[15px] left-1/2 h-px w-full bg-line-strong" aria-hidden />}
              <Link href={`/processos?etapa=${e.id}`} className="group relative flex flex-col items-center text-center">
                <span className={`num relative z-10 flex h-[30px] w-[30px] items-center justify-center rounded-full border-2 text-[12px] font-semibold ${COR[tom].anel}`}>
                  {e.ordem}
                </span>
                <span className="mt-2 line-clamp-2 min-h-[30px] text-[12px] leading-[15px] font-medium text-ink group-hover:text-primary-2" title={e.nome}>{nomeCurto(e.nome)}</span>
                <span className="text-[10.5px] text-subtle">{e.area}</span>
                <span className="num mt-2 text-lg leading-none font-semibold text-ink">{e.emAndamento}</span>
                <span className="text-[10.5px] text-muted">{e.emAndamento === 1 ? "processo" : "processos"}</span>
                {e.tipo === "tarefa" ? (
                  <span className="mt-1.5 text-[10.5px] leading-tight text-muted">
                    <span className={`num font-medium ${e.mediaReal !== null && e.meta && e.mediaReal / e.meta > 1.15 ? "text-bad-ink" : e.mediaReal !== null && e.meta && e.mediaReal - e.meta >= 0.3 ? "text-warn-ink" : "text-ink"}`}>{fmt1(e.mediaReal)} d.u.</span>
                    <br />meta {e.metaTexto}
                  </span>
                ) : (
                  <span className="mt-1.5 text-[10.5px] text-subtle">{e.tipo === "marco" ? "marco" : "fim"}</span>
                )}
                {e.atrasadas > 0 && <span className="num mt-1 text-[10.5px] font-semibold text-bad-ink">{e.atrasadas} atrasado{e.atrasadas > 1 ? "s" : ""}</span>}
              </Link>
            </li>
          );
        })}
      </ol>
    </div>
  );
}
