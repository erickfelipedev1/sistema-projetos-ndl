import { createClient } from "@/lib/supabase/server";
import type { EtapaAtual, Profile } from "@/lib/types";
import { mapaPerfis } from "@/lib/format";
import CardProcesso from "@/components/CardProcesso";

export const dynamic = "force-dynamic";

export default async function Minhas() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const [{ data }, { data: perfis }] = await Promise.all([
    supabase.from("v_etapas_atuais").select("*").contains("responsaveis", [user!.id]).order("prazo_em", { ascending: true, nullsFirst: false }),
    supabase.from("profiles").select("id,nome,email"),
  ]);
  const lista = (data ?? []) as EtapaAtual[];
  const mapa = mapaPerfis(perfis as Profile[]);

  const grupos = [
    { titulo: "Atrasadas", cor: "text-red-700", itens: lista.filter((e) => e.atrasada) },
    { titulo: "Vencem hoje ou amanhã", cor: "text-amber-700", itens: lista.filter((e) => !e.atrasada && e.dias_restantes !== null && e.dias_restantes <= 1) },
    { titulo: "Próximas", cor: "text-slate-700", itens: lista.filter((e) => !e.atrasada && (e.dias_restantes === null || e.dias_restantes > 1)) },
  ];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold">Minhas tarefas</h1>
        <p className="text-sm text-slate-500">Etapas em andamento em que você é responsável. Abra o processo para concluir e passar para a próxima área.</p>
      </div>
      {!lista.length && (
        <div className="card p-6 text-sm text-slate-500">
          Nenhuma etapa com você agora. Se deveria ter, peça para vincularem seu usuário à etapa em Configurações.
        </div>
      )}
      {grupos.filter((g) => g.itens.length).map((g) => (
        <section key={g.titulo}>
          <h2 className={`mb-2 font-medium ${g.cor}`}>{g.titulo} ({g.itens.length})</h2>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
            {g.itens.map((e) => <CardProcesso key={e.id} e={e} perfis={mapa} mostrarEtapa />)}
          </div>
        </section>
      ))}
    </div>
  );
}
