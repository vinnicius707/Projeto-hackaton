PRAGMA foreign_keys = ON;

CREATE TABLE nivel_senioridade (
    id INTEGER PRIMARY KEY,
    nome TEXT NOT NULL UNIQUE,
    ordem INTEGER NOT NULL UNIQUE CHECK (ordem > 0)
) STRICT;

CREATE TABLE calendario_feriados (
    id INTEGER PRIMARY KEY,
    codigo TEXT NOT NULL UNIQUE,
    nome TEXT NOT NULL
) STRICT;

CREATE TABLE funcionario (
    id INTEGER PRIMARY KEY,
    matricula TEXT UNIQUE,
    nome TEXT NOT NULL CHECK (length(trim(nome)) > 0),
    email TEXT COLLATE NOCASE UNIQUE,
    cargo TEXT NOT NULL CHECK (cargo IN ('DIRETOR', 'GERENTE', 'COORDENADOR', 'COLABORADOR')),
    nivel_senioridade_id INTEGER REFERENCES nivel_senioridade(id),
    gestor_id INTEGER,
    gestor_cargo TEXT,
    ado_identity_id TEXT UNIQUE,
    calendario_feriados_id INTEGER REFERENCES calendario_feriados(id),
    ativo INTEGER NOT NULL DEFAULT 1 CHECK (ativo IN (0, 1)),
    FOREIGN KEY (id, cargo) REFERENCES funcionario(id, cargo) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (gestor_id, gestor_cargo) REFERENCES funcionario(id, cargo) DEFERRABLE INITIALLY DEFERRED,
    UNIQUE (id, cargo),
    CHECK (
        (cargo IN ('DIRETOR', 'GERENTE') AND gestor_id IS NULL AND gestor_cargo IS NULL)
        OR (cargo = 'COORDENADOR' AND gestor_id IS NOT NULL AND gestor_cargo = 'GERENTE')
        OR (cargo = 'COLABORADOR' AND gestor_id IS NOT NULL AND gestor_cargo = 'COORDENADOR')
    ),
    CHECK (cargo <> 'COLABORADOR' OR nivel_senioridade_id IS NOT NULL)
) STRICT;

