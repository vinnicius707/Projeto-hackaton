-- O perfil sempre devolve o endereço com os 7 campos (vazios no que faltar):
-- é o formato que o app espera, e o admin, criado direto no banco, não tem endereço.
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
    'admin',        u.admin
  )
$$;
revoke all on function central.perfil(central.usuarios) from public;

select central.perfil(u) -> 'address' as endereco_admin from central.usuarios u where documento = '00000000191';
