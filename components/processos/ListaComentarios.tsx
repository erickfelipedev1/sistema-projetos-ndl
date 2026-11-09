import { FileText } from "lucide-react";
import Avatar from "@/components/ui/Avatar";
import { relativo } from "@/lib/status";
import { bytesTexto } from "@/lib/format";

export type ComentarioView = {
  id: number; texto: string; created_at: string; autor: string | null;
  anexos: { id: string; nome: string; tamanho: number | null; tipo_mime: string | null; url: string | null }[];
};

function escapar(t: string) {
  return t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** destaca @Nome no texto (só nomes de pessoas da equipe) */
function comMencoes(texto: string, nomes: string[]) {
  if (!nomes.length) return texto;
  const re = new RegExp(`(@(?:${[...nomes].sort((a, b) => b.length - a.length).map(escapar).join("|")}))`, "gi");
  return texto.split(re).map((parte, i) =>
    i % 2 === 1 ? <span key={i} className="rounded bg-primary-soft px-1 font-medium text-primary">{parte}</span> : parte);
}

export default function ListaComentarios({ itens, nomesPessoas }: { itens: ComentarioView[]; nomesPessoas: string[] }) {
  return (
    <ol className="space-y-4">
      {itens.map((c) => (
        <li key={c.id} className="flex gap-3">
          <Avatar nome={c.autor} tamanho={28} />
          <div className="min-w-0 flex-1">
            <p className="text-[12.5px]"><strong className="font-semibold text-ink">{c.autor ?? "Sistema"}</strong> <span className="text-muted">· {relativo(c.created_at)}</span></p>
            <p className="mt-0.5 text-[13px] leading-relaxed whitespace-pre-wrap text-ink">{comMencoes(c.texto, nomesPessoas)}</p>
            {c.anexos.length > 0 && (
              <div className="mt-2 flex flex-wrap gap-2">
                {c.anexos.map((a) => {
                  const imagem = a.tipo_mime?.startsWith("image/") && a.url;
                  return imagem ? (
                    <a key={a.id} href={a.url!} target="_blank" rel="noreferrer" title={a.nome} className="block overflow-hidden rounded-md border border-line">
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={a.url!} alt={a.nome} className="max-h-44 max-w-[260px] object-cover" loading="lazy" />
                    </a>
                  ) : (
                    <a key={a.id} href={a.url ?? undefined} target="_blank" rel="noreferrer"
                      className="inline-flex max-w-[280px] items-center gap-2 rounded-md border border-line bg-surface px-2.5 py-1.5 text-[12.5px] hover:bg-sunken">
                      <FileText size={14} className="shrink-0 text-primary-2" />
                      <span className="min-w-0 truncate text-ink">{a.nome}</span>
                      <span className="num shrink-0 text-[11px] text-muted">{bytesTexto(a.tamanho)}</span>
                    </a>
                  );
                })}
              </div>
            )}
          </div>
        </li>
      ))}
    </ol>
  );
}
