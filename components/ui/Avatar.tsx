import { iniciais } from "@/lib/status";

export default function Avatar({ nome, tamanho = 24, className = "" }: { nome: string | null | undefined; tamanho?: number; className?: string }) {
  return (
    <span
      className={`inline-flex shrink-0 items-center justify-center rounded-full bg-primary-soft font-semibold text-primary ${className}`}
      style={{ width: tamanho, height: tamanho, fontSize: Math.max(9, Math.round(tamanho * 0.4)) }}
      title={nome ?? undefined}
      aria-hidden
    >
      {iniciais(nome)}
    </span>
  );
}

export function Pessoa({ nome, sub, tamanho = 24 }: { nome: string; sub?: string | null; tamanho?: number }) {
  return (
    <span className="inline-flex min-w-0 items-center gap-2">
      <Avatar nome={nome} tamanho={tamanho} />
      <span className="min-w-0 leading-tight">
        <span className="block truncate text-[13px] text-ink">{nome}</span>
        {sub && <span className="block truncate text-[11px] text-muted">{sub}</span>}
      </span>
    </span>
  );
}

/** responsável: avatar só para pessoas cadastradas; texto neutro quando é só um rótulo ("Depende da viagem") */
export function Responsavel({ ids, label, mapa, tamanho = 22, sub }: {
  ids: string[]; label: string | null; mapa: Map<string, { nome: string | null }>; tamanho?: number; sub?: string | null;
}) {
  const nomes = ids.map((id) => mapa.get(id)?.nome).filter(Boolean) as string[];
  if (!nomes.length) return <span className="text-[13px] text-muted">{label ?? "Sem responsável"}</span>;
  if (nomes.length === 1) return <Pessoa nome={nomes[0]} sub={sub} tamanho={tamanho} />;
  return (
    <span className="inline-flex min-w-0 items-center gap-2">
      <span className="flex -space-x-1.5">
        {nomes.slice(0, 3).map((n) => <Avatar key={n} nome={n} tamanho={tamanho} className="ring-2 ring-surface" />)}
      </span>
      <span className="truncate text-[13px] text-ink">{nomes.join(" / ")}</span>
    </span>
  );
}
