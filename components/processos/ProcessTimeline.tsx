import { Check } from "lucide-react";
import type { ProcessoEtapa } from "@/lib/types";
import { nomeCurto } from "@/lib/status";
import { dataBR } from "@/lib/format";
import { paraDataBR } from "@/lib/diasUteis";

export type EstadoEtapa = "concluida" | "atual" | "atrasada" | "proxima" | "concluida_atraso";

export function estadoDe(e: ProcessoEtapa, hoje: string): EstadoEtapa {
  if (e.status === "concluida") return e.prazo_em && e.concluido_em && paraDataBR(e.concluido_em) > e.prazo_em ? "concluida_atraso" : "concluida";
  if (e.status === "em_andamento") return e.prazo_em && e.prazo_em < hoje ? "atrasada" : "atual";
  return "proxima";
}

const ROTULO: Record<EstadoEtapa, string> = {
  concluida: "Concluída", concluida_atraso: "Concluída com atraso", atual: "Em andamento", atrasada: "Atrasada", proxima: "Próxima",
};

/** 12 etapas em linha: estado, responsável, início, prazo e conclusão */
export default function ProcessTimeline({ etapas, hoje, responsavel }: { etapas: ProcessoEtapa[]; hoje: string; responsavel: (e: ProcessoEtapa) => string }) {
  return (
    <div className="scroll-x">
      <ol className="flex min-w-[1100px]">
        {etapas.map((e, i) => {
          const st = estadoDe(e, hoje);
          const atual = st === "atual" || st === "atrasada";
          const circulo = {
            concluida: "border-ok bg-ok text-white",
            concluida_atraso: "border-warn bg-warn text-white",
            atual: "border-primary bg-primary text-white ring-4 ring-primary-soft",
            atrasada: "border-bad bg-bad text-white ring-4 ring-bad-soft",
            proxima: "border-line-strong bg-surface text-subtle",
          }[st];
          const linha = e.status === "concluida" ? "bg-ok" : "bg-line-strong";
          return (
            <li key={e.id} className={`relative flex-1 px-1 text-center ${atual ? "" : ""}`} aria-current={atual ? "step" : undefined}>
              {i < etapas.length - 1 && <span className={`absolute top-[13px] left-1/2 h-0.5 w-full ${linha}`} aria-hidden />}
              <span className={`num relative z-10 mx-auto flex h-[26px] w-[26px] items-center justify-center rounded-full border-2 text-[11px] font-semibold ${circulo}`}
                title={ROTULO[st]}>
                {e.status === "concluida" ? <Check size={13} strokeWidth={3} /> : e.ordem}
              </span>
              <p className={`mt-2 truncate text-[12px] ${atual ? "font-semibold text-ink" : e.status === "concluida" ? "font-medium text-ink" : "text-muted"}`} title={e.nome}>
                {nomeCurto(e.nome)}
              </p>
              <p className="truncate text-[10.5px] text-subtle">{responsavel(e)}</p>
              <p className={`num mt-1 text-[10.5px] ${st === "atrasada" ? "font-medium text-bad-ink" : st === "concluida_atraso" ? "text-warn-ink" : "text-muted"}`}>
                {e.status === "concluida" && e.concluido_em ? `✓ ${dataBR(paraDataBR(e.concluido_em)).slice(0, 5)}`
                  : e.status === "em_andamento" && e.aguardando_cliente ? "aguardando cliente"
                  : e.status === "em_andamento" ? `até ${dataBR(e.prazo_em).slice(0, 5)}`
                  : e.prazo_dias_uteis != null && e.tipo === "tarefa" ? `${e.prazo_dias_uteis} d.u.` : e.tipo === "marco" ? "marco" : ""}
              </p>
            </li>
          );
        })}
      </ol>
    </div>
  );
}
