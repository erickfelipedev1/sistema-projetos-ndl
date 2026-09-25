"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { BookOpen, Building2, ChevronDown, LayoutDashboard, ListChecks, Mail, MessagesSquare, Settings, Workflow, LogOut } from "lucide-react";
import Avatar from "@/components/ui/Avatar";

type Contagens = { ativos: number; minhas: number; atrasadasMinhas: number; chat: number; demandas: number };

export default function Sidebar({ nome, cargo, contagens, sair }: { nome: string; cargo: string | null; contagens: Contagens; sair: () => void }) {
  const path = usePathname();
  const sp = useSearchParams();
  const visao = sp.get("visao") ?? "ativos";
  const emProcessos = path.startsWith("/processos");

  const Item = ({ href, icone: Icone, rotulo, ativo, extra }: { href: string; icone: typeof LayoutDashboard; rotulo: string; ativo: boolean; extra?: React.ReactNode }) => (
    <Link href={href} aria-current={ativo ? "page" : undefined}
      className={`group relative flex h-9 items-center gap-2.5 rounded-md px-2.5 text-[13px] transition-colors ${ativo ? "bg-white/10 font-medium text-white" : "text-white/65 hover:bg-white/5 hover:text-white"}`}>
      {ativo && <span className="absolute inset-y-2 left-0 w-0.5 rounded-r bg-white" aria-hidden />}
      <Icone size={16} strokeWidth={1.8} className="shrink-0" />
      <span className="hidden flex-1 truncate lg:inline">{rotulo}</span>
      {extra}
    </Link>
  );

  const Sub = ({ href, rotulo, ativo, n }: { href: string; rotulo: string; ativo: boolean; n?: number }) => (
    <Link href={href} className={`flex h-7 items-center justify-between rounded-md pr-2 pl-9 text-[12.5px] ${ativo ? "text-white" : "text-white/55 hover:text-white"}`}>
      <span className="flex items-center gap-2">
        <span className={`h-1 w-1 rounded-full ${ativo ? "bg-white" : "bg-white/30"}`} />
        {rotulo}
      </span>
      {n !== undefined && <span className="num text-[11px] text-white/50">{n}</span>}
    </Link>
  );

  return (
    <aside className="sticky top-0 flex h-screen w-16 shrink-0 flex-col bg-[#10304f] lg:w-[228px]">
      <Link href="/" className="flex h-14 items-center gap-2.5 border-b border-white/10 px-4">
        <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded bg-white text-[11px] font-bold text-[#10304f]">NDL</span>
        <span className="hidden leading-tight lg:block">
          <span className="block text-[13px] font-semibold text-white">NDL Projetos</span>
          <span className="block text-[11px] text-white/50">Central de operações</span>
        </span>
      </Link>

      <nav className="flex-1 space-y-0.5 overflow-y-auto px-2.5 py-3" aria-label="Principal">
        <Item href="/" icone={LayoutDashboard} rotulo="Painel" ativo={path === "/"} />
        <Item href="/processos" icone={Workflow} rotulo="Processos" ativo={emProcessos && !path.startsWith("/processos/novo") && path === "/processos"}
          extra={<ChevronDown size={14} className={`hidden text-white/40 transition-transform lg:block ${emProcessos ? "" : "-rotate-90"}`} />} />
        {emProcessos && (
          <div className="hidden space-y-0.5 pb-1 lg:block">
            <Sub href="/processos?visao=ativos" rotulo="Ativos" ativo={path === "/processos" && visao === "ativos"} n={contagens.ativos} />
            <Sub href="/processos?visao=concluido" rotulo="Concluídos" ativo={path === "/processos" && visao === "concluido"} />
            <Sub href="/processos?visao=cancelado" rotulo="Cancelados" ativo={path === "/processos" && visao === "cancelado"} />
          </div>
        )}
        <Item href="/minhas" icone={ListChecks} rotulo="Minhas tarefas" ativo={path.startsWith("/minhas")}
          extra={contagens.minhas > 0 ? (
            <span className={`num hidden rounded px-1.5 text-[11px] font-semibold lg:inline ${contagens.atrasadasMinhas > 0 ? "bg-bad text-white" : "bg-white/15 text-white"}`}>{contagens.minhas}</span>
          ) : null} />
        <Item href="/clientes" icone={Building2} rotulo="Clientes" ativo={path.startsWith("/clientes")} />
        <Item href="/chat" icone={MessagesSquare} rotulo="Chat e demandas" ativo={path.startsWith("/chat")}
          extra={contagens.chat + contagens.demandas > 0 ? (
            <span className="flex items-center gap-1">
              {contagens.demandas > 0 && <span title="Demandas abertas para você" className="num hidden rounded bg-warn px-1.5 text-[11px] font-semibold text-white lg:inline">{contagens.demandas}</span>}
              {contagens.chat > 0 && <span title="Mensagens não lidas" className="num rounded bg-primary-2 px-1.5 text-[11px] font-semibold text-white">{contagens.chat}</span>}
            </span>
          ) : null} />
        <div className="my-2 border-t border-white/10" />
        <Item href="/manual" icone={BookOpen} rotulo="Manual" ativo={path.startsWith("/manual")} />
        <Item href="/emails" icone={Mail} rotulo="E-mails" ativo={path.startsWith("/emails")} />
        <Item href="/configuracoes" icone={Settings} rotulo="Configurações" ativo={path.startsWith("/configuracoes")} />
      </nav>

      <div className="border-t border-white/10 p-3">
        <div className="flex items-center gap-2.5">
          <Avatar nome={nome} tamanho={30} className="bg-white/15 text-white" />
          <div className="hidden min-w-0 flex-1 leading-tight lg:block">
            <p className="truncate text-[13px] font-medium text-white">{nome}</p>
            <p className="truncate text-[11px] text-white/50">{cargo ?? "Sem cargo"}</p>
          </div>
          <form action={sair} className="hidden lg:block">
            <button className="rounded p-1.5 text-white/50 hover:bg-white/10 hover:text-white" aria-label="Sair" title="Sair"><LogOut size={15} /></button>
          </form>
        </div>
      </div>
    </aside>
  );
}
