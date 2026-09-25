export type Profile = { id: string; nome: string | null; email: string | null; cargo?: string | null; usuario?: string | null; tipo?: "equipe" | "cliente"; cliente_id?: string | null; admin?: boolean };

export type Etapa = {
  id: number;
  ordem: number;
  area: string;
  nome: string;
  tipo: "tarefa" | "marco" | "final";
  prazo_dias_uteis: number | null;
  prazo_editavel: boolean;
  responsaveis_label: string | null;
  responsaveis_padrao: string[];
  ativo: boolean;
  prazo_flex: number | null;
  prazo_full: number | null;
  prazo_premium: number | null;
  prazo_com_certificacao: number | null;
};

export type EtapaAtual = {
  id: string;
  processo_id: string;
  etapa_id: number | null;
  ordem: number;
  area: string;
  nome: string;
  tipo: string;
  prazo_dias_uteis: number | null;
  prazo_editavel: boolean;
  responsaveis: string[];
  responsaveis_label: string | null;
  iniciado_em: string | null;
  prazo_em: string | null;
  codigo: string;
  cliente: string;
  plano: string | null;
  descricao: string | null;
  processo_criado_em: string;
  dias_restantes: number | null;
  atrasada: boolean;
  certificacao: boolean;
  checklist_total: number;
  checklist_feitos: number;
  gerenciamento: "ntl" | "proprio" | null;
  situacao: string | null;
  proxima_acao: string | null;
  ultima_atualizacao: string | null;
  contato: string | null;
  aguardando_cliente: boolean;
  aguardando_desde: string | null;
  ultima_cobranca: string | null;
  proxima_cobranca: string | null;
  cobrar_hoje: boolean;
  cliente_id: string;
};

export type ProcessoEtapa = {
  id: string;
  processo_id: string;
  etapa_id: number | null;
  ordem: number;
  area: string;
  nome: string;
  tipo: string;
  prazo_dias_uteis: number | null;
  prazo_editavel: boolean;
  responsaveis: string[];
  responsaveis_label: string | null;
  status: "pendente" | "em_andamento" | "concluida";
  iniciado_em: string | null;
  prazo_em: string | null;
  concluido_em: string | null;
  concluido_por: string | null;
  situacao: string | null;
  aguardando_cliente: boolean;
  aguardando_desde: string | null;
  ultima_cobranca: string | null;
  retomado_em: string | null;
};

export type Processo = {
  id: string;
  codigo: string;
  cliente: string;
  cliente_id: string;
  plano: string | null;
  descricao: string | null;
  status: "ativo" | "concluido" | "cancelado";
  created_at: string;
  concluido_em: string | null;
  certificacao: boolean;
  contato: string | null;
  gerenciamento: "ntl" | "proprio" | null;
};

export type Evento = {
  id: number;
  processo_id: string;
  autor: string | null;
  tipo: string;
  texto: string;
  created_at: string;
};

export type Desempenho = {
  etapa_id: number;
  ordem: number;
  area: string;
  nome: string;
  tipo: string;
  prazo_dias_uteis: number | null;
  concluidas: number;
  media_dias_uteis: number | null;
  concluidas_com_atraso: number;
  em_andamento: number;
  atrasadas_agora: number;
  prazo_flex: number | null;
  prazo_full: number | null;
  prazo_premium: number | null;
  prazo_com_certificacao: number | null;
};

export type ChecklistItem = {
  id: string;
  processo_etapa_id: string;
  modelo_id?: number | null;
  avisado_em?: string | null;
  ordem: number;
  titulo: string;
  descricao: string | null;
  feito: boolean;
  feito_por: string | null;
  feito_em: string | null;
  aguarda_cliente: boolean;
  prazo_depois: number | null;
};

export type ChecklistModelo = {
  id: number;
  etapa_id: number;
  ordem: number;
  titulo: string;
  descricao: string | null;
  ativo: boolean;
  condicao: "ntl" | "proprio" | null;
  aguarda_cliente: boolean;
  prazo_depois: number | null;
  responsaveis: string[];
  responsaveis_label: string | null;
  prazo_item: number | null;
  prazo_item_cert: number | null;
};

export type EmailModelo = {
  id: number;
  chave: string;
  etapa_id: number | null;
  ordem: number;
  titulo: string;
  para: string | null;
  assunto: string | null;
  corpo: string;
  condicao: "ntl" | "proprio" | null;
  ativo: boolean;
};

export type Cliente = {
  id: string;
  nome: string;
  cnpj: string | null;
  contato: string | null;
  email: string | null;
  telefone: string | null;
  observacoes: string | null;
  created_at: string;
};

export type Anexo = {
  id: string;
  processo_id: string | null;
  processo_etapa_id: string | null;
  cliente_id: string | null;
  nome: string;
  caminho: string;
  tamanho: number | null;
  tipo_mime: string | null;
  autor: string | null;
  created_at: string;
};

export type Conversa = {
  id: string;
  tipo: "canal" | "direta";
  nome: string | null;
  outro_id: string | null;
  ultima_texto: string | null;
  ultima_em: string | null;
  nao_lidas: number;
};

export type Mensagem = {
  id: number;
  conversa_id: string;
  autor: string;
  texto: string;
  processo_id: string | null;
  demanda_para: string | null;
  demanda_prazo: string | null;
  demanda_status: "aberta" | "concluida" | null;
  demanda_concluida_em: string | null;
  created_at: string;
  checklist_id?: string | null;
};

export type PortalEtapa = { ordem: number; nome: string; area: string; tipo: string; status: "pendente" | "em_andamento" | "concluida"; iniciado_em: string | null; concluido_em: string | null; aguardando_cliente?: boolean; aguardando_o_que?: string | null };
export type PortalProcesso = { id: string; codigo: string; plano: string | null; status: string; descricao: string | null; aberto_em: string; concluido_em: string | null; previsao: string | null; etapas: PortalEtapa[] };
export type PortalDados = { cliente: { id: string; nome: string }; processos: PortalProcesso[] } | null;
