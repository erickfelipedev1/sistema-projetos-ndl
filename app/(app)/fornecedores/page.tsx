import { ExternalLink, Plus, Search, Star, Trash2 } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import type { Fornecedor } from "@/lib/types";
import PageHeader from "@/components/ui/PageHeader";
import EmptyState from "@/components/ui/EmptyState";
import Modal from "@/components/ui/Modal";
import SubmitButton from "@/components/ui/SubmitButton";
import FornecedorForm from "@/components/fornecedores/FornecedorForm";
import { excluirFornecedor } from "@/app/actions";

export const dynamic = "force-dynamic";

function Avaliacao({ n }: { n: number | null }) {
  if (!n) return <span className="text-xs text-subtle">—</span>;
  return (
    <span className="inline-flex items-center gap-0.5" title={`${n}/5`}>
      {Array.from({ length: 5 }, (_, i) => (
        <Star key={i} size={12} className={i < n ? "fill-warn text-warn" : "text-line"} />
      ))}
    </span>
  );
}

export default async function Fornecedores({ searchParams }: { searchParams: Promise<{ q?: string; origem?: string }> }) {
  const { q = "", origem = "" } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from("fornecedores").select("*").order("nome");
  const fornecedores = (data ?? []) as Fornecedor[];

  const origens = Array.from(new Set(fornecedores.map((f) => f.origem).filter(Boolean))).sort() as string[];
  const termo = q.trim().toLowerCase();
  const filtrados = fornecedores.filter((f) => {
    if (origem && f.origem !== origem) return false;
    if (!termo) return true;
    return [f.nome, f.produto, f.contato, f.email, f.origem].some((v) => v?.toLowerCase().includes(termo));
  });

  return (
    <div>
      <PageHeader titulo="Fornecedores" subtitulo={`${fornecedores.length} fornecedores cadastrados`}
        acoes={
          <Modal rotulo={<><Plus size={14} /> Novo fornecedor</>} botaoClasse="btn-primary" titulo="Novo fornecedor" largura={640}>
            <FornecedorForm />
          </Modal>
        } />

      <form className="mb-4 flex flex-wrap items-center gap-2">
        <div className="relative max-w-md flex-1">
          <Search size={14} className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-subtle" />
          <input name="q" defaultValue={q} placeholder="Buscar por nome, produto, contato…" className="input pl-8" />
        </div>
        <select name="origem" defaultValue={origem} className="input w-auto">
          <option value="">Todas as origens</option>
          {origens.map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
        <button className="btn-ghost">Buscar</button>
      </form>

      <section className="card">
        {filtrados.length ? (
          <div className="scroll-x">
            <table className="table-base w-full table-fixed min-w-[960px]">
              <colgroup>
                <col className="w-[30%]" /><col className="w-[20%]" /><col className="w-[22%]" /><col className="w-[16%]" /><col className="w-[12%]" />
              </colgroup>
              <thead><tr><th>Fornecedor</th><th>Produto</th><th>Contato</th><th>Origem</th><th>Avaliação</th></tr></thead>
              <tbody>
                {filtrados.map((f) => (
                  <tr key={f.id} className="hover:bg-sunken/60 align-top">
                    <td className="overflow-hidden">
                      <Modal rotulo={<span className="line-clamp-2 font-medium text-ink hover:text-primary-2 cursor-pointer">{f.nome}</span>} botaoClasse="text-left" titulo={f.nome} largura={640}>
                        <FornecedorForm fornecedor={f} />
                        <form action={excluirFornecedor} className="mt-3 border-t border-line pt-3">
                          <input type="hidden" name="id" value={f.id} />
                          <SubmitButton className="btn-quiet text-bad-ink" pendente="Excluindo…" confirmar={`Excluir o fornecedor ${f.nome}?`}><Trash2 size={13} /> Excluir fornecedor</SubmitButton>
                        </form>
                      </Modal>
                      {f.site && (
                        <a href={f.site.startsWith("http") ? f.site : `https://${f.site.split(" / ")[0]}`} target="_blank" rel="noreferrer"
                          className="mt-0.5 flex items-start gap-1 text-xs text-subtle hover:text-primary-2">
                          <ExternalLink size={11} className="mt-0.5 shrink-0" />
                          <span className="line-clamp-1 overflow-hidden break-all">{f.site}</span>
                        </a>
                      )}
                    </td>
                    <td className="overflow-hidden text-muted"><span className="line-clamp-2 break-words">{f.produto ?? "—"}</span></td>
                    <td className="overflow-hidden text-muted">
                      <span className="line-clamp-1 break-words">{f.contato ?? "—"}</span>
                      {f.telefone && <span className="block truncate text-xs text-subtle">{f.telefone}</span>}
                      {f.email && <span className="block truncate text-xs text-subtle">{f.email}</span>}
                    </td>
                    <td className="overflow-hidden"><span className="chip max-w-full truncate">{f.origem ?? "—"}</span></td>
                    <td><Avaliacao n={f.avaliacao} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <EmptyState titulo={termo || origem ? "Nenhum fornecedor encontrado" : "Nenhum fornecedor cadastrado"} texto="Cadastre os fornecedores que a equipe de sourcing já negociou ou conheceu em feiras." />}
      </section>
    </div>
  );
}
