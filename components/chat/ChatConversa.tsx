"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { ClipboardList, Send, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import type { Mensagem } from "@/lib/types";
import Avatar from "@/components/ui/Avatar";
import DemandaCard from "./DemandaCard";

type Pessoa = { id: string; nome: string; cargo: string | null };
type Proc = { id: string; codigo: string; cliente: string };

const hora = (ts: string) => new Date(ts).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit", timeZone: "America/Sao_Paulo" });
const dia = (ts: string) => new Date(ts).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
function rotuloDia(d: string) {
  const hoje = dia(new Date().toISOString());
  const ontem = dia(new Date(Date.now() - 86400000).toISOString());
  if (d === hoje) return "Hoje";
  if (d === ontem) return "Ontem";
  const [y, m, dd] = d.split("-");
  return `${dd}/${m}/${y}`;
}

export default function ChatConversa({ conversa, meuId, iniciais, pessoas, processos }: {
  conversa: { id: string; tipo: "canal" | "direta"; titulo: string; outroId: string | null };
  meuId: string; iniciais: Mensagem[]; pessoas: Pessoa[]; processos: Proc[];
}) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const [msgs, setMsgs] = useState<Mensagem[]>(iniciais);
  const [texto, setTexto] = useState("");
  const [demanda, setDemanda] = useState(false);
  const [para, setPara] = useState(conversa.outroId ?? "");
  const [processo, setProcesso] = useState("");
  const [prazo, setPrazo] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const fim = useRef<HTMLDivElement>(null);
  const nomes = useMemo(() => Object.fromEntries(pessoas.map((p) => [p.id, p.nome])), [pessoas]);
  const procNome = useMemo(() => Object.fromEntries(processos.map((p) => [p.id, `${p.codigo} · ${p.cliente}`])), [processos]);

  const juntar = useCallback((novas: Mensagem[]) => {
    setMsgs((atuais) => {
      const mapa = new Map(atuais.map((m) => [m.id, m]));
      for (const n of novas) mapa.set(n.id, n);
      return [...mapa.values()].sort((a, b) => a.id - b.id);
    });
  }, []);

  const marcarLido = useCallback(async () => {
    await supabase.from("conversa_leituras").upsert({ conversa_id: conversa.id, user_id: meuId, lido_em: new Date().toISOString() });
  }, [supabase, conversa.id, meuId]);

  // ao abrir: marca como lida e atualiza os contadores da barra lateral
  useEffect(() => {
    marcarLido().then(() => router.refresh());
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversa.id]);

  // tempo real (Supabase Realtime) + busca periódica como reserva
  useEffect(() => {
    let tempoReal = false;
    const canal = supabase
      .channel(`chat-${conversa.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "mensagens", filter: `conversa_id=eq.${conversa.id}` },
        (payload) => { if (payload.new && "id" in payload.new) { juntar([payload.new as Mensagem]); marcarLido(); } })
      .subscribe((status) => { tempoReal = status === "SUBSCRIBED"; });
    const buscar = async () => {
      if (tempoReal || document.hidden) return;
      const { data } = await supabase.from("mensagens").select("*").eq("conversa_id", conversa.id).order("id", { ascending: false }).limit(60);
      if (data?.length) { juntar(data as Mensagem[]); marcarLido(); }
    };
    const t = setInterval(buscar, 6000);
    return () => { clearInterval(t); supabase.removeChannel(canal); };
  }, [supabase, conversa.id, juntar, marcarLido]);

  useEffect(() => { fim.current?.scrollIntoView({ block: "end" }); }, [msgs.length]);

  async function enviar(e?: React.FormEvent) {
    e?.preventDefault();
    const t = texto.trim();
    if (!t || enviando) return;
    if (demanda && !para) return setErro("Escolha para quem é a demanda");
    setEnviando(true); setErro(null);
    const { data, error } = await supabase.from("mensagens").insert({
      conversa_id: conversa.id, autor: meuId, texto: t,
      processo_id: processo || null,
      ...(demanda ? { demanda_para: para, demanda_prazo: prazo || null, demanda_status: "aberta" } : {}),
    }).select("*").single();
    setEnviando(false);
    if (error) return setErro(error.message);
    juntar([data as Mensagem]);
    setTexto(""); setProcesso(""); setPrazo(""); setDemanda(false);
    if (demanda) router.refresh();
  }

  async function mudarStatus(m: Mensagem, status: "aberta" | "concluida") {
    const { data, error } = await supabase.from("mensagens")
      .update({ demanda_status: status, demanda_concluida_em: status === "concluida" ? new Date().toISOString() : null })
      .eq("id", m.id).select("*").single();
    if (error) return setErro(error.message);
    juntar([data as Mensagem]);
    router.refresh();
  }

  const destinatarios = pessoas.filter((p) => p.id !== meuId && (conversa.tipo === "canal" || p.id === conversa.outroId));

  return (
    <>
      <header className="flex h-12 shrink-0 items-center gap-2.5 border-b border-line bg-surface px-4">
        {conversa.tipo === "direta" && <Avatar nome={conversa.titulo} tamanho={26} />}
        <h2 className="text-[14px] font-semibold text-ink">{conversa.titulo}</h2>
        <span className="text-xs text-muted">{conversa.tipo === "canal" ? "toda a equipe" : "conversa direta"}</span>
      </header>

      <div className="flex-1 overflow-y-auto px-4 py-3" aria-live="polite">
        {msgs.length === 0 && <p className="mt-10 text-center text-[13px] text-muted">Nenhuma mensagem ainda. Comece a conversa.</p>}
        {msgs.map((m, i) => {
          const ant = msgs[i - 1];
          const novoDia = !ant || dia(ant.created_at) !== dia(m.created_at);
          const agrupa = !novoDia && ant && ant.autor === m.autor && !m.demanda_status && !ant.demanda_status
            && new Date(m.created_at).getTime() - new Date(ant.created_at).getTime() < 5 * 60000;
          const eu = m.autor === meuId;
          return (
            <div key={m.id}>
              {novoDia && (
                <div className="my-3 flex items-center gap-3 text-[11px] text-subtle"><span className="h-px flex-1 bg-line" />{rotuloDia(dia(m.created_at))}<span className="h-px flex-1 bg-line" /></div>
              )}
              <div className={`flex gap-2.5 ${agrupa ? "mt-0.5" : "mt-3"}`}>
                <div className="w-8 shrink-0">{!agrupa && <Avatar nome={nomes[m.autor] ?? "?"} tamanho={30} />}</div>
                <div className="min-w-0 flex-1">
                  {!agrupa && (
                    <p className="text-[12.5px]"><span className="font-semibold text-ink">{eu ? "Você" : nomes[m.autor] ?? "—"}</span> <span className="text-[11px] text-subtle">{hora(m.created_at)}</span></p>
                  )}
                  <p className="text-[13.5px] break-words whitespace-pre-wrap text-ink">{m.texto}</p>
                  {m.demanda_status ? (
                    <DemandaCard m={m} meuId={meuId} nomes={nomes} processo={m.processo_id ? procNome[m.processo_id] : null} onStatus={mudarStatus} />
                  ) : m.processo_id ? (
                    <a href={`/processos/${m.processo_id}`} className="mt-0.5 inline-block text-xs text-primary-2 hover:underline">{procNome[m.processo_id] ?? "ver processo"}</a>
                  ) : null}
                </div>
              </div>
            </div>
          );
        })}
        <div ref={fim} />
      </div>

      <form onSubmit={enviar} className="shrink-0 border-t border-line bg-surface px-4 py-3">
        {demanda && (
          <div className="mb-2 grid gap-2 rounded-md border border-warn/40 bg-warn-soft/50 p-2.5 sm:grid-cols-[1fr_1fr_150px_auto]">
            <div>
              <label className="label" htmlFor="d-para">Para quem</label>
              <select id="d-para" className="input h-8" value={para} onChange={(e) => setPara(e.target.value)} required>
                <option value="">Escolha…</option>
                {destinatarios.map((p) => <option key={p.id} value={p.id}>{p.nome}{p.cargo ? ` (${p.cargo})` : ""}</option>)}
              </select>
            </div>
            <div>
              <label className="label" htmlFor="d-proc">Processo (opcional)</label>
              <select id="d-proc" className="input h-8" value={processo} onChange={(e) => setProcesso(e.target.value)}>
                <option value="">Nenhum</option>
                {processos.map((p) => <option key={p.id} value={p.id}>{p.codigo} · {p.cliente}</option>)}
              </select>
            </div>
            <div>
              <label className="label" htmlFor="d-prazo">Prazo (opcional)</label>
              <input id="d-prazo" type="date" className="input h-8" value={prazo} onChange={(e) => setPrazo(e.target.value)} />
            </div>
            <button type="button" onClick={() => setDemanda(false)} className="self-start rounded p-1 text-subtle hover:text-ink" aria-label="Cancelar demanda"><X size={15} /></button>
          </div>
        )}
        {erro && <p className="mb-1.5 text-xs text-bad-ink">{erro}</p>}
        <div className="flex items-end gap-2">
          {!demanda && (
            <button type="button" onClick={() => setDemanda(true)} className="btn-ghost h-9 shrink-0" title="Transformar a mensagem em uma demanda para alguém">
              <ClipboardList size={15} /> <span className="max-sm:hidden">Demanda</span>
            </button>
          )}
          <textarea value={texto} onChange={(e) => setTexto(e.target.value)} rows={1} aria-label="Mensagem"
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); enviar(); } }}
            placeholder={demanda ? "Descreva a demanda…" : `Mensagem para ${conversa.titulo}`}
            className="textarea max-h-40 min-h-9 flex-1 resize-none py-2" />
          <button type="submit" className="btn-primary h-9 shrink-0" disabled={enviando || !texto.trim()}>
            <Send size={14} /> <span className="max-sm:hidden">{demanda ? "Enviar demanda" : "Enviar"}</span>
          </button>
        </div>
        <p className="mt-1 text-[11px] text-subtle">Enter envia · Shift+Enter quebra linha</p>
      </form>
    </>
  );
}
