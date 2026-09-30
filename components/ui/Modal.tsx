"use client";

import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";

/**
 * Modal / Drawer baseados em <dialog>. Pode ser usado a partir de Server Components:
 * `rotulo` é o conteúdo do botão que abre; `children` é o conteúdo (pode conter <form action={serverAction}>).
 */
export default function Modal({ rotulo, botaoClasse = "btn-ghost", titulo, descricao, children, lado = false, largura = 480 }: {
  rotulo: React.ReactNode; botaoClasse?: string; titulo: string; descricao?: string; children: React.ReactNode; lado?: boolean; largura?: number;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const [aberto, setAberto] = useState(false);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (aberto && !d.open) d.showModal();
    if (!aberto && d.open) d.close();
  }, [aberto]);
  // fecha depois que um formulário interno é enviado com sucesso
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    const onSubmit = () => setTimeout(() => setAberto(false), 400);
    d.addEventListener("submit", onSubmit);
    return () => d.removeEventListener("submit", onSubmit);
  }, []);
  const fechar = () => setAberto(false);
  return (
    <>
      <button type="button" className={botaoClasse} onClick={() => setAberto(true)}>{rotulo}</button>
      <dialog ref={ref} onClose={fechar} onClick={(e) => { if (e.target === ref.current) fechar(); }}
        className={`max-h-none max-w-none bg-transparent p-0 backdrop:bg-[#0b1a2b]/35 ${lado ? "fixed top-0 right-0 left-auto m-0 h-full" : "m-auto"}`}
        style={{ width: `min(${largura}px, 100vw)` }}>
        {aberto && (
          <div className={`flex flex-col bg-surface text-left shadow-[var(--shadow-pop)] ${lado ? "h-full border-l border-line" : "max-h-[85vh] rounded-lg border border-line"}`}>
            <div className="flex items-start justify-between gap-4 border-b border-line px-5 py-3.5">
              <div>
                <h2 className="text-sm font-semibold text-ink">{titulo}</h2>
                {descricao && <p className="mt-0.5 text-xs text-muted">{descricao}</p>}
              </div>
              <button type="button" onClick={fechar} className="btn-quiet h-7 w-7 px-0" aria-label="Fechar"><X size={16} /></button>
            </div>
            <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
          </div>
        )}
      </dialog>
    </>
  );
}

export function Drawer(props: Omit<Parameters<typeof Modal>[0], "lado">) {
  return <Modal {...props} lado largura={props.largura ?? 460} />;
}
