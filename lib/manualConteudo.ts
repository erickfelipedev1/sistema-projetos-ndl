// Conteúdo de referência do Manual (material "Passo a passo — e-mails de sourcing e fechamento")

export const FORMULARIOS: { titulo: string; onde?: string; campos: string[] }[] = [
  {
    titulo: "Solicitação de cotação de frete internacional",
    campos: [
      "Referência da planilha · Solicitado por",
      "Tipo de cotação: Aéreo / Marítimo / Outros",
      "Produto químico / contém baterias: sim / não (se sim: enviar MSDS / Test report)",
      "Condição: EX-WORKS (endereço completo / zip code; se mais de 1 endereço de coleta, informar) · FOB (porto de embarque) · Outra",
      "Quantidade total (caixas, pallets, container) · Dimensões (C × L × A) · CBM/M³ total · Peso bruto total",
      "CNPJ do cliente (caso não possua, informe) · Mercadoria / HS Code · Valor total da mercadoria",
      "Porto de destino · Outras informações para cotação · Obs. do processo",
    ],
  },
  {
    titulo: "Cotação de frete rodoviário (LCL ou FCL)",
    campos: ["Cliente", "Coleta", "Entrega", "Peso", "Quantidade", "Medidas (C × L × A)", "Valor da carga (USD)", "IMO", "Produto"],
  },
  {
    titulo: "Formulário de classificação de NCM",
    campos: [
      "Dados da empresa: nome, CNPJ, endereço com CEP",
      "Dados do cliente: nome e e-mail do responsável",
      "Informações do projeto: prioridade da estimativa, data de início e de finalização, responsável do produto, tipo de projeto (Flex, Full, Premium)",
      "Dados para a classificação: uso e finalidade, breve descrição, material de composição (obrigatório para tecido, ferro, produto químico), HS Code",
      "Foto do produto",
    ],
  },
  {
    titulo: "Formulário de estimativa de custos",
    campos: [
      "PI e PL (enviar no e-mail) — o que não pode faltar: Incoterm (se EXW, endereço da fábrica), porto de saída, peso bruto e líquido, total de itens, quantidade de volumes (pcs), quantidade de caixas, dimensões das caixas, CBM, HS Code, valor da carga (unitário e total)",
      "Frete internacional",
      "Frete rodoviário",
    ],
  },
  {
    titulo: "Formulário de fechamento (NTL)",
    onde: "Drive › Documentos › Formulário de Fechamento",
    campos: [
      "Tipo de serviço (pesquisa NLG ou fornecedor do cliente) · Data",
      "Empresa: nome, CNPJ, endereço",
      "Fornecedor: nome da empresa fornecedora, nome do fornecedor, telefone, endereço",
      "Produto: produto, descrição, quantidade, valor unitário, valor total",
    ],
  },
];

export const REFERENCIA_PRAZOS = {
  aviso: "Referência do material de treinamento. Os prazos oficiais do sistema são os do fluxograma (Flex 10 · Full 15 · Premium 25 dias úteis na etapa Projetos).",
  colunas: ["Tarefa", "Flex", "Full", "Premium"],
  linhas: [
    ["Recebimento do projeto, reunião com o cliente e montagem das referências", "1", "1", "1"],
    ["Busca por fornecedores", "9", "10", "15"],
    ["Escolha dos fornecedores", "1", "1", "1"],
    ["Montagem da apresentação", "1", "1", "2"],
    ["Envio da apresentação e catálogos + reunião de sourcing", "2", "2", "2"],
    ["Solicitação de PI e PL", "1", "1", "1"],
    ["Solicitação de frete internacional", "1", "2", "1"],
    ["Solicitação de frete rodoviário", "1", "1", "1"],
    ["Solicitação de estimativa de custos", "1", "1", "1"],
    ["Fornecedores apresentados", "2", "3", "2 por seguimento"],
  ],
};

export const INPI = {
  texto:
    "Quando o produto vem com a marca ou o logo do fabricante, sempre confirmar se a empresa tem patente no Brasil ou representantes comerciais — mesmo que o fornecedor diga que não.",
  url: "https://busca.inpi.gov.br/pePI/servlet/LoginController?action=login",
  passos: ["Entrar na consulta do INPI", "Clicar em Marca", "Pesquisa básica → Marca", "Digitar a marca e pesquisar"],
};
