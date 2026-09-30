"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Download, FileText, Loader2, Paperclip, Trash2, Upload } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { excluirAnexo, linkAnexo, registrarAnexo } from "@/app/actions";
import SubmitButton from "@/components/ui/SubmitButton";

export type AnexoView = { id: string; nome: string; tamanho: number | null; autor: string | null; created_at: string };
export type Destino = { processo_id?: string | null; processo_etapa_id?: string | null; cliente_id?: string | null };
export type GrupoAnexos = { chave: string; titulo: string; sub?: string; href?: string; destaque?: boolean; anexos: AnexoView[]; destino?: Destino };

const LIMITE_MB = 50;

export function tamanhoTexto(b: number | null) {
  if (b == null) return "";
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${Math.round(b / 1024)} KB`;
  return `${(b / 1024 / 1024).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} MB`;
}

function nomeSeguro(nome: string) {
  const limpo = nome.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^A-Za-z0-9._-]+/g, "_").replace(/_+/g, "_");
  return limpo.slice(-120) || "arquivo";
}

/** envia arquivos para o Storage (bucket privado "anexos") e registra na tabela anexos */
export function useEnviar(destino: Destino) {
  const router = useRouter();
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [, startTransition] = useTransition();

  async function enviar(arquivos: FileList | File[]) {
    const lista = Array.from(arquivos);
    if (!lista.length) return;
    setErro(null);
    const grandes = lista.filter((f) => f.size > LIMITE_MB * 1024 * 1024);
    if (grandes.length) return setErro(`Arquivo acima de ${LIMITE_MB} MB: ${grandes.map((g) => g.name).join(", ")}`);
    setEnviando(true);
    const supabase = createClient();
    try {
      for (const f of lista) {
        const pasta = destino.processo_id ? `${destino.processo_id}/${destino.processo_etapa_id ?? "geral"}` : `clientes/${destino.cliente_id}`;
        const caminho = `${pasta}/${crypto.randomUUID()}-${nomeSeguro(f.name)}`;
        const up = await supabase.storage.from("anexos").upload(caminho, f, { contentType: f.type || undefined, upsert: false });
        if (up.error) throw new Error(up.error.message);
        const { error } = await supabase.from("anexos").insert({
          processo_id: destino.processo_id ?? null,
          processo_etapa_id: destino.processo_etapa_id ?? null,
          cliente_id: destino.cliente_id ?? null,
          nome: f.name, caminho, tamanho: f.size, tipo_mime: f.type || null,
        });
        if (error) {
          await supabase.storage.from("anexos").remove([caminho]);
          throw new Error(error.message);
        }
        if (destino.processo_id) await registrarAnexo(destino.processo_id, f.name);
      }
      startTransition(() => router.refresh());
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setErro(/bucket not found/i.test(msg) ? "O armazenamento de arquivos ainda não foi configurado (bucket \"anexos\")." : `Não foi possível enviar: ${msg}`);
    } finally {
      setEnviando(false);
    }
  }
  return { enviar, enviando, erro };
}

/** botão compacto "Anexar arquivo" (usado no card da etapa atual) */
export function AnexarBotao({ destino, rotulo = "Anexar arquivo", className = "btn-ghost" }: { destino: Destino; rotulo?: string; className?: string }) {
  const ref = useRef<HTMLInputElement>(null);
  const { enviar, enviando, erro } = useEnviar(destino);
  return (
    <span className="inline-flex flex-col">
      <button type="button" className={className} onClick={() => ref.current?.click()} disabled={enviando}>
        {enviando ? <Loader2 size={14} className="animate-spin" /> : <Paperclip size={14} />} {enviando ? "Enviando…" : rotulo}
      </button>
      <input ref={ref} type="file" multiple hidden onChange={(e) => { if (e.target.files) enviar(e.target.files); e.target.value = ""; }} />
      {erro && <span className="mt-1 text-xs text-bad-ink">{erro}</span>}
    </span>
  );
}

function Baixar({ id }: { id: string }) {
  const [carregando, setCarregando] = useState(false);
  return (
    <button type="button" className="rounded p-1.5 text-subtle hover:bg-sunken hover:text-ink" title="Baixar" aria-label="Baixar"
      onClick={async () => {
        setCarregando(true);
        const url = await linkAnexo(id);
        setCarregando(false);
        if (url) window.location.href = url;
        else alert("Arquivo não encontrado");
      }}>
      {carregando ? <Loader2 size={15} className="animate-spin" /> : <Download size={15} />}
    </button>
  );
}

function Grupo({ g, autores }: { g: GrupoAnexos; autores: Record<string, string> }) {
  const ref = useRef<HTMLInputElement>(null);
  const [sobre, setSobre] = useState(false);
  const { enviar, enviando, erro } = useEnviar(g.destino ?? {});
  return (
    <section
      className={`rounded-md border ${sobre ? "border-primary-2 bg-primary-soft/40" : g.destaque ? "border-primary-2/40" : "border-line"}`}
      onDragOver={(e) => { if (g.destino) { e.preventDefault(); setSobre(true); } }}
      onDragLeave={() => setSobre(false)}
      onDrop={(e) => { if (!g.destino) return; e.preventDefault(); setSobre(false); enviar(e.dataTransfer.files); }}>
      <header className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
        <div className="min-w-0">
          <p className="text-[13px] font-medium text-ink">
            {g.href ? <Link href={g.href} className="hover:text-primary-2">{g.titulo}</Link> : g.titulo}
            <span className="num ml-1.5 text-xs font-normal text-subtle">{g.anexos.length || ""}</span>
          </p>
          {g.sub && <p className="text-[11.5px] text-muted">{g.sub}</p>}
        </div>
        {g.destino && (
          <>
            <button type="button" className="btn-quiet h-7 text-xs" onClick={() => ref.current?.click()} disabled={enviando}>
              {enviando ? <Loader2 size={13} className="animate-spin" /> : <Upload size={13} />} {enviando ? "Enviando…" : "Anexar"}
            </button>
            <input ref={ref} type="file" multiple hidden onChange={(e) => { if (e.target.files) enviar(e.target.files); e.target.value = ""; }} />
          </>
        )}
      </header>
      {erro && <p className="border-t border-line px-3 py-2 text-xs text-bad-ink">{erro}</p>}
      {g.anexos.length > 0 ? (
        <ul className="divide-y divide-line border-t border-line">
          {g.anexos.map((a) => (
            <li key={a.id} className="flex items-center gap-2.5 px-3 py-1.5">
              <FileText size={15} className="shrink-0 text-subtle" />
              <div className="min-w-0 flex-1">
                <p className="truncate text-[13px] text-ink" title={a.nome}>{a.nome}</p>
                <p className="text-[11px] text-subtle">
                  {tamanhoTexto(a.tamanho)}{a.autor && autores[a.autor] ? ` · ${autores[a.autor]}` : ""} · {new Date(a.created_at).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" })}
                </p>
              </div>
              <Baixar id={a.id} />
              <form action={excluirAnexo}>
                <input type="hidden" name="id" value={a.id} />
                <SubmitButton className="rounded p-1.5 text-subtle hover:bg-bad-soft hover:text-bad-ink" pendente="…" confirmar={`Excluir o arquivo "${a.nome}"?`}>
                  <Trash2 size={15} aria-label="Excluir" />
                </SubmitButton>
              </form>
            </li>
          ))}
        </ul>
      ) : g.destino ? (
        <p className="border-t border-dashed border-line px-3 py-2.5 text-xs text-subtle">Nenhum arquivo. Clique em Anexar ou arraste arquivos para cá.</p>
      ) : null}
    </section>
  );
}

export default function Anexos({ grupos, autores }: { grupos: GrupoAnexos[]; autores: Record<string, string> }) {
  return <div className="space-y-2.5">{grupos.map((g) => <Grupo key={g.chave} g={g} autores={autores} />)}</div>;
}
