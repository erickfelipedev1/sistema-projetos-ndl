"use client";

import { useOptimistic, useTransition } from "react";
import { ChevronRight, Hourglass, UserRound } from "lucide-react";
import type { ChecklistItem } from "@/lib/types";
import { marcarChecklist } from "@/app/actions";
import { limparPasso } from "@/lib/status";

/** responsaveis: por modelo_id, quem recebe a demanda automática do item (ex.: "Isabella / Cris") */
export default function Checklist({ itens, nomes, editavel = true, responsaveis = {} }: { itens: ChecklistItem[]; nomes: Record<string, string>; editavel?: boolean; responsaveis?: Record<number, string> }) {
  const [, start] = useTransition();
  const [lista, alternar] = useOptimistic(itens, (atual, id: string) => atual.map((i) => (i.id === id ? { ...i, feito: !i.feito } : i)));
  const feitos = lista.filter((i) => i.feito).length;
  const pct = lista.length ? Math.round((feitos / lista.length) * 100) : 0;

  return (
    <div>
      <div className="mb-3 flex items-center gap-3">
        <div className="h-2 flex-1 overflow-hidden rounded-full bg-line">
          <div className={`h-full rounded-full transition-[width] duration-300 ${pct === 100 ? "bg-ok" : "bg-primary-2"}`} style={{ width: `${pct}%` }} />
        </div>
        <span className="num shrink-0 text-xs font-medium text-ink">{pct}% concluído</span>
        <span className="num shrink-0 text-xs text-muted">{feitos}/{lista.length}</span>
      </div>
      <ul className="divide-y divide-line rounded-md border border-line">
        {lista.map((i) => (
          <li key={i.id} className={`group px-3 py-2 ${i.feito ? "bg-sunken/60" : ""}`}>
            <div className="flex items-start gap-2.5">
              <input type="checkbox" className="mt-[3px] h-4 w-4 shrink-0 cursor-pointer" checked={i.feito} disabled={!editavel}
                aria-label={i.titulo}
                onChange={() => start(async () => { alternar(i.id); await marcarChecklist(i.id, !i.feito); })} />
              <details className="min-w-0 flex-1">
                <summary className="flex cursor-pointer items-start justify-between gap-2">
                  <span className={`text-[13px] leading-5 ${i.feito ? "text-muted line-through decoration-subtle" : "text-ink"}`}>
                    {i.aguarda_cliente && <span className={`mr-1.5 inline-flex items-center gap-1 rounded px-1.5 py-px align-[1px] text-[10.5px] font-medium no-underline ${i.feito ? "bg-ok-soft text-ok-ink" : "bg-primary-soft text-primary"}`}><Hourglass size={11} />{i.feito ? "cliente respondeu" : "espera do cliente"}</span>}
                    {limparPasso(i.titulo)}
                    {i.modelo_id && responsaveis[i.modelo_id] && (
                      <span className="ml-1.5 inline-flex items-center gap-1 rounded bg-sunken px-1.5 py-px align-[1px] text-[10.5px] font-medium text-muted no-underline">
                        <UserRound size={11} />{responsaveis[i.modelo_id]}{!i.feito && (i.avisado_em ? " · demanda enviada" : " · avisa quando liberar")}
                      </span>
                    )}
                  </span>
                  <span className="flex shrink-0 items-center gap-2 text-[11px] text-subtle">
                    {i.feito && i.feito_em && (
                      <span className="num">{nomes[i.feito_por ?? ""] ? `${nomes[i.feito_por ?? ""]} · ` : ""}{new Date(i.feito_em).toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit", timeZone: "America/Sao_Paulo" })}</span>
                    )}
                    {i.descricao && <ChevronRight size={14} className="transition-transform group-[&:has(details[open])]:rotate-90" />}
                  </span>
                </summary>
                {i.descricao && <p className="mt-1.5 mb-1 whitespace-pre-line text-xs leading-relaxed text-muted">{i.descricao}</p>}
              </details>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
