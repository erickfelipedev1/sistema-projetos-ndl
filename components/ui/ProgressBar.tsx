export default function ProgressBar({ valor, total, tom = "primary", mostrarTexto = true, className = "" }: {
  valor: number; total: number; tom?: "primary" | "ok" | "warn" | "bad"; mostrarTexto?: boolean; className?: string;
}) {
  const pct = total > 0 ? Math.round((valor / total) * 100) : 0;
  const cor = { primary: "bg-primary-2", ok: "bg-ok", warn: "bg-warn", bad: "bg-bad" }[tom];
  return (
    <div className={`flex items-center gap-2 ${className}`}>
      <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-line" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
        <div className={`h-full rounded-full ${cor} transition-[width] duration-300`} style={{ width: `${pct}%` }} />
      </div>
      {mostrarTexto && <span className="num shrink-0 text-[11px] text-muted">{valor}/{total}</span>}
    </div>
  );
}
