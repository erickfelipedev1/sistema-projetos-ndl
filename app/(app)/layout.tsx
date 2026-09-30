import { Suspense } from "react";
import { redirect } from "next/navigation";
import Sidebar from "@/components/Sidebar";
import Topbar from "@/components/Topbar";
import { createClient } from "@/lib/supabase/server";
import { sair } from "@/app/actions";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data: perfil } = await supabase.from("profiles").select("nome,cargo,trocar_senha,tipo").eq("id", user!.id).maybeSingle();
  if (perfil?.trocar_senha) redirect("/trocar-senha");
  if (perfil?.tipo === "cliente") redirect("/portal");
  const [{ count: ativos }, { data: minhas }, { data: conversas }, { count: demandas }] = await Promise.all([
    supabase.from("processos").select("id", { count: "exact", head: true }).eq("status", "ativo"),
    supabase.from("v_etapas_atuais").select("atrasada").contains("responsaveis", [user!.id]),
    supabase.rpc("chat_conversas"),
    supabase.from("mensagens").select("id", { count: "exact", head: true }).eq("demanda_para", user!.id).eq("demanda_status", "aberta"),
  ]);
  const naoLidas = ((conversas ?? []) as { nao_lidas: number }[]).reduce((s, c) => s + (c.nao_lidas ?? 0), 0);

  return (
    <div className="flex min-h-screen">
      <Suspense fallback={<aside className="w-16 shrink-0 bg-[#10304f] lg:w-[228px]" />}>
        <Sidebar
          nome={perfil?.nome ?? user?.email ?? ""}
          cargo={perfil?.cargo ?? null}
          contagens={{ ativos: ativos ?? 0, minhas: minhas?.length ?? 0, atrasadasMinhas: (minhas ?? []).filter((m) => m.atrasada).length, chat: naoLidas, demandas: demandas ?? 0 }}
          sair={sair}
        />
      </Suspense>
      <div className="flex min-w-0 flex-1 flex-col">
        <Topbar />
        <main className="flex-1 px-5 py-5 xl:px-7">{children}</main>
      </div>
    </div>
  );
}
