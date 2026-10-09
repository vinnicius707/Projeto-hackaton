-- =====================================================================
-- Capacidade com códigos (para o app traduzir).
--
-- Os alertas calculados, os avisos e os bloqueios da simulação passam a
-- trazer um "codigo" e os "dados" que a frase usa. O app monta a frase no
-- idioma escolhido; a "mensagem" em português continua indo junto, como
-- reserva (e é o que os alertas registrados pelo time têm).
-- Nenhum cifrão seguido de número neste arquivo.
-- =====================================================================

-- Simulação: avisos e bloqueio com código.
create or replace function central.api_simular(p_cenario bigint, p_wi bigint, p_it text, p_resp bigint) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  w public.work_item;
  it_atual text;
  resp_atual bigint;
  alvo public.iteracao;
  pessoa public.funcionario;
  bloqueio text;
  bloqueio_codigo text;
  avisos jsonb := '[]'::jsonb;
  impacto jsonb;
begin
  select * into w from public.work_item where id = p_wi;
  if w.id is null then
    return jsonb_build_object('erro', 'Item não encontrado.', 'codigo', 'ITEM_NAO_ENCONTRADO');
  end if;
  if not exists (select 1 from public.cenario where id = p_cenario) then
    return jsonb_build_object('erro', 'Cenário não encontrado.', 'codigo', 'CENARIO_NAO_ENCONTRADO');
  end if;

  select pc.it_cen, pc.resp_cen into it_atual, resp_atual
  from central.plano_cenario(p_cenario) pc where pc.work_item_id = p_wi;

  select * into alvo from public.iteracao where id = p_it;
  select * into pessoa from public.funcionario where id = p_resp and ativo;

  if alvo.id is null then
    bloqueio := 'Sprint de destino não encontrada.'; bloqueio_codigo := 'SPRINT_NAO_ENCONTRADA';
  elsif pessoa.id is null then
    bloqueio := 'Pessoa de destino não encontrada.'; bloqueio_codigo := 'PESSOA_NAO_ENCONTRADA';
  elsif alvo.projeto_id <> w.projeto_id then
    bloqueio := 'A sprint de destino é de outro projeto.'; bloqueio_codigo := 'OUTRO_PROJETO';
  elsif w.estado = 'Concluido' then
    bloqueio := 'Item concluído não muda de lugar.'; bloqueio_codigo := 'CONCLUIDO';
  elsif alvo.fim < central.hoje() then
    bloqueio := 'A sprint de destino já terminou.'; bloqueio_codigo := 'SPRINT_ENCERRADA';
  elsif p_it = it_atual and p_resp is not distinct from resp_atual then
    bloqueio := 'O item já está nesse lugar.'; bloqueio_codigo := 'MESMO_LUGAR';
  end if;

  if alvo.id is not null and pessoa.id is not null then
    if not exists (
      select 1 from public.membro_equipe m
      join public.equipe_iteracao ei on ei.equipe_id = m.equipe_id
      where m.funcionario_id = pessoa.id and ei.iteracao_id = alvo.id
    ) then
      avisos := avisos || jsonb_build_array(jsonb_build_object(
        'tipo', 'EQUIPE', 'codigo', 'FORA_DA_EQUIPE',
        'dados', jsonb_build_object('pessoa', pessoa.nome, 'sprint', alvo.nome),
        'mensagem', pessoa.nome || ' não faz parte de nenhuma equipe da ' || alvo.nome || '.'));
    end if;

    avisos := avisos || coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', 'AUSENCIA', 'codigo', case when a.equipe_id is null then 'AUSENCIA' else 'AUSENCIA_EQUIPE' end,
        'dados', jsonb_build_object('motivo', a.motivo, 'equipe', e.nome, 'inicio', a.inicio, 'fim', a.fim, 'sprint', alvo.nome),
        'mensagem', coalesce(e.nome || ': ', '') || a.motivo || ' de ' || to_char(a.inicio, 'DD/MM')
          || case when a.fim > a.inicio then ' a ' || to_char(a.fim, 'DD/MM') else '' end
          || ' — dentro da ' || alvo.nome || '.') order by a.inicio)
      from public.ausencia a left join public.equipe e on e.id = a.equipe_id
      where (a.funcionario_id = pessoa.id
             or a.equipe_id in (select m.equipe_id from public.membro_equipe m where m.funcionario_id = pessoa.id))
        and a.inicio <= alvo.fim and a.fim >= alvo.inicio
    ), '[]'::jsonb);

    avisos := avisos || coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', 'FERIADO', 'codigo', 'FERIADO',
        'dados', jsonb_build_object('feriado', fe.nome, 'data', fe.data, 'sprint', alvo.nome),
        'mensagem', fe.nome || ' (' || to_char(fe.data, 'DD/MM') || ') cai dentro da ' || alvo.nome || '.') order by fe.data)
      from public.feriado fe
      where fe.calendario_id = coalesce(pessoa.calendario_feriados_id, central.calendario_padrao())
        and fe.data between alvo.inicio and alvo.fim and extract(isodow from fe.data) < 6
    ), '[]'::jsonb);
  end if;

  if bloqueio is null then
    with antes as (select * from central.sprints_cenario(p_cenario)),
         depois as (select * from central.sprints_cenario(p_cenario, p_wi, p_it, p_resp)),
         pares as (select resp_atual as pessoa_id, it_atual as it union select p_resp, p_it)
    select jsonb_agg(jsonb_build_object(
             'pessoa', pr.pessoa_id, 'nome', f.nome, 'sprint', pr.it, 'sprintNome', i.nome,
             'antes', jsonb_build_object('pct', a.pct, 'faixa', a.faixa, 'alocadas', a.alocadas, 'disponiveis', a.disponiveis),
             'depois', jsonb_build_object('pct', d.pct, 'faixa', d.faixa, 'alocadas', d.alocadas, 'disponiveis', d.disponiveis)
           ) order by f.nome, i.inicio)
      into impacto
    from pares pr
    join public.funcionario f on f.id = pr.pessoa_id
    join public.iteracao i on i.id = pr.it
    left join antes a on a.funcionario_id = pr.pessoa_id and a.iteracao_id = pr.it
    left join depois d on d.funcionario_id = pr.pessoa_id and d.iteracao_id = pr.it;
  end if;

  return jsonb_build_object(
    'item', jsonb_build_object('id', w.id, 'titulo', w.titulo, 'esforco', w.esforco, 'estado', w.estado),
    'de', jsonb_build_object('sprint', it_atual, 'responsavel', resp_atual),
    'para', jsonb_build_object('sprint', p_it, 'responsavel', p_resp),
    'permitido', bloqueio is null,
    'bloqueio', bloqueio,
    'bloqueioCodigo', bloqueio_codigo,
    'avisos', avisos,
    'impacto', coalesce(impacto, '[]'::jsonb)
  );
