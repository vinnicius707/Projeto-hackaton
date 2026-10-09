-- =====================================================================
-- Verificação do telefone por SMS (SIMULADO).
--
-- O cadastro deixa a conta "não verificada" e gera um código de 6 dígitos.
-- O banco guarda só o SHA-256 do código, que vale 10 minutos e aceita 5
-- tentativas. A sessão só abre depois do código certo.
--
-- Simulação: as funções devolvem o código no JSON (campo sms.codigo) para o
-- app mostrar um "SMS simulado". Quem decide se ele sai para o app é o n8n
-- (SIMULAR_SMS no nó de resposta); com SMS de verdade, o n8n manda o código
-- pelo provedor e tira o campo da resposta.
--
-- Nenhum cifrão seguido de número neste arquivo (o nó Postgres do n8n leria
-- como parâmetro).
-- =====================================================================

alter table central.usuarios add column if not exists telefone_verificado boolean not null default false;

-- As contas que já existiam (os admins, criados direto no banco) ficam verificadas.
update central.usuarios set telefone_verificado = true where not telefone_verificado;

create table if not exists central.verificacoes (
  usuario_id  bigint primary key references central.usuarios (id) on delete cascade,
  codigo_hash text not null,
  expira_em   timestamptz not null,
  tentativas  int not null default 0,
  enviado_em  timestamptz not null default now()
);
alter table central.verificacoes enable row level security;

-- "(13) 9****-4567"
create or replace function central.mascarar_telefone(p_tel text) returns text
language sql immutable set search_path = '' as $$
  select case
    when p_tel ~ '^[0-9]{10,11}$' then
      '(' || left(p_tel, 2) || ') ' || substr(p_tel, 3, 1) || repeat('*', length(p_tel) - 7) || '-' || right(p_tel, 4)
    else ''
  end
$$;

-- Gera e guarda um código novo (6 dígitos, aleatório de verdade). Devolve o código em claro.
create or replace function central.novo_codigo(p_usuario_id bigint) returns text
language plpgsql set search_path = '' as $$
declare
  v_codigo text := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
begin
  insert into central.verificacoes (usuario_id, codigo_hash, expira_em, tentativas, enviado_em)
  values (p_usuario_id, encode(extensions.digest(v_codigo, 'sha256'), 'hex'), now() + interval '10 minutes', 0, now())
  on conflict (usuario_id) do update
    set codigo_hash = excluded.codigo_hash, expira_em = excluded.expira_em, tentativas = 0, enviado_em = now();
  return v_codigo;
end
$$;

-- O "pedido de verificação" que o app recebe (com o SMS simulado).
create or replace function central.pedido_verificacao(u central.usuarios, p_codigo text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'status', 'verificar',
    'documento', u.documento,
    'telefone', central.mascarar_telefone(u.telefone),
    'validoMinutos', 10,
    'sms', case when p_codigo is null then null
                else jsonb_build_object('para', central.mascarar_telefone(u.telefone), 'codigo', p_codigo) end
  )
$$;

