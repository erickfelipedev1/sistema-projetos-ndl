"use client";

import { useOptimistic, useState, useTransition } from "react";
import { ChevronRight, GripVertical, Hourglass, Pencil, Plus, Trash2, UserRound } from "lucide-react";
import type { ChecklistItem } from "@/lib/types";
import {
  marcarChecklist, alterarPrazoItemChecklist, alterarResponsavelItemChecklist, adicionarItemChecklist, removerItemChecklist,
  editarItemChecklist, reordenarChecklist,
} from "@/app/actions";
import { limparPasso } from "@/lib/status";

type Acao =
  | { tipo: "feito"; id: string }
  | { tipo: "prazo"; id: string; prazo_em: string | null }
  | { tipo: "responsavel"; id: string; responsavel_id: string | null }
  | { tipo: "remover"; id: string }
  | { tipo: "editar"; id: string; titulo: string; descricao: string | null }
  | { tipo: "reordenar"; ordemIds: string[] };

type Pessoa = { id: string; nome: string };

/** responsaveis: por modelo_id, o rótulo padrão do modelo (ex.: "Isabella / Cris") — usado quando o item não tem responsável escolhido no processo */
export default function Checklist({ itens, nomes, editavel = true, responsaveis = {}, bloqueados = {}, pessoas = [], processoEtapaId }: {
  itens: ChecklistItem[]; nomes: Record<string, string>; editavel?: boolean; responsaveis?: Record<number, string>; bloqueados?: Record<string, string>;
  pessoas?: Pessoa[]; processoEtapaId?: string;
}) {
  const [, start] = useTransition();
  const [novoTitulo, setNovoTitulo] = useState("");
  const [adicionando, setAdicionando] = useState(false);
  const [editandoId, setEditandoId] = useState<string | null>(null);
  const [tituloEdit, setTituloEdit] = useState("");
  const [descEdit, setDescEdit] = useState("");
  const [dragId, setDragId] = useState<string | null>(null);
  const [overId, setOverId] = useState<string | null>(null);
  const [lista, despachar] = useOptimistic(itens, (atual, acao: Acao) => {
    if (acao.tipo === "remover") return atual.filter((i) => i.id !== acao.id);
    if (acao.tipo === "reordenar") {
      const mapa = new Map(atual.map((i) => [i.id, i]));
      return acao.ordemIds.map((id) => mapa.get(id)).filter((i): i is ChecklistItem => !!i);
    }
    return atual.map((i) => {
      if (i.id !== acao.id) return i;
      if (acao.tipo === "feito") return { ...i, feito: !i.feito };
      if (acao.tipo === "prazo") return { ...i, prazo_em: acao.prazo_em };
      if (acao.tipo === "editar") return { ...i, titulo: acao.titulo, descricao: acao.descricao };
      return { ...i, responsavel_id: acao.responsavel_id };
    });
  });
  const feitos = lista.filter((i) => i.feito).length;
  const pct = lista.length ? Math.round((feitos / lista.length) * 100) : 0;
  const hoje = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" }); // yyyy-mm-dd

  async function adicionar() {
    const titulo = novoTitulo.trim();
    if (!titulo || !processoEtapaId) return;
    setNovoTitulo("");
    setAdicionando(true);
    await adicionarItemChecklist(processoEtapaId, titulo);
    setAdicionando(false);
  }

  function abrirEdicao(i: ChecklistItem) {
    setEditandoId(i.id);
    setTituloEdit(limparPasso(i.titulo));
    setDescEdit(i.descricao ?? "");
  }

  function salvarEdicao(id: string) {
    const titulo = tituloEdit.trim();
    if (!titulo) return;
    const descricao = descEdit.trim() || null;
    setEditandoId(null);
    start(async () => { despachar({ tipo: "editar", id, titulo, descricao }); await editarItemChecklist(id, titulo, descricao); });
  }

  function soltar(alvoId: string) {
    setOverId(null);
    if (!dragId || dragId === alvoId) { setDragId(null); return; }
    const ids = lista.map((i) => i.id);
    const de = ids.indexOf(dragId);
    const para = ids.indexOf(alvoId);
    if (de < 0 || para < 0) { setDragId(null); return; }
    const nova = [...ids];
    nova.splice(de, 1);
    nova.splice(para, 0, dragId);
    setDragId(null);
    start(async () => { despachar({ tipo: "reordenar", ordemIds: nova }); await reordenarChecklist(nova); });
  }

  return (
    <div>
      <div className="mb-3 flex items-center gap-3">
        <div className="h-2 flex-1 overflow-hidden rounded-full bg-line">
          <div className={`h-full rounded-full transition-[width] duration-300 ${pct === 100 ? "bg-ok" : "bg-primary-2"}`} style={{ width: `${pct}%` }} />
        </div>
        <span className="num shrink-0 text-xs font-medium text-ink">{pct}% concluído</span>
        <span className="num shrink-0 text-xs text-muted">{feitos}/{lista.length}</span>
      </div>
      <ul className="divide-y divide-line rounded-md border border-line">
        {lista.map((i) => {
          const atrasado = !!(i.prazo_em && !i.feito && i.prazo_em < hoje);
          const editando = editandoId === i.id;
          return (
          <li key={i.id}
            className={`group px-3 py-2 ${i.feito ? "bg-sunken/60" : ""} ${dragId === i.id ? "opacity-40" : ""} ${overId === i.id && dragId && dragId !== i.id ? "border-t-2 border-t-primary-2" : ""}`}
            onDragOver={editavel && dragId ? (e) => { e.preventDefault(); if (overId !== i.id) setOverId(i.id); } : undefined}
            onDrop={editavel && dragId ? (e) => { e.preventDefault(); soltar(i.id); } : undefined}>
            <div className="flex items-start gap-1.5">
              {editavel && (
                <span draggable title="Arrastar para reordenar" className="mt-[3px] shrink-0 cursor-grab text-subtle hover:text-muted active:cursor-grabbing"
                  onDragStart={(e) => { e.dataTransfer.effectAllowed = "move"; setDragId(i.id); }}
                  onDragEnd={() => { setDragId(null); setOverId(null); }}>
                  <GripVertical size={14} />
                </span>
              )}
              <input type="checkbox" className="mt-[3px] h-4 w-4 shrink-0 cursor-pointer" checked={i.feito} disabled={!editavel || !!bloqueados[i.id]}
                aria-label={i.titulo} title={bloqueados[i.id]}
                onChange={() => start(async () => { despachar({ tipo: "feito", id: i.id }); await marcarChecklist(i.id, !i.feito); })} />
              {editando ? (
                <div className="min-w-0 flex-1 space-y-1.5">
                  <input value={tituloEdit} onChange={(e) => setTituloEdit(e.target.value)} className="input h-7 text-[13px]"
                    onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); salvarEdicao(i.id); } if (e.key === "Escape") setEditandoId(null); }} autoFocus />
                  <textarea value={descEdit} onChange={(e) => setDescEdit(e.target.value)} rows={2} placeholder="Descrição (opcional)" className="textarea text-xs" />
                  <div className="flex gap-2">
                    <button type="button" className="btn-ghost h-6 px-2 text-[11px]" onClick={() => salvarEdicao(i.id)}>Salvar</button>
                    <button type="button" className="text-[11px] text-subtle hover:text-ink" onClick={() => setEditandoId(null)}>Cancelar</button>
                  </div>
                </div>
              ) : (
                <details className="min-w-0 flex-1">
                  <summary className="flex cursor-pointer items-start justify-between gap-2">
                    <span className={`text-[13px] leading-5 ${i.feito ? "text-muted line-through decoration-subtle" : "text-ink"}`}>
                      {i.aguarda_cliente && <span className={`mr-1.5 inline-flex items-center gap-1 rounded px-1.5 py-px align-[1px] text-[10.5px] font-medium no-underline ${i.feito ? "bg-ok-soft text-ok-ink" : "bg-primary-soft text-primary"}`}><Hourglass size={11} />{i.feito ? "cliente respondeu" : "espera do cliente"}</span>}
                      {limparPasso(i.titulo)}
                      {!i.responsavel_id && i.modelo_id && responsaveis[i.modelo_id] && (
                        <span className="ml-1.5 inline-flex items-center gap-1 rounded bg-sunken px-1.5 py-px align-[1px] text-[10.5px] font-medium text-muted no-underline">
                          <UserRound size={11} />{responsaveis[i.modelo_id]}{!i.feito && (i.avisado_em ? " · demanda enviada" : " · avisa quando liberar")}
                        </span>
                      )}
                    </span>
                    {i.descricao && <ChevronRight size={14} className="mt-0.5 shrink-0 text-subtle transition-transform group-[&:has(details[open])]:rotate-90" />}
                  </summary>
                  {i.descricao && <p className="mt-1.5 mb-1 whitespace-pre-line text-xs leading-relaxed text-muted">{i.descricao}</p>}
                </details>
              )}
            </div>
            {editavel && !editando && (
              <div className="mt-1.5 flex flex-wrap items-center gap-1.5 pl-[42px]">
                <select value={i.responsavel_id ?? ""} disabled={!editavel}
                  title="Responsável por este item neste processo"
                  className="h-6 rounded border border-line bg-surface px-1 text-[11px] text-muted disabled:opacity-50"
                  onChange={(e) => { const v = e.target.value || null; start(async () => { despachar({ tipo: "responsavel", id: i.id, responsavel_id: v }); await alterarResponsavelItemChecklist(i.id, v); }); }}>
                  <option value="">sem responsável</option>
                  {pessoas.map((p) => <option key={p.id} value={p.id}>{p.nome}</option>)}
                </select>
                {!i.feito && (
                  <input type="date" value={i.prazo_em ?? ""} disabled={!editavel}
                    title="Prazo deste item — clique para adiantar ou atrasar"
                    className={`num h-6 w-[108px] rounded border px-1 text-[11px] ${atrasado ? "border-bad-ink/40 bg-bad-soft text-bad-ink" : "border-line bg-surface text-subtle"} disabled:opacity-50`}
                    onChange={(e) => { const v = e.target.value || null; start(async () => { despachar({ tipo: "prazo", id: i.id, prazo_em: v }); await alterarPrazoItemChecklist(i.id, v); }); }} />
                )}
                <button type="button" title="Editar título e descrição" className="text-subtle hover:text-primary-2" onClick={() => abrirEdicao(i)}>
                  <Pencil size={13} />
                </button>
                <button type="button" title="Remover este item do checklist" className="ml-auto text-subtle hover:text-bad-ink disabled:opacity-30"
                  onClick={() => { if (!window.confirm(`Remover "${limparPasso(i.titulo)}" do checklist deste processo?`)) return; start(async () => { despachar({ tipo: "remover", id: i.id }); await removerItemChecklist(i.id); }); }}>
                  <Trash2 size={13} />
                </button>
              </div>
            )}
          </li>
          );
        })}
      </ul>
      {editavel && processoEtapaId && (
        <div className="mt-2 flex items-center gap-2">
          <input value={novoTitulo} onChange={(e) => setNovoTitulo(e.target.value)} placeholder="Adicionar item ao checklist…"
            className="input h-8 flex-1 text-[13px]" disabled={adicionando}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); adicionar(); } }} />
          <button type="button" className="btn-ghost h-8" disabled={adicionando || !novoTitulo.trim()} onClick={adicionar}>
            <Plus size={14} /> Adicionar
          </button>
        </div>
      )}
    </div>
  );
}
