-- =====================================================================
-- Central de Painéis — contas e sessões do app.
--
-- Schema próprio (central), separado do sistema que já mora no public:
-- nada aqui lê ou altera as tabelas de lá. O schema não é exposto pela
-- API do Supabase e as tabelas têm RLS ligado sem política nenhuma, então
-- só o servidor (o n8n, com a credencial do banco) chega nelas.
--
-- A senha nunca é guardada: só o hash bcrypt (pgcrypto). O token de sessão
-- também não: o app recebe o token uma vez, e o banco guarda o SHA-256 dele.
-- =====================================================================

create schema if not exists central;
revoke all on schema central from public;

create table if not exists central.usuarios (
  id            bigint generated always as identity primary key,
  doc_type      text not null check (doc_type in ('cpf', 'cnpj')),
  -- CPF: 11 dígitos. CNPJ: 12 letras ou dígitos + 2 dígitos (o alfanumérico de 2026).
  documento     text not null unique check (documento ~ '^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$'),
  nome_completo text not null check (char_length(nome_completo) between 1 and 120),
  nome_social   text not null default '' check (char_length(nome_social) <= 120),
  nascimento    date,
  telefone      text not null default '' check (telefone ~ '^([0-9]{10,11})?$'),
  endereco      jsonb not null default '{}'::jsonb,
  -- Quem se cadastra entra como COLABORADOR; o cargo só muda por aqui, no banco.
  cargo         text not null default 'COLABORADOR'
                check (cargo in ('COLABORADOR', 'COORDENADOR', 'GERENTE', 'DIRETOR')),
  admin         boolean not null default false,
  ativo         boolean not null default true,
  senha_hash    text not null,
  criado_em     timestamptz not null default now()
);
alter table central.usuarios enable row level security;

create table if not exists central.sessoes (
  token_hash text primary key,
  usuario_id bigint not null references central.usuarios (id) on delete cascade,
  criada_em  timestamptz not null default now(),
  expira_em  timestamptz not null default now() + interval '12 hours'
);
create index if not exists sessoes_usuario_idx on central.sessoes (usuario_id);
alter table central.sessoes enable row level security;

-- O cadastro no formato do app (o Employee do types.ts), mais cargo e admin.
create or replace function central.perfil(u central.usuarios) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id',           u.id,
    'docType',      u.doc_type,
    'document',     u.documento,
    'fullName',     u.nome_completo,
    'socialName',   u.nome_social,
    'birthDate',    coalesce(to_char(u.nascimento, 'YYYY-MM-DD'), ''),
    'phone',        u.telefone,
    'address',      u.endereco,
    'registeredAt', to_char(u.criado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'cargo',        u.cargo,
    'admin',        u.admin
  )
$$;

-- Abre uma sessão e devolve o token (a única vez que ele existe em claro).
create or replace function central.nova_sessao(p_usuario_id bigint) returns text
language plpgsql set search_path = '' as $$
declare
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from central.sessoes where expira_em < now();
  insert into central.sessoes (token_hash, usuario_id)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), p_usuario_id);
  return v_token;
end
$$;

-- Cadastro: grava a conta e já abre a sessão. Documento repetido -> status 'existe'.
create or replace function central.cadastrar(p_dados jsonb, p_senha text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v central.usuarios;
begin
  insert into central.usuarios
    (doc_type, documento, nome_completo, nome_social, nascimento, telefone, endereco, senha_hash)
  values (
    p_dados ->> 'docType',
    p_dados ->> 'document',
    p_dados ->> 'fullName',
    coalesce(p_dados ->> 'socialName', ''),
    nullif(p_dados ->> 'birthDate', '')::date,
    coalesce(p_dados ->> 'phone', ''),
    coalesce(p_dados -> 'address', '{}'::jsonb),
    extensions.crypt(p_senha, extensions.gen_salt('bf', 10))
  )
  on conflict (documento) do nothing
  returning * into v;

  if v.id is null then
    return jsonb_build_object('status', 'existe');
  end if;
  return jsonb_build_object('status', 'ok', 'token', central.nova_sessao(v.id), 'usuario', central.perfil(v));
end
$$;

-- Login. Documento desconhecido gasta o mesmo bcrypt que uma senha errada:
-- o tempo da resposta não entrega quem tem cadastro.
create or replace function central.entrar(p_documento text, p_senha text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v central.usuarios;
begin
  select * into v from central.usuarios where documento = p_documento and ativo;

  if v.id is null then
    perform extensions.crypt(p_senha, extensions.gen_salt('bf', 10));
    return jsonb_build_object('status', 'negado');
  end if;

  if v.senha_hash <> extensions.crypt(p_senha, v.senha_hash) then
    return jsonb_build_object('status', 'negado');
  end if;

  return jsonb_build_object('status', 'ok', 'token', central.nova_sessao(v.id), 'usuario', central.perfil(v));
end
$$;

-- Quem é o dono do token, ou null (token inválido, vencido ou conta inativa).
create or replace function central.sessao(p_token text) returns jsonb
language sql stable set search_path = '' as $$
  select central.perfil(u)
  from central.sessoes s
  join central.usuarios u on u.id = s.usuario_id
  where s.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
    and s.expira_em > now()
    and u.ativo
$$;

-- Logout: apaga a sessão do token.
create or replace function central.sair(p_token text) returns void
language sql set search_path = '' as $$
  delete from central.sessoes
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

revoke all on all functions in schema central from public;

-- O admin. CPF de teste 000.000.001-91 (troque por um de verdade com um
-- UPDATE). A senha chega aqui só como hash bcrypt, em hexadecimal: o
-- prefixo do hash (cifrão seguido de número) seria lido como parâmetro
-- da query pelo nó Postgres do n8n.
insert into central.usuarios (doc_type, documento, nome_completo, cargo, admin, senha_hash)
values ('cpf', '00000000191', 'Administrador', 'DIRETOR', true,
        convert_from(decode('__ADMIN_HASH_HEX__', 'hex'), 'UTF8'))
on conflict (documento) do update
  set senha_hash = excluded.senha_hash, cargo = 'DIRETOR', admin = true, ativo = true;

select id, documento, nome_completo, cargo, admin,
       left(senha_hash, 7) as hash_prefixo,
       (select count(*) from central.usuarios) as total_usuarios
from central.usuarios where documento = '00000000191';
