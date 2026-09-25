import Link from "next/link";
import { ArrowLeft, Eye } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import type { PortalDados } from "@/lib/types";
import PortalView from "@/components/portal/PortalView";

export const dynamic = "force-dynamic";

export default async function PortalPreview({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data } = await supabase.rpc("portal_processos", { p_cliente_id: id });
  return (
    <div className="mx-auto max-w-6xl">
      <div className="mb-5 flex flex-wrap items-center justify-between gap-2 rounded-md border border-primary-2/30 bg-primary-soft px-4 py-2.5 text-[13px] text-primary">
        <span className="flex items-center gap-2"><Eye size={15} /> Pré-visualização: é assim que o cliente vê o portal.</span>
        <Link href={`/clientes/${id}`} className="flex items-center gap-1 font-medium hover:underline"><ArrowLeft size={14} /> Voltar ao cliente</Link>
      </div>
      <PortalView dados={data as PortalDados} />
    </div>
  );
}
