export type Profile = { id: string; nome: string | null; email: string | null };

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
};

export type ProcessoEtapa = {
  id: string;
  processo_id: string;
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
};

export type Processo = {
  id: string;
  codigo: string;
  cliente: string;
  plano: string | null;
  descricao: string | null;
  status: "ativo" | "concluido" | "cancelado";
  created_at: string;
  concluido_em: string | null;
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
};
