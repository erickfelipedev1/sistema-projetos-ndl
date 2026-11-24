import { redirect } from "next/navigation";
import { LogOut } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { sair } from "@/app/actions";
import type { PortalDados } from "@/lib/types";
import PortalView from "@/components/portal/PortalView";
import Image from "next/image";

export const dynamic = "force-dynamic";

export default async function Portal() {
  const supabase = await createClient();
  // sessão lida do cookie local — o middleware já validou nesta mesma requisição
  const { data: { session } } = await supabase.auth.getSession();
  const user = session?.user;
  if (!user) redirect("/login");
  const [{ data: perfil }, { data }] = await Promise.all([
    supabase.from("profiles").select("nome,tipo,trocar_senha").eq("id", user.id).maybeSingle(),
    supabase.rpc("portal_processos"),
  ]);
  if (perfil?.trocar_senha) redirect("/trocar-senha");
  if (perfil?.tipo !== "cliente") redirect("/clientes");

  return (
    <div className="min-h-screen bg-canvas">
      <header className="border-b border-white/10 bg-[#10304f]">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4">
          <div className="flex items-center gap-2.5">
            <Image src="/logo-rota4s-branco.png" alt="Rota 4S" width={634} height={160} priority className="h-8 w-auto" />
            <span className="border-l border-white/15 pl-2.5 leading-tight">
              <span className="block text-[13px] font-semibold text-white">Portal do cliente</span>
              <span className="block text-[11px] text-white/50">Grupo Now</span>
            </span>
          </div>
          <div className="flex items-center gap-3">
            <span className="hidden text-[13px] text-white/70 sm:inline">{perfil?.nome}</span>
            <form action={sair}><button className="flex items-center gap-1.5 rounded px-2 py-1.5 text-[13px] text-white/70 hover:bg-white/10 hover:text-white"><LogOut size={14} /> Sair</button></form>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">
        <PortalView dados={data as PortalDados} />
        <p className="mt-8 text-center text-xs text-subtle">Dúvidas sobre o seu processo? Fale com o seu atendimento (CS) da Rota 4S.</p>
      </main>
    </div>
  );
}
