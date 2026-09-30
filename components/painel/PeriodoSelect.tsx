"use client";

import { CalendarDays, ChevronDown } from "lucide-react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";

const OPCOES = [
  { valor: "30", rotulo: "Últimos 30 dias" },
  { valor: "90", rotulo: "Últimos 90 dias" },
  { valor: "180", rotulo: "Últimos 6 meses" },
];

/** período do fluxo (média por etapa e tempo de conclusão) */
export default function PeriodoSelect({ valor }: { valor: string }) {
  const router = useRouter();
  const sp = useSearchParams();
  const path = usePathname();
  return (
    <label className="relative inline-flex h-9 items-center rounded-md border border-line bg-surface pr-8 pl-9 text-[13px] text-ink shadow-[var(--shadow-card)]">
      <CalendarDays size={15} className="pointer-events-none absolute left-3 text-muted" aria-hidden />
      <select value={valor} aria-label="Período" className="cursor-pointer appearance-none bg-transparent outline-none"
        onChange={(e) => { const u = new URLSearchParams(sp.toString()); u.set("periodo", e.target.value); router.replace(`${path}?${u.toString()}`, { scroll: false }); }}>
        {OPCOES.map((o) => <option key={o.valor} value={o.valor}>{o.rotulo}</option>)}
      </select>
      <ChevronDown size={14} className="pointer-events-none absolute right-2.5 text-muted" aria-hidden />
    </label>
  );
}
