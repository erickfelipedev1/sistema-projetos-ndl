import Link from "next/link";
import { CheckCircle2, MessageSquare, RotateCcw, CalendarClock, UserRound, PlusCircle, Flag, Info } from "lucide-react";
import { relativo } from "@/lib/status";

export type Atividade = { id: number; tipo: string; texto: string; created_at: string; autor: string | null; processo_id?: string; processo?: string | null };

const ICONE: Record<string, typeof Info> = {
  avanco: CheckCircle2, comentario: MessageSquare, retorno: RotateCcw, prazo: CalendarClock,
  responsavel: UserRound, criado: PlusCircle, status: Flag, situacao: Info,
};
const COR: Record<string, string> = {
  avanco: "text-ok", comentario: "text-primary-2", retorno: "text-warn", prazo: "text-primary-2",
  responsavel: "text-primary-2", criado: "text-muted", status: "text-bad", situacao: "text-warn",
};

export default function ActivityTimeline({ itens, mostrarProcesso = true }: { itens: Atividade[]; mostrarProcesso?: boolean }) {
  return (
    <ol className="relative">
      {itens.map((a, i) => {
        const Icone = ICONE[a.tipo] ?? Info;
        const primeira = a.texto.split("\n")[0];
        const resto = a.texto.split("\n").slice(1).join(" ");
        return (
          <li key={a.id} className="relative flex gap-3 pb-3.5 last:pb-0">
            {i < itens.length - 1 && <span className="absolute top-6 bottom-0 left-[11px] w-px bg-line" aria-hidden />}
            <span className="relative z-10 mt-0.5 flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-full border border-line bg-surface">
              <Icone size={12} className={COR[a.tipo] ?? "text-muted"} />
            </span>
            <div className="min-w-0 flex-1 text-[12.5px] leading-snug">
              <p className="text-ink">
                <span className="font-medium">{a.autor ?? "Sistema"}</span>{" "}
                <span className="text-muted">{a.tipo === "comentario" ? "comentou:" : ""}</span>{" "}
                {a.tipo === "comentario" ? <span className="text-ink">“{primeira}”</span> : <span>{primeira.charAt(0).toLowerCase() + primeira.slice(1)}</span>}
              </p>
              {resto && <p className="mt-0.5 text-muted">{resto}</p>}
              <p className="mt-0.5 text-[11px] text-subtle">
                {mostrarProcesso && a.processo && a.processo_id && (
                  <><Link href={`/processos/${a.processo_id}`} className="text-muted hover:text-primary-2">{a.processo}</Link> · </>
                )}
                {relativo(a.created_at)}
              </p>
            </div>
          </li>
        );
      })}
    </ol>
  );
}