end
$$;

create or replace function central.api_mover(p_cenario bigint, p_wi bigint, p_it text, p_resp bigint) returns jsonb
language plpgsql set search_path = '' as $$
declare
  sim jsonb;
  w public.work_item;
begin
  if p_cenario = 1 then
    return jsonb_build_object('erro', 'O cenário baseline é o estado real e não muda. Escolha um cenário de simulação para mover itens.',
                              'codigo', 'BASELINE_FIXO');
  end if;

  sim := central.api_simular(p_cenario, p_wi, p_it, p_resp);
  if sim ? 'erro' or not (sim ->> 'permitido')::boolean then
    return sim;
  end if;

  select * into w from public.work_item where id = p_wi;
  delete from public.alteracao_plano where cenario_id = p_cenario and work_item_id = p_wi;
  if not (p_it = w.iteracao_id and p_resp is not distinct from w.responsavel_id) then
    insert into public.alteracao_plano (cenario_id, work_item_id, iteracao_id, responsavel_id)
    values (p_cenario, p_wi, p_it, p_resp);
  end if;

  return sim || jsonb_build_object('salvo', true);
end
$$;

create or replace function central.api_desfazer(p_cenario bigint, p_wi bigint) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if p_cenario = 1 then
    return jsonb_build_object('erro', 'O cenário baseline não tem mudanças para desfazer.', 'codigo', 'BASELINE_FIXO');
  end if;
  delete from public.alteracao_plano where cenario_id = p_cenario and work_item_id = p_wi;
  return jsonb_build_object('salvo', true);
