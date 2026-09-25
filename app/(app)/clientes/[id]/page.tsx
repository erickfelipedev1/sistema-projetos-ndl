import Link from "next/link";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { ChevronRight, Eye, Plus } from "lucide-react";
import { base } from "@/lib/dados";
import type { Anexo, Cliente, EtapaAtual, Processo } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { nomeCurto } from "@/lib/status";
import EmptyState from "@/components/ui/EmptyState";
import StatusBadge from "@/components/ui/StatusBadge";
import { PlanoTag } from "@/components/processos/ProcessCard";
import ClienteForm from "@/components/clientes/ClienteForm";
import PortalAcesso from "@/components/clientes/PortalAcesso";
import Anexos, { type GrupoAnexos } from "@/components/anexos/Anexos";
import SubmitButton from "@/components/ui/SubmitButton";
import { excluirCliente } from "@/app/actions";

export const dynamic = "force-dynamic";

export default async function ClienteDetalhe({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, perfis } = await base();
  const [{ data: cli }, { data: procData }, { data: atuaisData }, { data: acessos }, { data: anexosData }] = await Promise.all([
    supabase.from("clientes").select("*").eq("id", id).maybeSingle(),
    supabase.from("processos").select("*").eq("cliente_id", id).order("created_at", { ascending: false }),
    supabase.from("v_etapas_atuais").select("processo_id,ordem,nome,prazo_em,atrasada,dias_restantes"),
    supabase.from("profiles").select("id,nome,usuario,trocar_senha").eq("tipo", "cliente").eq("cliente_id", id).order("nome"),
    supabase.from("anexos").select("*").eq("cliente_id", id).order("created_at", { ascending: false }),
  ]);
  if (!cli) notFound();
  const c = cli as Cliente;
  const processos = (procData ?? []) as Processo[];
  const atuais = new Map(((atuaisData ?? []) as EtapaAtual[]).map((a) => [a.processo_id, a]));
  const anexos = (anexosData ?? []) as Anexo[];
  const autores = Object.fromEntries(perfis.map((p) => [p.id, p.nome ?? ""]));
  const h = await headers();
  const site = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("x-forwarded-host") ?? h.get("host")}`;

  const grupos: GrupoAnexos[] = [
    { chave: "cliente", titulo: "Arquivos do cliente", sub: "Documentos da empresa, sem processo específico (contrato social, cadastro, procurações…)",
      anexos: anexos.filter((a) => !a.processo_id), destino: { cliente_id: c.id }, destaque: true },
    ...processos.map((p) => ({
      chave: p.id, titulo: `${p.codigo}${p.descricao ? ` · ${p.descricao}` : ""}`, href: `/processos/${p.id}?tab=anexos`,
      sub: "Arquivos do processo (todas as etapas)", anexos: anexos.filter((a) => a.processo_id === p.id),
    })).filter((g) => g.anexos.length),
  ];
  const ativos = processos.filter((p) => p.status === "ativo").length;

  return (
    <div className="space-y-4">
      <div>
        <nav className="mb-2 flex items-center gap-1 text-xs text-muted" aria-label="Trilha">
          <Link href="/clientes" className="hover:text-ink">Clientes</Link><ChevronRight size={12} /><span className="text-ink">{c.nome}</span>
        </nav>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-xl font-semibold tracking-tight">{c.nome}</h1>
            <p className="mt-0.5 text-[13px] text-muted">{[c.cnpj, c.contato, c.email, c.telefone].filter(Boolean).join(" · ") || "Sem dados de contato"}</p>
          </div>
          <div className="flex flex-wrap gap-2">
            <Link href={`/clientes/${c.id}/portal`} className="btn-ghost"><Eye size={14} /> Ver como o cliente</Link>
            <Link href={`/processos/novo?cliente=${c.id}`} className="btn-primary"><Plus size={14} /> Novo processo</Link>
          </div>
        </div>
      </div>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
        <div className="min-w-0 space-y-4">
          <section className="card">
            <div className="card-header"><h2 className="card-title">Processos</h2><span className="text-xs text-muted">{ativos} ativo{ativos === 1 ? "" : "s"} · {processos.length} no total</span></div>
            {processos.length ? (
              <div className="scroll-x">
                <table className="table-base min-w-[640px]">
                  <thead><tr><th>Processo</th><th>Plano</th><th>Etapa atual</th><th>Status</th><th>Aberto em</th></tr></thead>
                  <tbody>
                    {processos.map((p) => {
                      const a = atuais.get(p.id);
                      const st = p.status === "concluido" ? { tipo: "concluido" as const, texto: "Concluído" }
                        : p.status === "cancelado" ? { tipo: "cancelado" as const, texto: "Cancelado" }
                        : p.status === "pausado" ? { tipo: "sem_prazo" as const, texto: "Pausado" }
                        : a?.atrasada ? { tipo: "atrasado" as const, texto: "Em atraso" } : { tipo: "em_dia" as const, texto: "Em andamento" };
                      return (
                        <tr key={p.id} className="hover:bg-sunken/60">
                          <td><Link href={`/processos/${p.id}`} className="font-medium text-ink hover:text-primary-2">{p.codigo}</Link>{p.descricao && <span className="block max-w-[260px] truncate text-xs text-subtle">{p.descricao}</span>}</td>
                          <td><PlanoTag plano={p.plano} /></td>
                          <td className="text-muted">{a ? `${a.ordem}. ${nomeCurto(a.nome)}` : "—"}</td>
                          <td><StatusBadge tipo={st.tipo} texto={st.texto} /></td>
                          <td className="num text-muted">{dataBR(p.created_at)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            ) : <EmptyState compacto titulo="Nenhum processo deste cliente" acao={<Link href={`/processos/novo?cliente=${c.id}`} className="btn-primary"><Plus size={14} /> Abrir processo</Link>} />}
          </section>

          <section className="card">
            <div className="card-header"><h2 className="card-title">Arquivos</h2><span className="text-xs text-muted">{anexos.length} arquivo{anexos.length === 1 ? "" : "s"}</span></div>
            <div className="p-4"><Anexos grupos={grupos} autores={autores} /></div>
          </section>
        </div>

        <aside className="space-y-4">
          <section className="card">
            <div className="card-header"><div><h2 className="card-title">Acesso ao portal</h2><p className="text-xs text-muted">O cliente vê só as etapas e datas dos processos dele.</p></div></div>
            <div className="p-4"><PortalAcesso clienteId={c.id} contato={c.contato} usuarios={(acessos ?? []) as { id: string; nome: string | null; usuario: string | null; trocar_senha: boolean }[]} site={site} /></div>
          </section>
          <section className="card">
            <div className="card-header"><h2 className="card-title">Dados do cliente</h2></div>
            <div className="p-4"><ClienteForm cliente={c} /></div>
            {processos.length === 0 && (
              <form action={excluirCliente} className="border-t border-line px-4 py-3">
                <input type="hidden" name="id" value={c.id} />
                <SubmitButton className="btn-quiet text-bad-ink" pendente="Excluindo…" confirmar={`Excluir o cliente ${c.nome}?`}>Excluir cliente</SubmitButton>
              </form>
            )}
          </section>
        </aside>
      </div>
    </div>
  );
}