CREATE TABLE setor (
    id INTEGER PRIMARY KEY,
    nome TEXT NOT NULL UNIQUE CHECK (length(trim(nome)) > 0),
    diretor_id INTEGER NOT NULL,
    diretor_cargo TEXT NOT NULL DEFAULT 'DIRETOR' CHECK (diretor_cargo = 'DIRETOR'),
    gerente_id INTEGER NOT NULL UNIQUE,
    gerente_cargo TEXT NOT NULL DEFAULT 'GERENTE' CHECK (gerente_cargo = 'GERENTE'),
    FOREIGN KEY (diretor_id, diretor_cargo) REFERENCES funcionario(id, cargo) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (gerente_id, gerente_cargo) REFERENCES funcionario(id, cargo) DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE feriado (
    id INTEGER PRIMARY KEY,
    calendario_id INTEGER NOT NULL REFERENCES calendario_feriados(id) ON DELETE CASCADE,
    data TEXT NOT NULL CHECK (date(data) = data),
    nome TEXT NOT NULL,
    UNIQUE (calendario_id, data, nome)
) STRICT;

CREATE TABLE projeto (
    id TEXT PRIMARY KEY,
    nome TEXT NOT NULL,
    origem TEXT NOT NULL DEFAULT 'ADO' CHECK (origem IN ('ADO', 'MANUAL')),
    estado TEXT,
    url TEXT,
    atualizado_em TEXT
) STRICT;

CREATE TABLE equipe (
    id TEXT PRIMARY KEY,
    projeto_id TEXT NOT NULL REFERENCES projeto(id) ON DELETE CASCADE,
    nome TEXT NOT NULL,
    coordenador_id INTEGER,
    coordenador_cargo TEXT NOT NULL DEFAULT 'COORDENADOR' CHECK (coordenador_cargo = 'COORDENADOR'),
    origem TEXT NOT NULL DEFAULT 'ADO' CHECK (origem IN ('ADO', 'MANUAL')),
    FOREIGN KEY (coordenador_id, coordenador_cargo) REFERENCES funcionario(id, cargo) DEFERRABLE INITIALLY DEFERRED,
    UNIQUE (id, projeto_id)
) STRICT;

CREATE TABLE membro_equipe (
    equipe_id TEXT NOT NULL REFERENCES equipe(id) ON DELETE CASCADE,
    funcionario_id INTEGER NOT NULL REFERENCES funcionario(id) ON DELETE CASCADE,
    adicionado_em TEXT,
    PRIMARY KEY (equipe_id, funcionario_id)
) STRICT;

CREATE TABLE iteracao (
    id TEXT PRIMARY KEY,
    projeto_id TEXT NOT NULL REFERENCES projeto(id) ON DELETE CASCADE,
    nome TEXT NOT NULL,
    inicio TEXT CHECK (inicio IS NULL OR date(inicio) = inicio),
    fim TEXT CHECK (fim IS NULL OR date(fim) = fim),
    origem TEXT NOT NULL DEFAULT 'ADO' CHECK (origem IN ('ADO', 'MANUAL')),
    CHECK (inicio IS NULL OR fim IS NULL OR inicio <= fim),
    UNIQUE (id, projeto_id)
) STRICT;

CREATE TABLE equipe_iteracao (
    equipe_id TEXT NOT NULL,
    iteracao_id TEXT NOT NULL,
    projeto_id TEXT NOT NULL,
    PRIMARY KEY (equipe_id, iteracao_id),
    FOREIGN KEY (equipe_id, projeto_id) REFERENCES equipe(id, projeto_id) ON DELETE CASCADE,
    FOREIGN KEY (iteracao_id, projeto_id) REFERENCES iteracao(id, projeto_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE capacidade (
    equipe_id TEXT NOT NULL,
    iteracao_id TEXT NOT NULL,
    funcionario_id INTEGER NOT NULL REFERENCES funcionario(id) ON DELETE CASCADE,
    horas_dia REAL NOT NULL CHECK (horas_dia >= 0),
    atividade TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (equipe_id, iteracao_id, funcionario_id, atividade),
    FOREIGN KEY (equipe_id, iteracao_id) REFERENCES equipe_iteracao(equipe_id, iteracao_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE ausencia (
    id INTEGER PRIMARY KEY,
    funcionario_id INTEGER REFERENCES funcionario(id) ON DELETE CASCADE,
    equipe_id TEXT REFERENCES equipe(id) ON DELETE CASCADE,
    inicio TEXT NOT NULL CHECK (date(inicio) = inicio),
    fim TEXT NOT NULL CHECK (date(fim) = fim),
    horas_dia REAL NOT NULL DEFAULT 0 CHECK (horas_dia >= 0),
    motivo TEXT,
    CHECK (funcionario_id IS NOT NULL OR equipe_id IS NOT NULL),
    CHECK (inicio <= fim)
) STRICT;

CREATE TABLE work_item (
    id INTEGER PRIMARY KEY,
    projeto_id TEXT NOT NULL REFERENCES projeto(id) ON DELETE CASCADE,
    iteracao_id TEXT,
    responsavel_id INTEGER REFERENCES funcionario(id) ON DELETE SET NULL,
    titulo TEXT NOT NULL,
    tipo TEXT,
    estado TEXT,
    esforco REAL CHECK (esforco IS NULL OR esforco >= 0),
    origem TEXT NOT NULL DEFAULT 'ADO' CHECK (origem IN ('ADO', 'MANUAL')),
    atualizado_em TEXT,
    FOREIGN KEY (iteracao_id, projeto_id) REFERENCES iteracao(id, projeto_id) DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE cenario (
    id INTEGER PRIMARY KEY,
    nome TEXT NOT NULL UNIQUE,
    descricao TEXT,
    criado_em TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE alteracao_plano (
    cenario_id INTEGER NOT NULL REFERENCES cenario(id) ON DELETE CASCADE,
    work_item_id INTEGER NOT NULL REFERENCES work_item(id) ON DELETE CASCADE,
    iteracao_id TEXT REFERENCES iteracao(id) ON DELETE SET NULL,
    responsavel_id INTEGER REFERENCES funcionario(id) ON DELETE SET NULL,
    PRIMARY KEY (cenario_id, work_item_id)
) STRICT;

CREATE TABLE carga_diaria (
    cenario_id INTEGER NOT NULL REFERENCES cenario(id) ON DELETE CASCADE,
    funcionario_id INTEGER NOT NULL REFERENCES funcionario(id) ON DELETE CASCADE,
    data TEXT NOT NULL CHECK (date(data) = data),
    horas_disponiveis REAL NOT NULL CHECK (horas_disponiveis >= 0),
    horas_alocadas REAL NOT NULL CHECK (horas_alocadas >= 0),
    conflito INTEGER NOT NULL DEFAULT 0 CHECK (conflito IN (0, 1)),
    PRIMARY KEY (cenario_id, funcionario_id, data)
) STRICT;

CREATE TABLE alerta (
    id INTEGER PRIMARY KEY,
    cenario_id INTEGER NOT NULL REFERENCES cenario(id) ON DELETE CASCADE,
    funcionario_id INTEGER REFERENCES funcionario(id) ON DELETE CASCADE,
    tipo TEXT NOT NULL,
    mensagem TEXT NOT NULL,
    data TEXT CHECK (data IS NULL OR date(data) = data),
    criado_em TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE execucao_sync (
    id INTEGER PRIMARY KEY,
    projeto_id TEXT REFERENCES projeto(id) ON DELETE SET NULL,
    iniciado_em TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    concluido_em TEXT,
    estado TEXT NOT NULL CHECK (estado IN ('EXECUTANDO', 'SUCESSO', 'ERRO')),
    detalhes TEXT
) STRICT;

CREATE INDEX idx_funcionario_gestor ON funcionario(gestor_id);
CREATE INDEX idx_setor_diretor ON setor(diretor_id);
CREATE INDEX idx_equipe_projeto ON equipe(projeto_id);
CREATE INDEX idx_work_item_responsavel ON work_item(responsavel_id);
CREATE INDEX idx_work_item_iteracao ON work_item(iteracao_id);
CREATE INDEX idx_carga_data ON carga_diaria(data);
CREATE INDEX idx_alerta_cenario ON alerta(cenario_id);

CREATE TRIGGER proteger_cenario_baseline_delete
BEFORE DELETE ON cenario
WHEN OLD.id = 1
BEGIN
    SELECT RAISE(ABORT, 'O cenario baseline nao pode ser excluido');
END;

CREATE TRIGGER proteger_cenario_baseline_id
BEFORE UPDATE OF id ON cenario
WHEN OLD.id = 1 AND NEW.id <> 1
BEGIN
    SELECT RAISE(ABORT, 'O cenario baseline nao pode ser renumerado');
END;

CREATE TRIGGER validar_mudanca_cargo_com_subordinados
BEFORE UPDATE OF cargo ON funcionario
WHEN NEW.cargo <> OLD.cargo
 AND EXISTS (SELECT 1 FROM funcionario subordinado WHERE subordinado.gestor_id = OLD.id)
BEGIN
    SELECT RAISE(ABORT, 'Nao e possivel mudar o cargo de funcionario com subordinados');
END;

CREATE TRIGGER validar_coordenador_equipe_insert
BEFORE INSERT ON equipe
WHEN NEW.coordenador_id IS NOT NULL
 AND NOT EXISTS (
    SELECT 1 FROM funcionario
    WHERE id = NEW.coordenador_id AND cargo = 'COORDENADOR'
 )
BEGIN
    SELECT RAISE(ABORT, 'O coordenador da equipe deve ter cargo COORDENADOR');
END;

CREATE TRIGGER validar_coordenador_equipe_update
BEFORE UPDATE OF coordenador_id ON equipe
WHEN NEW.coordenador_id IS NOT NULL
 AND NOT EXISTS (
    SELECT 1 FROM funcionario
    WHERE id = NEW.coordenador_id AND cargo = 'COORDENADOR'
 )
BEGIN
    SELECT RAISE(ABORT, 'O coordenador da equipe deve ter cargo COORDENADOR');
END;

CREATE VIEW vw_violacoes_hierarquia AS
SELECT f.id AS funcionario_id, f.nome, f.cargo, 'DIRETOR_SEM_SETOR' AS violacao
FROM funcionario f
WHERE f.cargo = 'DIRETOR'
  AND NOT EXISTS (SELECT 1 FROM setor s WHERE s.diretor_id = f.id)
UNION ALL
SELECT f.id, f.nome, f.cargo, 'GERENTE_SEM_SETOR'
FROM funcionario f
WHERE f.cargo = 'GERENTE'
  AND NOT EXISTS (SELECT 1 FROM setor s WHERE s.gerente_id = f.id)
UNION ALL
SELECT f.id, f.nome, f.cargo, 'COORDENADOR_SEM_COLABORADORES'
FROM funcionario f
WHERE f.cargo = 'COORDENADOR'
  AND NOT EXISTS (
      SELECT 1 FROM funcionario subordinado
      WHERE subordinado.gestor_id = f.id AND subordinado.cargo = 'COLABORADOR'
  );

CREATE VIEW vw_organograma AS
SELECT
    colaborador.id AS funcionario_id,
    colaborador.nome AS funcionario,
    colaborador.cargo,
    coordenador.id AS coordenador_id,
    coordenador.nome AS coordenador,
    gerente.id AS gerente_id,
    gerente.nome AS gerente,
    setor.id AS setor_id,
    setor.nome AS setor,
    diretor.id AS diretor_id,
    diretor.nome AS diretor
FROM funcionario colaborador
LEFT JOIN funcionario coordenador
    ON coordenador.id = CASE
        WHEN colaborador.cargo = 'COORDENADOR' THEN colaborador.id
        WHEN colaborador.cargo = 'COLABORADOR' THEN colaborador.gestor_id
    END
LEFT JOIN funcionario gerente
    ON gerente.id = CASE
        WHEN colaborador.cargo = 'GERENTE' THEN colaborador.id
        WHEN colaborador.cargo = 'COORDENADOR' THEN colaborador.gestor_id
        WHEN colaborador.cargo = 'COLABORADOR' THEN coordenador.gestor_id
    END
LEFT JOIN setor ON setor.gerente_id = gerente.id
LEFT JOIN funcionario diretor ON diretor.id = setor.diretor_id;

CREATE VIEW vw_utilizacao_semanal AS
SELECT
    c.cenario_id,
    c.funcionario_id,
    f.nome AS funcionario,
    strftime('%Y-%W', c.data) AS semana,
    SUM(c.horas_disponiveis) AS horas_disponiveis,
    SUM(c.horas_alocadas) AS horas_alocadas,
    CASE
        WHEN MAX(c.conflito) = 1 OR SUM(c.horas_disponiveis) = 0 THEN 'Conflito'
        WHEN 100.0 * SUM(c.horas_alocadas) / SUM(c.horas_disponiveis) < 70 THEN 'Ocioso'
        WHEN 100.0 * SUM(c.horas_alocadas) / SUM(c.horas_disponiveis) <= 100 THEN 'Saudavel'
        WHEN 100.0 * SUM(c.horas_alocadas) / SUM(c.horas_disponiveis) <= 120 THEN 'Em risco'
        ELSE 'Sobrecarregado'
    END AS faixa_utilizacao,
    CASE
        WHEN SUM(c.horas_disponiveis) = 0 THEN NULL
        ELSE ROUND(100.0 * SUM(c.horas_alocadas) / SUM(c.horas_disponiveis), 2)
    END AS utilizacao_percentual
FROM carga_diaria c
JOIN funcionario f ON f.id = c.funcionario_id
GROUP BY c.cenario_id, c.funcionario_id, f.nome, strftime('%Y-%W', c.data);

INSERT INTO nivel_senioridade (id, nome, ordem) VALUES
    (1, 'Junior', 1),
    (2, 'Pleno', 2),
    (3, 'Senior', 3);

INSERT INTO calendario_feriados (id, codigo, nome) VALUES
    (1, 'BR', 'Brasil'),
    (2, 'BR-SP', 'Sao Paulo'),
    (3, 'BR-SP-Santos', 'Santos');

INSERT INTO cenario (id, nome, descricao) VALUES
    (1, 'baseline', 'Estado atual sincronizado do Azure DevOps');
