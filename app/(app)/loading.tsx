// Aparece na hora ao trocar de tela, enquanto o servidor busca os dados
export default function Carregando() {
  return (
    <div className="animate-pulse space-y-5" role="status" aria-label="Carregando">
      <div className="space-y-2">
        <div className="h-6 w-48 rounded bg-line" />
        <div className="h-3.5 w-80 max-w-full rounded bg-line/70" />
      </div>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        {Array.from({ length: 6 }, (_, i) => <div key={i} className="card h-[86px]" />)}
      </div>
      <div className="card h-64" />
      <div className="card h-48" />
    </div>
  );
}
