export default function PageHeader({ titulo, subtitulo, acoes, children }: {
  titulo: string; subtitulo?: string; acoes?: React.ReactNode; children?: React.ReactNode;
}) {
  return (
    <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
      <div className="min-w-0">
        {children}
        <h1 className="text-xl font-semibold tracking-tight text-ink">{titulo}</h1>
        {subtitulo && <p className="mt-0.5 text-[13px] text-muted">{subtitulo}</p>}
      </div>
      {acoes && <div className="flex flex-wrap items-center gap-2">{acoes}</div>}
    </div>
  );
}
