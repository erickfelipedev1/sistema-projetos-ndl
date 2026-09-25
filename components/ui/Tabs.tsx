import Link from "next/link";

/** abas de navegação por URL (server-friendly) */
export default function Tabs({ itens, ativo, className = "" }: {
  itens: { chave: string; rotulo: string; href: string; contagem?: number }[]; ativo: string; className?: string;
}) {
  return (
    <nav className={`flex gap-5 border-b border-line ${className}`} aria-label="Abas">
      {itens.map((t) => {
        const on = t.chave === ativo;
        return (
          <Link key={t.chave} href={t.href} scroll={false} aria-current={on ? "page" : undefined}
            className={`-mb-px inline-flex h-9 items-center gap-1.5 border-b-2 text-[13px] font-medium transition-colors ${on ? "border-primary text-primary" : "border-transparent text-muted hover:text-ink"}`}>
            {t.rotulo}
            {t.contagem !== undefined && (
              <span className={`num rounded px-1.5 text-[11px] ${on ? "bg-primary-soft text-primary" : "bg-sunken text-muted"}`}>{t.contagem}</span>
            )}
          </Link>
        );
      })}
    </nav>
  );
}

/** controle segmentado (ex.: Kanban | Lista) */
export function Segmented({ itens, ativo }: { itens: { chave: string; rotulo: React.ReactNode; href: string }[]; ativo: string }) {
  return (
    <div className="inline-flex rounded-md border border-line bg-surface p-0.5">
      {itens.map((i) => (
        <Link key={i.chave} href={i.href} scroll={false}
          className={`inline-flex h-7 items-center gap-1.5 rounded px-2.5 text-xs font-medium ${i.chave === ativo ? "bg-primary-soft text-primary" : "text-muted hover:text-ink"}`}>
          {i.rotulo}
        </Link>
      ))}
    </div>
  );
}
