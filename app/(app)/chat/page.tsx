import Link from "next/link";
import { redirect } from "next/navigation";
import { ClipboardList, Hash } from "lucide-react";
import { base } from "@/lib/dados";
import type { Conversa, Mensagem } from "@/lib/types";
import { relativo } from "@/lib/status";
import Avatar from "@/components/ui/Avatar";
import ChatConversa from "@/components/chat/ChatConversa";
import Demandas from "@/components/chat/Demandas";

export const dynamic = "force-dynamic";

export default async function Chat({ searchParams }: { searchParams: Promise<{ c?: string; com?: string; v?: string }> }) {
  const sp = await searchParams;
  const { supabase, user, perfis } = await base();

  if (sp.com && sp.com !== user.id) {
    const { data: id, error } = await supabase.rpc("conversa_direta", { p_outro: sp.com });
    if (!error && id) redirect(`/chat?c=${id}`);
  }

  const [{ data: convData }, { data: procData }] = await Promise.all([
    supabase.rpc("chat_conversas"),
    supabase.from("processos").select("id,codigo,cliente").eq("status", "ativo").order("created_at", { ascending: false }),
  ]);
  const conversas = (convData ?? []) as Conversa[];
  const processos = (procData ?? []) as { id: string; codigo: string; cliente: string }[];
  const nome = (id: string | null) => perfis.find((p) => p.id === id)?.nome ?? "—";
  const pessoas = perfis.map((p) => ({ id: p.id, nome: p.nome ?? p.email ?? "", cargo: p.cargo ?? null }));
  const canais = conversas.filter((c) => c.tipo === "canal");
  const diretas = conversas.filter((c) => c.tipo === "direta").sort((a, b) => (b.ultima_em ?? "").localeCompare(a.ultima_em ?? ""));
  const comDireta = new Set(diretas.map((d) => d.outro_id));
  const verDemandas = sp.v === "demandas";
  const atual = verDemandas ? null : conversas.find((c) => c.id === sp.c) ?? canais[0] ?? null;

  let mensagens: Mensagem[] = [];
  if (atual) {
    const { data } = await supabase.from("mensagens").select("*").eq("conversa_id", atual.id).order("id", { ascending: false }).limit(150);
    mensagens = ((data ?? []) as Mensagem[]).reverse();
  }
  const { data: demData } = verDemandas
    ? await supabase.from("mensagens").select("*").not("demanda_status", "is", null).or(`demanda_para.eq.${user.id},autor.eq.${user.id}`).order("created_at", { ascending: false }).limit(200)
    : { data: [] };
  const { count: minhasAbertas } = await supabase.from("mensagens").select("id", { count: "exact", head: true }).eq("demanda_para", user.id).eq("demanda_status", "aberta");

  const Linha = ({ c }: { c: Conversa }) => {
    const ativo = atual?.id === c.id;
    const titulo = c.tipo === "canal" ? c.nome ?? "Canal" : nome(c.outro_id);
    return (
      <Link href={`/chat?c=${c.id}`} aria-current={ativo ? "page" : undefined}
        className={`flex items-center gap-2.5 rounded-md px-2.5 py-2 ${ativo ? "bg-primary-soft" : "hover:bg-sunken"}`}>
        {c.tipo === "canal" ? <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-sunken text-muted"><Hash size={14} /></span> : <Avatar nome={titulo} tamanho={28} />}
        <span className="min-w-0 flex-1">
          <span className="flex items-baseline justify-between gap-2">
            <span className={`truncate text-[13px] ${c.nao_lidas ? "font-semibold text-ink" : ativo ? "font-medium text-primary" : "text-ink"}`}>{titulo}</span>
            {c.ultima_em && <span className="shrink-0 text-[10.5px] text-subtle">{relativo(c.ultima_em)}</span>}
          </span>
          <span className="flex items-center justify-between gap-2">
            <span className="truncate text-xs text-muted">{c.ultima_texto ?? "Sem mensagens"}</span>
            {c.nao_lidas > 0 && <span className="num shrink-0 rounded-full bg-primary-2 px-1.5 text-[10.5px] font-semibold text-white">{c.nao_lidas}</span>}
          </span>
        </span>
      </Link>
    );
  };

  return (
    <div className="-mx-5 -my-5 flex h-[calc(100vh-56px)] xl:-mx-7">
      <aside className="flex w-[280px] shrink-0 flex-col border-r border-line bg-surface max-md:hidden">
        <div className="border-b border-line px-4 py-3">
          <h1 className="text-[15px] font-semibold text-ink">Chat e demandas</h1>
          <p className="text-xs text-muted">Converse e peça demandas para a equipe</p>
        </div>
        <nav className="flex-1 space-y-4 overflow-y-auto p-2.5">
          <Link href="/chat?v=demandas" aria-current={verDemandas ? "page" : undefined}
            className={`flex items-center gap-2.5 rounded-md px-2.5 py-2 text-[13px] ${verDemandas ? "bg-primary-soft font-medium text-primary" : "text-ink hover:bg-sunken"}`}>
            <span className="flex h-7 w-7 items-center justify-center rounded-full bg-warn-soft text-warn-ink"><ClipboardList size={14} /></span>
            <span className="flex-1">Demandas</span>
            {!!minhasAbertas && <span className="num rounded bg-warn px-1.5 text-[11px] font-semibold text-white" title="Abertas para você">{minhasAbertas}</span>}
          </Link>
          <div>
            <p className="eyebrow px-2.5 pb-1">Canais</p>
            {canais.map((c) => <Linha key={c.id} c={c} />)}
          </div>
          <div>
            <p className="eyebrow px-2.5 pb-1">Conversas diretas</p>
            {diretas.map((c) => <Linha key={c.id} c={c} />)}
            {pessoas.filter((p) => p.id !== user.id && !comDireta.has(p.id)).map((p) => (
              <Link key={p.id} href={`/chat?com=${p.id}`} className="flex items-center gap-2.5 rounded-md px-2.5 py-1.5 text-[13px] text-muted hover:bg-sunken hover:text-ink">
                <Avatar nome={p.nome} tamanho={24} /><span className="flex-1 truncate">{p.nome}</span><span className="text-[11px] text-subtle">{p.cargo}</span>
              </Link>
            ))}
          </div>
        </nav>
      </aside>

      <section className="flex min-w-0 flex-1 flex-col bg-canvas">
        {/* seletor para telas pequenas */}
        <div className="flex gap-1.5 overflow-x-auto border-b border-line bg-surface px-3 py-2 md:hidden">
          <Link href="/chat?v=demandas" className={`chip shrink-0 border ${verDemandas ? "border-primary bg-primary-soft text-primary" : "border-line"}`}>Demandas</Link>
          {[...canais, ...diretas].map((c) => (
            <Link key={c.id} href={`/chat?c=${c.id}`} className={`chip shrink-0 border ${atual?.id === c.id ? "border-primary bg-primary-soft text-primary" : "border-line"}`}>
              {c.tipo === "canal" ? `# ${c.nome}` : nome(c.outro_id)}{c.nao_lidas ? ` (${c.nao_lidas})` : ""}
            </Link>
          ))}
        </div>
        {verDemandas ? (
          <Demandas meuId={user.id} demandas={(demData ?? []) as Mensagem[]} nomes={Object.fromEntries(pessoas.map((p) => [p.id, p.nome]))}
            processos={Object.fromEntries(processos.map((p) => [p.id, `${p.codigo} · ${p.cliente}`]))} />
        ) : atual ? (
          <ChatConversa key={atual.id}
            conversa={{ id: atual.id, tipo: atual.tipo, titulo: atual.tipo === "canal" ? `# ${atual.nome}` : nome(atual.outro_id), outroId: atual.outro_id }}
            meuId={user.id} iniciais={mensagens} pessoas={pessoas} processos={processos} />
        ) : (
          <p className="m-auto text-[13px] text-muted">Rode o SQL 008 para ativar o chat.</p>
        )}
      </section>
    </div>
  );
}