end
$$;

-- Alertas com código e dados.
create or replace function central.api_alertas(p_cenario bigint) returns jsonb
language sql stable set search_path = '' as $$
  with h as (select central.hoje() as dia, date_trunc('week', central.hoje())::date as semana),
  jf as (select (select semana from h) + 8 * 7 - 1 as fim),
  plano as (
    select * from central.plano_cenario(p_cenario)
    where estado <> 'Concluido' and resp_cen is not null and it_cen is not null
  ),
  semanas as (select * from central.semanas_cenario(p_cenario, (select semana from h), (select fim from jf))),
  carga as (
    select * from central.carga_cenario(p_cenario) c
    where c.data between (select dia from h) and (select fim from jf)
  ),
  registrados as (
    select 'registrado'::text as origem, al.tipo, null::text as codigo, al.funcionario_id, al.data,
           al.mensagem, '{}'::jsonb as dados
    from public.alerta al where al.cenario_id = p_cenario
  ),
  sobrecarga as (
    select 'calculado'::text, 'SOBRECARGA'::text, 'SOBRECARGA'::text, s.funcionario_id, min(s.semana),
           'Chega a ' || max(s.pct) || '% de utilização'
           || case when count(*) > 1 then ' em ' || count(*) || ' semanas' else '' end
           || ', a partir da semana de ' || to_char(min(s.semana), 'DD/MM') || '.',
           jsonb_build_object('pct', max(s.pct), 'semanas', count(*), 'desde', min(s.semana))
    from semanas s where s.faixa = 'Sobrecarregado' group by s.funcionario_id
  ),
  conflito as (
    select 'calculado'::text, 'CONFLITO'::text, 'CONFLITO'::text, c.funcionario_id, min(c.data),
           'Tem mais trabalho do que horas disponíveis (ou trabalho em dia sem disponibilidade) em '
           || count(*) || case when count(*) = 1 then ' dia' else ' dias' end
           || ', a partir de ' || to_char(min(c.data), 'DD/MM') || '.',
           jsonb_build_object('dias', count(*), 'desde', min(c.data))
    from carga c where c.conflito group by c.funcionario_id
  ),
  ausencia as (
    select 'calculado'::text, 'AUSENCIA'::text, 'AUSENCIA'::text, a.funcionario_id, a.inicio,
           a.motivo || ' de ' || to_char(a.inicio, 'DD/MM')
           || case when a.fim > a.inicio then ' a ' || to_char(a.fim, 'DD/MM') else '' end
           || ' durante a ' || i.nome || ' (' || pr.nome || '), com ' || count(p.work_item_id)
           || case when count(p.work_item_id) = 1 then ' item em aberto.' else ' itens em aberto.' end,
           jsonb_build_object('motivo', a.motivo, 'inicio', a.inicio, 'fim', a.fim, 'sprint', i.nome,
                              'projeto', pr.nome, 'itens', count(p.work_item_id))
    from public.ausencia a
    join plano p on p.resp_cen = a.funcionario_id
    join public.iteracao i on i.id = p.it_cen
    join public.projeto pr on pr.id = i.projeto_id
    where a.funcionario_id is not null and a.fim >= (select dia from h)
      and a.inicio <= i.fim and a.fim >= i.inicio
    group by a.id, a.funcionario_id, a.inicio, a.fim, a.motivo, i.id, i.nome, pr.nome
  ),
  ausencia_equipe as (
    select 'calculado'::text, 'AUSENCIA'::text, 'AUSENCIA_EQUIPE'::text, null::bigint, a.inicio,
           a.motivo || ' (' || e.nome || ') em ' || to_char(a.inicio, 'DD/MM')
           || case when a.fim > a.inicio then ' a ' || to_char(a.fim, 'DD/MM') else '' end
           || ': ' || a.horas_dia || 'h por dia a menos para cada pessoa da equipe.',
           jsonb_build_object('motivo', a.motivo, 'equipe', e.nome, 'inicio', a.inicio, 'fim', a.fim, 'horasDia', a.horas_dia)
    from public.ausencia a join public.equipe e on e.id = a.equipe_id
    where a.fim >= (select dia from h)
  ),
  feriado as (
    select 'calculado'::text, 'FERIADO'::text, 'FERIADO'::text, null::bigint, fe.data,
           fe.nome || ' (' || to_char(fe.data, 'DD/MM') || ') cai dentro da '
           || string_agg(distinct i.nome || ' do ' || pr.nome, ', ') || ': um dia útil a menos.',
           jsonb_build_object('feriado', fe.nome, 'data', fe.data,
             'sprints', jsonb_agg(distinct jsonb_build_object('sprint', i.nome, 'projeto', pr.nome)))
    from public.feriado fe
    join public.iteracao i on fe.data between i.inicio and i.fim
    join public.projeto pr on pr.id = i.projeto_id
    where fe.calendario_id = central.calendario_padrao()
      and fe.data between (select dia from h) and (select fim from jf)
      and extract(isodow from fe.data) < 6
    group by fe.data, fe.nome
  ),
  sobreposicao as (
    select 'calculado'::text, 'SOBREPOSICAO'::text, 'SOBREPOSICAO'::text, p1.resp_cen, greatest(i1.inicio, i2.inicio),
           'Tem itens em aberto em dois projetos ao mesmo tempo: ' || i1.nome || ' (' || pr1.nome || ') e '
           || i2.nome || ' (' || pr2.nome || ').',
           jsonb_build_object('sprint1', i1.nome, 'projeto1', pr1.nome, 'sprint2', i2.nome, 'projeto2', pr2.nome)
    from plano p1
    join plano p2 on p2.resp_cen = p1.resp_cen
    join public.iteracao i1 on i1.id = p1.it_cen
    join public.iteracao i2 on i2.id = p2.it_cen
    join public.projeto pr1 on pr1.id = i1.projeto_id
    join public.projeto pr2 on pr2.id = i2.projeto_id
    where i1.id < i2.id and i1.projeto_id <> i2.projeto_id
      and i1.inicio <= i2.fim and i2.inicio <= i1.fim
      and greatest(i1.fim, i2.fim) >= (select dia from h)
    group by p1.resp_cen, i1.id, i1.nome, i1.inicio, pr1.nome, i2.id, i2.nome, i2.inicio, pr2.nome
  ),
  todos as (
    select * from registrados
    union all select * from sobrecarga
    union all select * from conflito
    union all select * from ausencia
    union all select * from ausencia_equipe
    union all select * from feriado
    union all select * from sobreposicao
  ),
  classificados as (
    select t.*, case
             when t.tipo in ('SOBRECARGA', 'CONFLITO') then 'alta'
             when t.tipo in ('FERIADO', 'OCIOSIDADE') then 'baixa'
             else 'media' end as gravidade
    from todos t
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'origem', c.origem, 'tipo', c.tipo, 'codigo', c.codigo, 'dados', c.dados, 'gravidade', c.gravidade,
           'pessoa', c.funcionario_id, 'nome', f.nome, 'data', c.data, 'mensagem', c.mensagem
         ) order by case c.gravidade when 'alta' then 1 when 'media' then 2 else 3 end, c.data, f.nome), '[]'::jsonb)
  from classificados c left join public.funcionario f on f.id = c.funcionario_id
$$;

revoke all on all functions in schema central from public;

select
  (select jsonb_array_length(central.api_alertas(1))) as alertas,
  (select central.api_alertas(1) -> 1) as exemplo,
  (select central.api_simular(1, 1001, 'IT-CENTRAL-S12', 11) ->> 'bloqueioCodigo') as bloqueio_concluido;
