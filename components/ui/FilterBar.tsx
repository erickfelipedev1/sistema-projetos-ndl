"use client";

import { useRef } from "react";
import { Search, X } from "lucide-react";

export type Filtro = { nome: string; rotulo: string; valor: string; opcoes: { valor: string; rotulo: string }[] };

/** filtros em uma linha; aplicam ao mudar */
export default function FilterBar({ filtros, busca, ocultos, limparHref }: {
  filtros: Filtro[]; busca?: string; ocultos?: Record<string, string>; limparHref: string;
}) {
  const ref = useRef<HTMLFormElement>(null);
  const ativos = filtros.filter((f) => f.valor).length + (busca ? 1 : 0);
  return (
    <form ref={ref} className="flex flex-wrap items-center gap-2">
      {Object.entries(ocultos ?? {}).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
      <div className="relative">
        <Search size={14} className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-subtle" />
        <input name="q" defaultValue={busca} placeholder="Empresa ou contato" className="input h-8 w-48! pl-8" />
      </div>
      {filtros.map((f) => (
        <select key={f.nome} name={f.nome} defaultValue={f.valor} onChange={() => ref.current?.requestSubmit()} aria-label={f.rotulo}
          className={`input h-8 w-auto! pr-7 ${f.valor ? "border-primary-2/60 bg-primary-soft text-primary" : ""}`}>
          <option value="">{f.rotulo}</option>
          {f.opcoes.map((o) => <option key={o.valor} value={o.valor}>{o.rotulo}</option>)}
        </select>
      ))}
      {ativos > 0 && (
        <a href={limparHref} className="btn-quiet h-8 text-xs"><X size={13} /> Limpar ({ativos})</a>
      )}
    </form>
  );
}
