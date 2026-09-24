import Link from "next/link";
import Nav from "@/components/Nav";
import { createClient } from "@/lib/supabase/server";
import { sair } from "@/app/actions";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const [{ data: perfil }, { count }] = await Promise.all([
    supabase.from("profiles").select("nome").eq("id", user!.id).maybeSingle(),
    supabase.from("v_etapas_atuais").select("id", { count: "exact", head: true }).contains("responsaveis", [user!.id]),
  ]);

  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-20 border-b border-slate-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex max-w-[1600px] flex-wrap items-center gap-3 px-4 py-2.5">
          <Link href="/" className="mr-2 font-semibold text-slate-900">Controle de Processos</Link>
          <Nav contagemMinhas={count ?? 0} />
          <div className="ml-auto flex items-center gap-3 text-sm">
            <span className="text-slate-500">{perfil?.nome ?? user?.email}</span>
            <form action={sair}><button className="text-slate-500 hover:text-slate-900">Sair</button></form>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-[1600px] px-4 py-6">{children}</main>
    </div>
  );
}
