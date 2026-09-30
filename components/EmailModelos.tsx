"use client";

import { ChevronRight, Mail, Send } from "lucide-react";
import CopiarTexto from "@/components/CopiarTexto";
import { nomeCurto } from "@/lib/status";

export type EmailPreenchido = { id: number; titulo: string; para: string | null; assunto: string; corpo: string; etapa: string | null };

/** lista de modelos de e-mail já preenchidos, com copiar e abrir no e-mail */
export default function EmailModelos({ emails }: { emails: EmailPreenchido[] }) {
  if (!emails.length) return <p className="text-[13px] text-muted">Nenhum modelo para esta etapa.</p>;
  return (
    <div className="divide-y divide-line rounded-md border border-line">
      {emails.map((e) => (
        <details key={e.id} className="group">
          <summary className="flex cursor-pointer items-center gap-2.5 px-3 py-2.5 hover:bg-sunken">
            <Mail size={15} className="shrink-0 text-subtle" />
            <span className="min-w-0 flex-1">
              <span className="block text-[13px] font-medium text-ink">{e.titulo}</span>
              <span className="block truncate text-[11.5px] text-muted">{e.assunto}</span>
            </span>
            {e.etapa && <span className="chip hidden shrink-0 bg-sunken text-muted sm:inline-flex">{nomeCurto(e.etapa)}</span>}
            <ChevronRight size={14} className="shrink-0 text-subtle transition-transform group-open:rotate-90" />
          </summary>
          <div className="space-y-3 border-t border-line bg-sunken/50 px-3 py-3 text-[13px]">
            <dl className="space-y-1">
              {e.para && <div className="grid grid-cols-[70px_1fr]"><dt className="text-muted">Para</dt><dd className="text-ink">{e.para}</dd></div>}
              {e.assunto && <div className="grid grid-cols-[70px_1fr]"><dt className="text-muted">Assunto</dt><dd className="font-medium text-ink">{e.assunto}</dd></div>}
            </dl>
            <pre className="max-h-80 overflow-y-auto rounded-md border border-line bg-surface p-3 font-sans text-[13px] leading-relaxed whitespace-pre-wrap text-ink">{e.corpo}</pre>
            <div className="flex flex-wrap gap-2">
              {e.assunto && <CopiarTexto texto={e.assunto} rotulo="Copiar assunto" className="btn-ghost h-7 text-xs" />}
              <CopiarTexto texto={e.corpo} rotulo="Copiar texto" className="btn-ghost h-7 text-xs" />
              {e.para?.includes("@") && (
                <a className="btn-primary h-7 text-xs" href={`mailto:${e.para.replace(/\s/g, "")}?subject=${encodeURIComponent(e.assunto)}&body=${encodeURIComponent(e.corpo)}`}>
                  <Send size={13} /> Abrir no e-mail
                </a>
              )}
            </div>
          </div>
        </details>
      ))}
    </div>
  );
}
