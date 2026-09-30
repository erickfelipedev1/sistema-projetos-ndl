import { BellRing } from "lucide-react";
import { registrarCobranca } from "@/app/actions";
import SubmitButton from "@/components/ui/SubmitButton";

/** "Registrei a cobrança" — a próxima cobrança passa para daqui a 7 dias */
export default function CobrancaForm({ peId, compacto = false }: { peId: string; compacto?: boolean }) {
  return (
    <form action={registrarCobranca} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="pe_id" value={peId} />
      {!compacto && <input name="obs" className="input h-8 min-w-[200px] flex-1" placeholder="Como cobrou? (ex.: WhatsApp, e-mail) — opcional" />}
      <SubmitButton className={compacto ? "btn-ghost h-7 text-xs" : "btn-ghost"} pendente="Registrando…">
        <BellRing size={compacto ? 13 : 14} /> Registrar cobrança
      </SubmitButton>
    </form>
  );
}
