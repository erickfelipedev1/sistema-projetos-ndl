import { createClient } from "@/lib/supabase/server";
import type { Etapa, Profile } from "@/lib/types";
import { dataBR } from "@/lib/format";
import ConfirmSubmit from "@/components/ConfirmSubmit";
import { aplicarResponsaveisEmAndamento, removerFeriado, salvarEtapa, salvarFeriado, salvarMeuNome } from "@/app/actions";

export const dynamic = "force-dynamic";

function FormEtapa({ e, perfis }: { e?: Etapa; perfis: Profile[] }) {
  return (
    <form action={salvarEtapa} className="grid gap-2 p-4 md:grid-cols-[60px_1fr_1.6fr_110px_90px_1.4fr] md:items-start">
      <input type="hidden" name="id" value={e?.id ?? ""} />
      <div><label className="label">Ordem</label><input name="ordem" type="number" defaultValue={e?.ordem ?? ""} required className="input" /></div>
      <div><label className="label">Área</label><input name="area" defaultValue={e?.area ?? ""} required className="input" /></div>
      <div><label className="label">Etapa</label><input name="nome" defaultValue={e?.nome ?? ""} required className="input" /></div>
      <div>
        <label className="label">Tipo</label>
        <select name="tipo" defaultValue={e?.tipo ?? "tarefa"} className="input">
          <option value="tarefa">Tarefa</option><option value="marco">Marco</option><option value="final">Final</option>
        </select>
      </div>
      <div><label className="label">Prazo (d.u.)</label><input name="prazo_dias_uteis" type="number" min={0} defaultValue={e?.prazo_dias_uteis ?? ""} className="input" /></div>
      <div>
        <label className="label">Responsáveis padrão</label>
        <div className="max-h-24 space-y-0.5 overflow-y-auto rounded-lg border border-slate-200 p-2">
          {perfis.map((p) => (
            <label key={p.id} className="flex items-center gap-2 text-xs">
              <input type="checkbox" name="responsaveis_padrao" value={p.id} defaultChecked={e?.responsaveis_padrao.includes(p.id)} />
              {p.nome ?? p.email}
            </label>
          ))}
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 md:col-span-6">
        <div className="flex items-center gap-2">
          <label className="text-xs text-slate-500">Texto quando sem usuário:</label>
          <input name="responsaveis_label" defaultValue={e?.responsaveis_label ?? ""} className="input w-44 py-1" />
        </div>
        <label className="flex items-center gap-1.5 text-xs"><input type="checkbox" name="prazo_editavel" defaultChecked={e?.prazo_editavel} /> Data definida por processo (ex.: ETA)</label>
        <label className="flex items-center gap-1.5 text-xs"><input type="checkbox" name="ativo" defaultChecked={e ? e.ativo : true} /> Ativa</label>
        <ConfirmSubmit className="btn-ghost py-1">{e ? "Salvar" : "Adicionar etapa"}</ConfirmSubmit>
        {e && (
          <button formAction={aplicarResponsaveisEmAndamento} className="text-xs text-indigo-600 hover:underline">
            Aplicar responsáveis aos processos em andamento
          </button>
        )}
      </div>
    </form>
  );
}

export default async function Configuracoes() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const [{ data: etapas }, { data: perfis }, { data: feriados }] = await Promise.all([
    supabase.from("etapas").select("*").order("ordem"),
    supabase.from("profiles").select("id,nome,email").order("nome"),
    supabase.from("feriados").select("*").order("data"),
  ]);
  const pf = (perfis ?? []) as Profile[];
  const eu = pf.find((p) => p.id === user!.id);

  return (
    <div className="space-y-8">
      <h1 className="text-xl font-semibold">Configurações</h1>

      <section>
        <h2 className="font-medium">Etapas do fluxo</h2>
        <p className="mb-3 text-sm text-slate-500">
          Mudanças valem para processos criados a partir de agora. Vincule os usuários às etapas para que o processo caia
          automaticamente em &quot;Minhas tarefas&quot; de cada pessoa.
        </p>
        <div className="card divide-y divide-slate-100">
          {((etapas ?? []) as Etapa[]).map((e) => <FormEtapa key={e.id} e={e} perfis={pf} />)}
          <details>
            <summary className="cursor-pointer px-4 py-3 text-sm font-medium text-indigo-600">+ Nova etapa</summary>
            <FormEtapa perfis={pf} />
          </details>
        </div>
      </section>

      <div className="grid gap-8 lg:grid-cols-2">
        <section>
          <h2 className="font-medium">Feriados</h2>
          <p className="mb-3 text-sm text-slate-500">Não contam como dia útil no cálculo dos prazos.</p>
          <div className="card">
            <form action={salvarFeriado} className="flex gap-2 border-b border-slate-100 p-3">
              <input type="date" name="data" required className="input w-40" />
              <input name="descricao" required placeholder="Descrição" className="input" />
              <ConfirmSubmit className="btn-ghost">Adicionar</ConfirmSubmit>
            </form>
            <ul className="max-h-80 divide-y divide-slate-100 overflow-y-auto text-sm">
              {(feriados ?? []).map((f: { data: string; descricao: string }) => (
                <li key={f.data} className="flex items-center justify-between px-3 py-1.5">
                  <span><span className="tabular-nums text-slate-500">{dataBR(f.data)}</span> · {f.descricao}</span>
                  <form action={removerFeriado}>
                    <input type="hidden" name="data" value={f.data} />
                    <button className="text-xs text-red-600 hover:underline">remover</button>
                  </form>
                </li>
              ))}
            </ul>
          </div>
        </section>

        <section className="space-y-6">
          <div>
            <h2 className="font-medium">Meu nome</h2>
            <form action={salvarMeuNome} className="mt-2 flex gap-2">
              <input name="nome" defaultValue={eu?.nome ?? ""} className="input" required />
              <ConfirmSubmit className="btn-ghost">Salvar</ConfirmSubmit>
            </form>
          </div>
          <div>
            <h2 className="font-medium">Equipe ({pf.length})</h2>
            <p className="mb-2 text-sm text-slate-500">Cada pessoa se cadastra na tela de login com o próprio e-mail.</p>
            <ul className="card divide-y divide-slate-100 text-sm">
              {pf.map((p) => (
                <li key={p.id} className="flex justify-between px-3 py-2">
                  <span className="font-medium">{p.nome ?? "—"}</span>
                  <span className="text-slate-500">{p.email}</span>
                </li>
              ))}
            </ul>
          </div>
        </section>
      </div>
    </div>
  );
}
