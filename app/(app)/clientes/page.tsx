import Link from "next/link";
import { ChevronRight, Plus, Search } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import type { Cliente } from "@/lib/types";
import { dataBR } from "@/lib/format";
import PageHeader from "@/components/ui/PageHeader";
import EmptyState from "@/components/ui/EmptyState";
import Modal from "@/components/ui/Modal";
import ClienteForm from "@/components/clientes/ClienteForm";

export const dynamic = "force-dynamic";

export default async function Clientes({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q = "" } = await searchParams;
  const supabase = await createClient();
  const [{ data: cli }, { data: procs }, { data: acessos }] = await Promise.all([
    supabase.from("clientes").select("*").order("nome"),
    supabase.from("processos").select("cliente_id,status,created_at"),
    supabase.from("profiles").select("cliente_id").eq("tipo", "cliente"),
  ]);
  const termo = q.trim().toLowerCase();
  const clientes = ((cli ?? []) as Cliente[]).filter((c) => !termo || [c.nome, c.cnpj, c.contato, c.email].some((v) => v?.toLowerCase().includes(termo)));
  const stats = new Map<string, { ativos: number; total: number; ultimo: string | null }>();
  for (const p of procs ?? []) {
    const s = stats.get(p.cliente_id) ?? { ativos: 0, total: 0, ultimo: null };
    s.total++;
    if (p.status === "ativo") s.ativos++;
    if (!s.ultimo || p.created_at > s.ultimo) s.ultimo = p.created_at;
    stats.set(p.cliente_id, s);
  }
  const comAcesso = new Set((acessos ?? []).map((a) => a.cliente_id));

  return (
    <div>
      <PageHeader titulo="Clientes" subtitulo={`${cli?.length ?? 0} clientes · cada processo pertence a um cliente`}
        acoes={
          <Modal rotulo={<><Plus size={14} /> Novo cliente</>} botaoClasse="btn-primary" titulo="Novo cliente" largura={560}>
            <ClienteForm />
          </Modal>
        } />

      <form className="mb-4 flex max-w-md items-center gap-2">
        <div className="relative flex-1">
          <Search size={14} className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-subtle" />
          <input name="q" defaultValue={q} placeholder="Buscar por nome, CNPJ, contato…" className="input pl-8" />
        </div>
        <button className="btn-ghost">Buscar</button>
      </form>

      <section className="card">
        {clientes.length ? (
          <div className="scroll-x">
            <table className="table-base min-w-[720px]">
              <thead><tr><th>Cliente</th><th>Contato</th><th className="text-right">Ativos</th><th className="text-right">Total</th><th>Último processo</th><th>Portal</th><th /></tr></thead>
              <tbody>
                {clientes.map((c) => {
                  const s = stats.get(c.id);
                  return (
                    <tr key={c.id} className="hover:bg-sunken/60">
                      <td>
                        <Link href={`/clientes/${c.id}`} className="font-medium text-ink hover:text-primary-2">{c.nome}</Link>
                        {c.cnpj && <span className="block text-xs text-subtle">{c.cnpj}</span>}
                      </td>
                      <td className="text-muted">{c.contato ?? "—"}{c.email && <span className="block text-xs text-subtle">{c.email}</span>}</td>
                      <td className="num text-right">{s?.ativos ?? 0}</td>
                      <td className="num text-right text-muted">{s?.total ?? 0}</td>
                      <td className="num text-muted">{s?.ultimo ? dataBR(s.ultimo) : "—"}</td>
                      <td>{comAcesso.has(c.id) ? <span className="chip bg-ok-soft text-ok-ink">Com acesso</span> : <span className="text-xs text-subtle">—</span>}</td>
                      <td className="text-right"><Link href={`/clientes/${c.id}`} className="inline-flex text-subtle hover:text-ink" aria-label={`Abrir ${c.nome}`}><ChevronRight size={16} /></Link></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : <EmptyState titulo={termo ? "Nenhum cliente encontrado" : "Nenhum cliente cadastrado"} texto="Clientes também são criados automaticamente ao abrir um processo com uma empresa nova." />}
      </section>
    </div>
  );
}
