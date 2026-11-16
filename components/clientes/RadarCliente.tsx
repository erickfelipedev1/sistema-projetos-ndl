import { Check, Circle, Pencil, ShieldCheck } from "lucide-react";
import type { Anexo, ClienteRadar } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { RADAR_STATUS, radarResumo } from "@/lib/radar";
import { salvarRadar } from "@/app/actions";
import Modal from "@/components/ui/Modal";
import SubmitButton from "@/components/ui/SubmitButton";
import Anexos from "@/components/anexos/Anexos";

function Item({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <li className="flex items-center gap-2 text-[13px]">
      {ok ? <Check size={14} className="shrink-0 text-ok-ink" /> : <Circle size={12} className="mx-px shrink-0 text-subtle" />}
      <span className={ok ? "text-ink" : "text-muted"}>{children}</span>
    </li>
  );
}

function Form({ clienteId, r }: { clienteId: string; r: ClienteRadar | null }) {
  const caixa = (nome: keyof ClienteRadar, rotulo: string) => (
    <label className="flex items-center gap-2 text-[13px]"><input type="checkbox" name={nome} defaultChecked={!!r?.[nome]} /> {rotulo}</label>
  );
  return (
    <form action={salvarRadar} className="grid gap-3 sm:grid-cols-2">
      <input type="hidden" name="cliente_id" value={clienteId} />
      <div className="sm:col-span-2">
        <label className="label" htmlFor="rd-status">Situação</label>
        <select id="rd-status" name="status" defaultValue={r?.status ?? "documentos"} className="input">
          {Object.entries(RADAR_STATUS).map(([v, t]) => <option key={v} value={v}>{t}</option>)}
        </select>
      </div>
      <fieldset className="space-y-1.5 sm:col-span-2">
        <legend className="label">Documentos recebidos do cliente</legend>
        {caixa("doc_identidade", "RG ou CNH do responsável legal")}
        {caixa("doc_contrato_social", "Contrato social da empresa")}
        {caixa("doc_ecpf", "Certificado digital e-CPF do responsável legal")}
      </fieldset>
      <div><label className="label" htmlFor="rd-mod">Modalidade</label><input id="rd-mod" name="modalidade" defaultValue={r?.modalidade ?? ""} className="input" placeholder="Ex.: Limitada" /></div>
      <div><label className="label" htmlFor="rd-lim">Limite (US$)</label><input id="rd-lim" name="limite_usd" inputMode="decimal" defaultValue={r?.limite_usd ?? ""} className="input" placeholder="Ex.: 150000" /></div>
      <div><label className="label" htmlFor="rd-per">O limite vale por</label>
        <select id="rd-per" name="limite_periodo" defaultValue={r?.limite_periodo ?? "semestre"} className="input">
          <option value="semestre">semestre</option><option value="ano">ano</option><option value="">— (ilimitado)</option>
        </select></div>
      <div><label className="label" htmlFor="rd-def">Deferido em</label><input id="rd-def" type="date" name="deferido_em" defaultValue={r?.deferido_em ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="rd-val">Validade até</label><input id="rd-val" type="date" name="validade_ate" defaultValue={r?.validade_ate ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="rd-dev">Devolutiva enviada ao cliente em</label><input id="rd-dev" type="date" name="devolutiva_em" defaultValue={r?.devolutiva_em ?? ""} className="input" /></div>
      <fieldset className="space-y-1.5 sm:col-span-2">
        <legend className="label">Procuração e e-CAC</legend>
        {caixa("procuracao_assinada", "Procuração assinada pelo cliente")}
        {caixa("procuracao_firma", "Firma reconhecida")}
        {caixa("dte_ecac", "Optou pelo DTE (caixa postal do e-CAC)")}
      </fieldset>
      <div><label className="label" htmlFor="rd-proc">Procuração recebida em</label><input id="rd-proc" type="date" name="procuracao_em" defaultValue={r?.procuracao_em ?? ""} className="input" /></div>
      <div className="sm:col-span-2"><label className="label" htmlFor="rd-hist">Histórico das comunicações com o cliente</label>
        <textarea id="rd-hist" name="historico" rows={5} defaultValue={r?.historico ?? ""} className="textarea" placeholder="Datas, o que foi pedido, o que o cliente enviou, o que a Receita respondeu…" /></div>
      <div className="flex justify-end sm:col-span-2"><SubmitButton>Salvar Radar</SubmitButton></div>
    </form>
  );
}

export default function RadarCliente({ clienteId, radar, anexos, autores }: { clienteId: string; radar: ClienteRadar | null; anexos: Anexo[]; autores: Record<string, string> }) {
  const r = radar;
  const resumo = radarResumo(r);
  return (
    <section className="card">
      <div className="card-header">
        <div className="min-w-0">
          <h2 className="card-title flex items-center gap-2"><ShieldCheck size={15} className="text-subtle" /> Habilitação de Radar (Siscomex)</h2>
          <p className="text-xs text-muted">O limite do Radar define quanto a empresa pode importar. Consulte antes de planejar as importações.</p>
        </div>
        <Modal rotulo={<><Pencil size={13} /> {r ? "Atualizar" : "Iniciar habilitação"}</>} botaoClasse={r ? "btn-ghost" : "btn-primary"} titulo="Habilitação de Radar" largura={640}>
          <Form clienteId={clienteId} r={r} />
        </Modal>
      </div>
      {r ? (
        <div className="grid gap-4 px-4 py-3 md:grid-cols-3">
          <div>
            <p className="text-[11px] font-medium text-muted">Situação</p>
            <p className={`mt-1 text-[15px] font-semibold ${r.status === "habilitado" ? "text-ok-ink" : r.status === "indeferido" || r.status === "inativo" ? "text-bad-ink" : "text-primary"}`}>{RADAR_STATUS[r.status]}</p>
            <p className="mt-1 text-[13px] text-ink">{resumo ?? "Limite ainda não definido"}</p>
            {r.deferido_em && <p className="text-xs text-muted">Deferido em {dataBR(r.deferido_em)}</p>}
            {r.devolutiva_em && <p className="text-xs text-muted">Devolutiva ao cliente em {dataBR(r.devolutiva_em)}</p>}
          </div>
          <div>
            <p className="text-[11px] font-medium text-muted">Documentos do cliente</p>
            <ul className="mt-1 space-y-1">
              <Item ok={r.doc_identidade}>RG ou CNH do responsável</Item>
              <Item ok={r.doc_contrato_social}>Contrato social</Item>
              <Item ok={r.doc_ecpf}>e-CPF do responsável</Item>
            </ul>
          </div>
          <div>
            <p className="text-[11px] font-medium text-muted">Procuração e e-CAC</p>
            <ul className="mt-1 space-y-1">
              <Item ok={r.procuracao_assinada}>Procuração assinada{r.procuracao_em ? ` (${dataBR(r.procuracao_em)})` : ""}</Item>
              <Item ok={r.procuracao_firma}>Firma reconhecida</Item>
              <Item ok={r.dte_ecac}>DTE no e-CAC</Item>
            </ul>
          </div>
          {r.historico && (
            <div className="md:col-span-3">
              <p className="text-[11px] font-medium text-muted">Histórico</p>
              <p className="mt-1 text-[13px] whitespace-pre-line text-ink">{r.historico}</p>
            </div>
          )}
        </div>
      ) : <p className="px-4 py-3 text-[13px] text-muted">Ainda não há habilitação de Radar registrada para este cliente.</p>}
      <div className="border-t border-line p-4">
        <Anexos autores={autores} grupos={[{
          chave: "radar", titulo: "Arquivos do Radar", sub: "Documentos recebidos, termo de deferimento, consultas, procuração assinada, e-mail da devolutiva…",
          anexos, destino: { cliente_id: clienteId, categoria: "radar" },
        }]} />
      </div>
    </section>
  );
}
