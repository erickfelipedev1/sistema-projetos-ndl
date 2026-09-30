import Link from "next/link";
import { Plus, Search } from "lucide-react";

export default function Topbar() {
  const hoje = new Date().toLocaleDateString("pt-BR", { weekday: "long", day: "numeric", month: "long", timeZone: "America/Sao_Paulo" });
  return (
    <header className="sticky top-0 z-20 flex h-14 items-center gap-3 border-b border-line bg-surface/95 px-5 backdrop-blur">
      <form action="/processos" className="relative w-full max-w-md">
        <Search size={15} className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-subtle" />
        <input name="q" placeholder="Buscar processo, empresa ou contato…" className="input h-8 bg-sunken pl-8" aria-label="Buscar processos" />
      </form>
      <div className="ml-auto flex items-center gap-3">
        <span className="hidden text-xs text-muted first-letter:uppercase xl:inline">{hoje}</span>
        <Link href="/processos/novo" className="btn-primary"><Plus size={15} /> Novo processo</Link>
      </div>
    </header>
  );
}