-- Cadastro: grava a conta NÃO verificada e manda o código. Documento repetido -> 'existe'.
create or replace function central.cadastrar(p_dados jsonb, p_senha text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v central.usuarios;
begin
  insert into central.usuarios
    (doc_type, documento, nome_completo, nome_social, nascimento, telefone, endereco, senha_hash, telefone_verificado)
  values (
    p_dados ->> 'docType',
    p_dados ->> 'document',
    p_dados ->> 'fullName',
    coalesce(p_dados ->> 'socialName', ''),
    nullif(p_dados ->> 'birthDate', '')::date,
    coalesce(p_dados ->> 'phone', ''),
    coalesce(p_dados -> 'address', '{}'::jsonb),
    extensions.crypt(p_senha, extensions.gen_salt('bf', 10)),
    false
  )
  on conflict (documento) do nothing
  returning * into v;

  if v.id is null then
    return jsonb_build_object('status', 'existe');
  end if;
  return central.pedido_verificacao(v, central.novo_codigo(v.id));
end
$$;

-- Login. Senha certa e telefone não verificado -> manda um código novo (no máximo 1 por minuto).
create or replace function central.entrar(p_documento text, p_senha text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v central.usuarios;
  ultimo timestamptz;
begin
  select * into v from central.usuarios where documento = p_documento and ativo;

  if v.id is null then
    perform extensions.crypt(p_senha, extensions.gen_salt('bf', 10));
    return jsonb_build_object('status', 'negado');
  end if;

  if v.senha_hash <> extensions.crypt(p_senha, v.senha_hash) then
    return jsonb_build_object('status', 'negado');
  end if;

  if not v.telefone_verificado then
    select enviado_em into ultimo from central.verificacoes where usuario_id = v.id;
    if ultimo is not null and ultimo > now() - interval '60 seconds' then
      return central.pedido_verificacao(v, null) || jsonb_build_object('reenvioEmSegundos',
        ceil(extract(epoch from (ultimo + interval '60 seconds' - now())))::int);
    end if;
    return central.pedido_verificacao(v, central.novo_codigo(v.id));
  end if;

  return jsonb_build_object('status', 'ok', 'token', central.nova_sessao(v.id), 'usuario', central.perfil(v));
end
$$;

-- Confere o código. Certo -> marca o telefone como verificado e abre a sessão.
create or replace function central.verificar(p_documento text, p_codigo text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v central.usuarios;
  c central.verificacoes;
begin
  select * into v from central.usuarios where documento = p_documento and ativo;
  if v.id is null then
    return jsonb_build_object('status', 'invalido');
  end if;
  if v.telefone_verificado then
    return jsonb_build_object('status', 'ja_verificado');
  end if;

  select * into c from central.verificacoes where usuario_id = v.id;
  if c.usuario_id is null or c.expira_em < now() then
    return jsonb_build_object('status', 'expirado');
  end if;
  if c.tentativas >= 5 then
    return jsonb_build_object('status', 'bloqueado');
  end if;

  if c.codigo_hash <> encode(extensions.digest(coalesce(p_codigo, ''), 'sha256'), 'hex') then
    update central.verificacoes set tentativas = tentativas + 1 where usuario_id = v.id;
    return jsonb_build_object('status', 'incorreto', 'tentativasRestantes', greatest(0, 4 - c.tentativas));
  end if;

  update central.usuarios set telefone_verificado = true where id = v.id returning * into v;
  delete from central.verificacoes where usuario_id = v.id;
  return jsonb_build_object('status', 'ok', 'token', central.nova_sessao(v.id), 'usuario', central.perfil(v));
end
$$;

-- Reenvia o código (no máximo 1 por minuto).
create or replace function central.reenviar(p_documento text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v central.usuarios;
  ultimo timestamptz;
begin
  select * into v from central.usuarios where documento = p_documento and ativo;
  if v.id is null or v.telefone_verificado then
    return jsonb_build_object('status', 'invalido');
  end if;
  select enviado_em into ultimo from central.verificacoes where usuario_id = v.id;
  if ultimo is not null and ultimo > now() - interval '60 seconds' then
    return jsonb_build_object('status', 'aguarde',
      'reenvioEmSegundos', ceil(extract(epoch from (ultimo + interval '60 seconds' - now())))::int);
  end if;
  return central.pedido_verificacao(v, central.novo_codigo(v.id));
end
$$;

-- O perfil passa a dizer se o telefone foi verificado.
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
    'address',      jsonb_build_object('cep', '', 'street', '', 'number', '', 'complement', '',
                                       'district', '', 'city', '', 'state', '') || u.endereco,
    'registeredAt', to_char(u.criado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'cargo',        u.cargo,
    'admin',        u.admin,
    'telefoneVerificado', u.telefone_verificado
  )
$$;

revoke all on all functions in schema central from public;

select
  (select count(*) from central.usuarios where telefone_verificado) as verificadas,
  (select count(*) from central.usuarios) as contas,
  central.mascarar_telefone('13991234567') as mascara_exemplo;
