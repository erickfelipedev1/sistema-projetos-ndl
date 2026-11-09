"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Paperclip, X } from "lucide-react";
import { comentarProcesso } from "@/app/actions";
import { enviarArquivosProcesso, LIMITE_MB, tamanhoTexto } from "@/components/anexos/Anexos";

type Pessoa = { id: string; nome: string };

/** campo de comentário com @menção (autocompletar) e anexos de fotos/documentos */
export default function ComentarForm({ processoId, pessoas }: { processoId: string; pessoas: Pessoa[] }) {
  const router = useRouter();
  const areaRef = useRef<HTMLTextAreaElement>(null);
  const arquivoRef = useRef<HTMLInputElement>(null);
  const [texto, setTexto] = useState("");
  const [mencionados, setMencionados] = useState<Pessoa[]>([]);
  const [arquivos, setArquivos] = useState<File[]>([]);
  const [busca, setBusca] = useState<{ inicio: number; termo: string } | null>(null);
  const [ativo, setAtivo] = useState(0);
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  const sugestoes = busca
    ? pessoas.filter((p) => p.nome.toLowerCase().includes(busca.termo.toLowerCase())).slice(0, 6)
    : [];

  function detectar(valor: string, cursor: number) {
    const antes = valor.slice(0, cursor);
    const m = /(^|\s)@([^\s@]{0,30})$/.exec(antes);
    if (m) { setBusca({ inicio: cursor - m[2].length - 1, termo: m[2] }); setAtivo(0); }
    else setBusca(null);
  }

  function escolher(p: Pessoa) {
    if (!busca) return;
    const cursor = areaRef.current?.selectionStart ?? texto.length;
    const novo = `${texto.slice(0, busca.inicio)}@${p.nome} ${texto.slice(cursor)}`;
    setTexto(novo);
    setMencionados((m) => (m.some((x) => x.id === p.id) ? m : [...m, p]));
    setBusca(null);
    requestAnimationFrame(() => {
      const pos = busca.inicio + p.nome.length + 2;
      areaRef.current?.focus();
      areaRef.current?.setSelectionRange(pos, pos);
    });
  }

  async function enviar() {
    if (enviando) return;
    const corpo = texto.trim() || (arquivos.length ? "Anexo" : "");
    if (!corpo) return setErro("Escreva um comentário ou anexe um arquivo");
    const grandes = arquivos.filter((f) => f.size > LIMITE_MB * 1024 * 1024);
    if (grandes.length) return setErro(`Arquivo acima de ${LIMITE_MB} MB: ${grandes.map((g) => g.name).join(", ")}`);
    setErro(null);
    setEnviando(true);
    // só notifica quem continua citado no texto
    const ids = mencionados.filter((p) => corpo.includes(`@${p.nome}`)).map((p) => p.id);
    const r = await comentarProcesso(processoId, corpo, ids);
    if (!r.ok) { setEnviando(false); return setErro(r.erro); }
    const falhas = arquivos.length ? await enviarArquivosProcesso(processoId, arquivos, r.id) : [];
    setTexto(""); setMencionados([]); setArquivos([]); setEnviando(false);
    if (falhas.length) setErro(`Comentário enviado, mas não foi possível anexar: ${falhas.join(", ")}.`);
    router.refresh();
  }

  return (
    <div className="space-y-2">
      <div className="relative">
        <textarea ref={areaRef} rows={2} className="textarea" value={texto} disabled={enviando}
          placeholder="Escreva um comentário para a equipe… use @ para mencionar alguém"
          onChange={(e) => { setTexto(e.target.value); detectar(e.target.value, e.target.selectionStart); }}
          onKeyUp={(e) => { if (!["ArrowUp", "ArrowDown", "Enter", "Tab", "Escape"].includes(e.key)) detectar(e.currentTarget.value, e.currentTarget.selectionStart); }}
          onKeyDown={(e) => {
            if (sugestoes.length) {
              if (e.key === "ArrowDown") { e.preventDefault(); setAtivo((a) => (a + 1) % sugestoes.length); return; }
              if (e.key === "ArrowUp") { e.preventDefault(); setAtivo((a) => (a - 1 + sugestoes.length) % sugestoes.length); return; }
              if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); escolher(sugestoes[ativo]); return; }
              if (e.key === "Escape") { setBusca(null); return; }
            }
            if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); enviar(); }
          }} />
        {sugestoes.length > 0 && (
          <ul role="listbox" className="absolute z-20 mt-1 w-64 overflow-hidden rounded-md border border-line bg-surface py-1 shadow-[var(--shadow-pop)]">
            {sugestoes.map((p, i) => (
              <li key={p.id} role="option" aria-selected={i === ativo}>
                <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => escolher(p)}
                  className={`flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px] ${i === ativo ? "bg-primary-soft text-primary" : "hover:bg-sunken"}`}>
                  <span className="text-subtle">@</span>{p.nome}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      {arquivos.length > 0 && (
        <ul className="space-y-1">
          {arquivos.map((f, i) => (
            <li key={`${f.name}-${i}`} className="flex items-center gap-2 rounded bg-sunken px-2.5 py-1.5 text-[12.5px]">
              <Paperclip size={12} className="shrink-0 text-subtle" />
              <span className="min-w-0 flex-1 truncate text-ink">{f.name}</span>
              <span className="num shrink-0 text-[11px] text-muted">{tamanhoTexto(f.size)}</span>
              <button type="button" className="text-subtle hover:text-bad-ink" aria-label={`Remover ${f.name}`} disabled={enviando}
                onClick={() => setArquivos((a) => a.filter((_, j) => j !== i))}><X size={13} /></button>
            </li>
          ))}
        </ul>
      )}

      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <input ref={arquivoRef} type="file" multiple className="hidden" accept="image/*,.pdf,.doc,.docx,.xls,.xlsx,.csv,.ppt,.pptx,.txt,.zip"
            onChange={(e) => { setArquivos((a) => [...a, ...Array.from(e.target.files ?? [])]); if (arquivoRef.current) arquivoRef.current.value = ""; }} />
          <button type="button" className="btn-ghost h-8 text-xs" disabled={enviando} onClick={() => arquivoRef.current?.click()}><Paperclip size={14} /> Anexar foto ou arquivo</button>
          <span className="hidden text-[11px] text-muted sm:inline">Ctrl+Enter envia · quem for mencionado recebe aviso no chat</span>
        </div>
        <button type="button" className="btn-primary" onClick={enviar} disabled={enviando}>{enviando ? (arquivos.length ? "Enviando…" : "Comentando…") : "Comentar"}</button>
      </div>
      {erro && <p className="text-[13px] text-bad-ink">{erro}</p>}
    </div>
  );
}
