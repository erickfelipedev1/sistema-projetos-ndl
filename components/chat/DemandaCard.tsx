"use client";

import Link from "next/link";
import { CalendarClock, CircleCheck, ClipboardList, RotateCcw } from "lucide-react";
import type { Mensagem } from "@/lib/types";
import { dataBR } from "@/lib/format";

export default function DemandaCard({ m, meuId, nomes, processo, onStatus }: {
  m: Mensagem; meuId: string; nomes: Record<string, string>; processo?: string | null; onStatus: (m: Mensagem, status: "aberta" | "concluida") => void;
}) {
  const aberta = m.demanda_status === "aberta";
  const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  const vencida = aberta && m.demanda_prazo && m.demanda_prazo < hoje;
  const posso = m.demanda_para === meuId || m.autor === meuId;
  return (
    <div className={`mt-1.5 max-w-lg rounded-md border px-3 py-2 ${aberta ? (vencida ? "border-bad/40 bg-bad-soft/50" : "border-warn/40 bg-warn-soft/60") : "border-ok/30 bg-ok-soft/60"}`}>
      <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
        <span className={`inline-flex items-center gap-1 font-semibold ${aberta ? "text-warn-ink" : "text-ok-ink"}`}>
          <ClipboardList size={13} /> Demanda {aberta ? "aberta" : "concluída"}
        </span>
        <span className="text-muted">para <strong className="font-medium text-ink">{m.demanda_para === meuId ? "você" : nomes[m.demanda_para ?? ""] ?? "—"}</strong></span>
        {m.demanda_prazo && <span className={`inline-flex items-center gap-1 ${vencida ? "font-medium text-bad-ink" : "text-muted"}`}><CalendarClock size={12} /> até {dataBR(m.demanda_prazo)}</span>}
        {m.processo_id && <Link href={`/processos/${m.processo_id}`} className="text-primary-2 hover:underline">{processo ?? "ver processo"}</Link>}
      </p>
      {posso && (
        <div className="mt-1.5">
          {aberta
            ? <button type="button" onClick={() => onStatus(m, "concluida")} className="btn-quiet h-7 text-xs text-ok-ink"><CircleCheck size={13} /> Marcar como concluída</button>
            : <button type="button" onClick={() => onStatus(m, "aberta")} className="btn-quiet h-7 text-xs"><RotateCcw size={13} /> Reabrir</button>}
        </div>
      )}
    </div>
  );
}
