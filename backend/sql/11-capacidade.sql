-- =====================================================================
-- Projeto Atlas — cálculo de capacidade e API do planejamento.
--
-- Tudo aqui mora no schema central e só LÊ o modelo do time (public).
-- A única escrita no public é em public.alteracao_plano, pelas funções
-- api_mover/api_desfazer, e nunca no cenário baseline (id 1).
--
-- Como a carga de um cenário é calculada
--   baseline (cenário 1) = public.carga_diaria, como o time a gravou;
--   outro cenário        = baseline + o efeito dos itens que ele move
--                          (public.alteracao_plano).
-- Um item movido tira o esforço (horas) da pessoa e da sprint de antes e
-- põe na de depois, espalhado pelos dias úteis da sprint (sem fim de
-- semana nem feriado do calendário da pessoa). Itens concluídos não pesam.
--
-- As faixas são as da vw_utilizacao_semanal do time (Ocioso < 70%,
-- Saudável até 100%, Em risco até 120%, Sobrecarregado acima), mais
-- "Ausente" para semana sem hora disponível e sem trabalho.
--
-- Atenção: nenhum cifrão seguido de número neste arquivo — o nó Postgres
-- do n8n leria como parâmetro.
-- =====================================================================

create or replace function central.hoje() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'America/Sao_Paulo')::date
$$;

create or replace function central.calendario_padrao() returns bigint
language sql stable set search_path = '' as $$
  select calendario_feriados_id from public.funcionario
  where calendario_feriados_id is not null
  group by 1 order by count(*) desc limit 1
$$;

create or replace function central.faixa(p_disp numeric, p_aloc numeric, p_conflito boolean) returns text
language sql immutable set search_path = '' as $$
  select case
    when p_conflito then 'Conflito'
    when coalesce(p_disp, 0) = 0 and coalesce(p_aloc, 0) = 0 then 'Ausente'
    when coalesce(p_disp, 0) = 0 then 'Conflito'
    when 100 * p_aloc / p_disp < 70 then 'Ocioso'
    when 100 * p_aloc / p_disp <= 100 then 'Saudavel'
    when 100 * p_aloc / p_disp <= 120 then 'Em risco'
    else 'Sobrecarregado'
  end
$$;

-- O plano de um cenário: onde cada item está (sprint e responsável).
-- p_wi/p_it/p_resp simulam UMA mudança a mais, sem gravar (simulação).
create or replace function central.plano_cenario(
  p_cenario bigint, p_wi bigint default null, p_it text default null, p_resp bigint default null
) returns table (
  work_item_id bigint, projeto_id text, horas numeric, estado text,
  it_base text, resp_base bigint, it_cen text, resp_cen bigint, movido boolean
)
language sql stable set search_path = '' as $$
  select w.id, w.projeto_id, coalesce(w.esforco, 0), w.estado,
         w.iteracao_id, w.responsavel_id,
         x.it, x.resp,
         (x.it is distinct from w.iteracao_id or x.resp is distinct from w.responsavel_id)
  from public.work_item w
  left join public.alteracao_plano a
    on a.work_item_id = w.id and a.cenario_id = p_cenario and p_cenario <> 1
  cross join lateral (
    select case when w.id = p_wi then coalesce(p_it, w.iteracao_id) else coalesce(a.iteracao_id, w.iteracao_id) end as it,
           case when w.id = p_wi then coalesce(p_resp, w.responsavel_id) else coalesce(a.responsavel_id, w.responsavel_id) end as resp
  ) x
$$;

-- A carga diária de um cenário (ver o cabeçalho).
create or replace function central.carga_cenario(
  p_cenario bigint, p_wi bigint default null, p_it text default null, p_resp bigint default null
) returns table (funcionario_id bigint, data date, horas_disponiveis numeric, horas_alocadas numeric, conflito boolean)
language sql stable set search_path = '' as $$
  with movidos as (
    select * from central.plano_cenario(p_cenario, p_wi, p_it, p_resp)
    where movido and estado <> 'Concluido' and horas > 0
  ),
  pontas as (
    select work_item_id, resp_base as pessoa, it_base as it, -horas as horas
    from movidos where resp_base is not null and it_base is not null
    union all
    select work_item_id, resp_cen, it_cen, horas
    from movidos where resp_cen is not null and it_cen is not null
  ),
  dias as (
    select pt.work_item_id, pt.pessoa, pt.horas, g.d::date as data
    from pontas pt
    join public.iteracao i on i.id = pt.it
    join public.funcionario f on f.id = pt.pessoa
    cross join lateral generate_series(i.inicio, i.fim, interval '1 day') g(d)
    where extract(isodow from g.d) < 6
      and not exists (
        select 1 from public.feriado fe
        where fe.calendario_id = coalesce(f.calendario_feriados_id, central.calendario_padrao())
          and fe.data = g.d::date
      )
  ),
  delta as (
    select pessoa as funcionario_id, data, sum(horas / n) as horas
    from (select *, count(*) over (partition by work_item_id, pessoa, sign(horas)) as n from dias) x
    group by 1, 2
  ),
  base as (
    select c.funcionario_id, c.data, c.horas_disponiveis, c.horas_alocadas, c.conflito
    from public.carga_diaria c where c.cenario_id = 1
  )
  select coalesce(b.funcionario_id, d.funcionario_id),
         coalesce(b.data, d.data),
         coalesce(b.horas_disponiveis, 0),
         greatest(0, coalesce(b.horas_alocadas, 0) + coalesce(d.horas, 0)),
         coalesce(b.conflito, false)
           or (coalesce(b.horas_disponiveis, 0) = 0 and coalesce(b.horas_alocadas, 0) + coalesce(d.horas, 0) > 0.01)
  from base b
  full join delta d on d.funcionario_id = b.funcionario_id and d.data = b.data
$$;

-- Por semana (segunda-feira) e pessoa.
create or replace function central.semanas_cenario(
  p_cenario bigint, p_inicio date, p_fim date,
  p_wi bigint default null, p_it text default null, p_resp bigint default null
) returns table (funcionario_id bigint, semana date, disponiveis numeric, alocadas numeric, pct numeric, faixa text)
language sql stable set search_path = '' as $$
  select c.funcionario_id, date_trunc('week', c.data)::date,
         round(sum(c.horas_disponiveis), 1), round(sum(c.horas_alocadas), 1),
         case when sum(c.horas_disponiveis) > 0 then round(100 * sum(c.horas_alocadas) / sum(c.horas_disponiveis)) end,
         central.faixa(sum(c.horas_disponiveis), sum(c.horas_alocadas), bool_or(c.conflito))
  from central.carga_cenario(p_cenario, p_wi, p_it, p_resp) c
  where c.data between p_inicio and p_fim
  group by 1, 2
$$;

-- Por sprint e pessoa (a carga total da pessoa no período da sprint,
-- inclusive o que ela tem em outros projetos).
create or replace function central.sprints_cenario(
  p_cenario bigint, p_wi bigint default null, p_it text default null, p_resp bigint default null
) returns table (funcionario_id bigint, iteracao_id text, disponiveis numeric, alocadas numeric, pct numeric, faixa text)
language sql stable set search_path = '' as $$
  select c.funcionario_id, i.id,
         round(sum(c.horas_disponiveis), 1), round(sum(c.horas_alocadas), 1),
         case when sum(c.horas_disponiveis) > 0 then round(100 * sum(c.horas_alocadas) / sum(c.horas_disponiveis)) end,
         central.faixa(sum(c.horas_disponiveis), sum(c.horas_alocadas), bool_or(c.conflito))
  from central.carga_cenario(p_cenario, p_wi, p_it, p_resp) c
  join public.iteracao i on c.data between i.inicio and i.fim
  group by 1, 2
$$;

/* ------------------------------------------------------------------ */
/* API (cada função devolve o JSON que a tela usa)                     */
/* ------------------------------------------------------------------ */

create or replace function central.api_contexto() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'hoje', central.hoje(),
    'cenarios', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'nome', c.nome, 'descricao', c.descricao, 'base', c.id = 1,
        'alteracoes', (select count(*) from public.alteracao_plano a where a.cenario_id = c.id)
      ) order by c.id), '[]'::jsonb) from public.cenario c),
    'projetos', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.nome, 'origem', p.origem, 'estado', p.estado
      ) order by p.nome), '[]'::jsonb) from public.projeto p),
    'equipes', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'nome', e.nome, 'projeto', e.projeto_id
      ) order by e.nome), '[]'::jsonb) from public.equipe e),
    'sincronizacao', (select coalesce(jsonb_agg(jsonb_build_object(
        'projeto', s.projeto_id, 'estado', s.estado,
        'em', coalesce(s.concluido_em, s.iniciado_em), 'detalhes', s.detalhes
      ) order by s.projeto_id), '[]'::jsonb)
      from (select distinct on (projeto_id) * from public.execucao_sync order by projeto_id, iniciado_em desc) s)
  )
$$;

-- Heatmap: pessoas x semanas.
create or replace function central.api_heatmap(p_cenario bigint, p_inicio date, p_semanas int) returns jsonb
language sql stable set search_path = '' as $$
  with janela as (
    select date_trunc('week', coalesce(p_inicio, central.hoje() - 14))::date as ini,
           least(greatest(coalesce(p_semanas, 10), 1), 26) as n
  ),
  limites as (select ini, ini + n * 7 - 1 as fim from janela),
  s as (select * from central.semanas_cenario(p_cenario, (select ini from limites), (select fim from limites))),
  semana_atual as (select date_trunc('week', central.hoje())::date as d)
  select jsonb_build_object(
    'semanas', (select jsonb_agg(to_char(g.d, 'YYYY-MM-DD') order by g.d)
                from limites, generate_series(limites.ini, limites.fim, interval '7 day') g(d)),
    'semanaAtual', (select d from semana_atual),
    'pessoas', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id, 'nome', f.nome, 'cargo', f.cargo,
        'equipes', (select coalesce(jsonb_agg(m.equipe_id order by m.equipe_id), '[]'::jsonb)
                    from public.membro_equipe m where m.funcionario_id = f.id),
        'celulas', (select coalesce(jsonb_object_agg(to_char(x.semana, 'YYYY-MM-DD'), jsonb_build_object(
                      'pct', x.pct, 'faixa', x.faixa, 'alocadas', x.alocadas, 'disponiveis', x.disponiveis)), '{}'::jsonb)
                    from s x where x.funcionario_id = f.id)
      ) order by f.nome), '[]'::jsonb)
      from public.funcionario f where f.id in (select funcionario_id from s)),
    'resumo', (select jsonb_build_object(
        'sobrecarregados', count(*) filter (where faixa = 'Sobrecarregado'),
        'emRisco', count(*) filter (where faixa = 'Em risco'),
        'ociosos', count(*) filter (where faixa = 'Ocioso'),
        'conflitos', count(*) filter (where faixa = 'Conflito'),
        'saudaveis', count(*) filter (where faixa = 'Saudavel'),
        'media', round(avg(pct)))
      from s where s.semana = (select d from semana_atual))
  )
$$;

-- Timeline de um projeto: sprints x pessoas, com os itens e a carga de cada um.
create or replace function central.api_timeline(p_cenario bigint, p_projeto text) returns jsonb
language sql stable set search_path = '' as $$
  with plano as (
    select p.*, w.titulo, w.tipo, w.origem
    from central.plano_cenario(p_cenario) p join public.work_item w on w.id = p.work_item_id
    where p.projeto_id = p_projeto
  ),
  sprints as (select * from public.iteracao where projeto_id = p_projeto),
  periodo as (select min(inicio) as ini, max(fim) as fim from sprints),
  pessoas as (
    select m.funcionario_id as id from public.membro_equipe m
    join public.equipe e on e.id = m.equipe_id where e.projeto_id = p_projeto
    union
    select resp_cen from plano where resp_cen is not null
  ),
  uso as (
    select * from central.sprints_cenario(p_cenario) u
    where u.iteracao_id in (select id from sprints) and u.funcionario_id in (select id from pessoas)
  )
  select jsonb_build_object(
    'projeto', (select jsonb_build_object('id', p.id, 'nome', p.nome, 'origem', p.origem, 'estado', p.estado)
                from public.projeto p where p.id = p_projeto),
    'sprints', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'nome', s.nome, 'inicio', s.inicio, 'fim', s.fim, 'encerrada', s.fim < central.hoje()
      ) order by s.inicio), '[]'::jsonb) from sprints s),
    'pessoas', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id, 'nome', f.nome, 'cargo', f.cargo,
        'equipes', (select coalesce(jsonb_agg(e.nome order by e.nome), '[]'::jsonb)
                    from public.membro_equipe m join public.equipe e on e.id = m.equipe_id
                    where m.funcionario_id = f.id and e.projeto_id = p_projeto),
        'uso', (select coalesce(jsonb_object_agg(u.iteracao_id, jsonb_build_object(
                  'pct', u.pct, 'faixa', u.faixa, 'alocadas', u.alocadas, 'disponiveis', u.disponiveis)), '{}'::jsonb)
                from uso u where u.funcionario_id = f.id),
        'ausencias', (select coalesce(jsonb_agg(jsonb_build_object(
                  'inicio', a.inicio, 'fim', a.fim, 'motivo', a.motivo, 'horasDia', a.horas_dia
                ) order by a.inicio), '[]'::jsonb)
                from public.ausencia a, periodo
                where (a.funcionario_id = f.id
                       or a.equipe_id in (select m.equipe_id from public.membro_equipe m where m.funcionario_id = f.id))
                  and a.fim >= periodo.ini and a.inicio <= periodo.fim)
      ) order by f.nome), '[]'::jsonb)
      from public.funcionario f where f.id in (select id from pessoas)),
    'itens', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.work_item_id, 'titulo', p.titulo, 'tipo', p.tipo, 'estado', p.estado,
        'esforco', p.horas, 'origem', p.origem,
        'sprint', p.it_cen, 'responsavel', p.resp_cen, 'movido', p.movido,
        'sprintOriginal', p.it_base, 'responsavelOriginal', p.resp_base
      ) order by p.work_item_id), '[]'::jsonb) from plano p),
    'feriados', (select coalesce(jsonb_agg(jsonb_build_object('data', fe.data, 'nome', fe.nome) order by fe.data), '[]'::jsonb)
                 from public.feriado fe, periodo
                 where fe.calendario_id = central.calendario_padrao()
                   and fe.data between periodo.ini and periodo.fim and extract(isodow from fe.data) < 6)
  )
$$;

-- Simulação: o que muda se o item for para (sprint, pessoa), sem gravar.
create or replace function central.api_simular(p_cenario bigint, p_wi bigint, p_it text, p_resp bigint) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  w public.work_item;
  it_atual text;
  resp_atual bigint;
  alvo public.iteracao;
  pessoa public.funcionario;
  bloqueio text;
  avisos jsonb := '[]'::jsonb;
  impacto jsonb;
begin
  select * into w from public.work_item where id = p_wi;
  if w.id is null then
    return jsonb_build_object('erro', 'Item não encontrado.');
  end if;
  if not exists (select 1 from public.cenario where id = p_cenario) then
    return jsonb_build_object('erro', 'Cenário não encontrado.');
  end if;

  select pc.it_cen, pc.resp_cen into it_atual, resp_atual
  from central.plano_cenario(p_cenario) pc where pc.work_item_id = p_wi;

  select * into alvo from public.iteracao where id = p_it;
  select * into pessoa from public.funcionario where id = p_resp and ativo;

  if alvo.id is null then
    bloqueio := 'Sprint de destino não encontrada.';
  elsif pessoa.id is null then
    bloqueio := 'Pessoa de destino não encontrada.';
  elsif alvo.projeto_id <> w.projeto_id then
    bloqueio := 'A sprint de destino é de outro projeto.';
  elsif w.estado = 'Concluido' then
    bloqueio := 'Item concluído não muda de lugar.';
  elsif alvo.fim < central.hoje() then
    bloqueio := 'A sprint de destino já terminou.';
  elsif p_it = it_atual and p_resp is not distinct from resp_atual then
    bloqueio := 'O item já está nesse lugar.';
  end if;

  if alvo.id is not null and pessoa.id is not null then
    if not exists (
      select 1 from public.membro_equipe m
      join public.equipe_iteracao ei on ei.equipe_id = m.equipe_id
      where m.funcionario_id = pessoa.id and ei.iteracao_id = alvo.id
    ) then
      avisos := avisos || jsonb_build_array(jsonb_build_object('tipo', 'EQUIPE',
        'mensagem', pessoa.nome || ' não faz parte de nenhuma equipe da ' || alvo.nome || '.'));
    end if;

    avisos := avisos || coalesce((
      select jsonb_agg(jsonb_build_object('tipo', 'AUSENCIA', 'mensagem',
        coalesce(e.nome || ': ', '') || a.motivo || ' de ' || to_char(a.inicio, 'DD/MM')
        || case when a.fim > a.inicio then ' a ' || to_char(a.fim, 'DD/MM') else '' end
        || ' — dentro da ' || alvo.nome || '.') order by a.inicio)
      from public.ausencia a left join public.equipe e on e.id = a.equipe_id
      where (a.funcionario_id = pessoa.id
             or a.equipe_id in (select m.equipe_id from public.membro_equipe m where m.funcionario_id = pessoa.id))
        and a.inicio <= alvo.fim and a.fim >= alvo.inicio
    ), '[]'::jsonb);

    avisos := avisos || coalesce((
      select jsonb_agg(jsonb_build_object('tipo', 'FERIADO', 'mensagem',
        fe.nome || ' (' || to_char(fe.data, 'DD/MM') || ') cai dentro da ' || alvo.nome || '.') order by fe.data)
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
    'avisos', avisos,
    'impacto', coalesce(impacto, '[]'::jsonb)
  );
end
$$;

-- Grava a mudança no cenário (nunca no baseline). Voltar ao lugar original apaga a alteração.
create or replace function central.api_mover(p_cenario bigint, p_wi bigint, p_it text, p_resp bigint) returns jsonb
language plpgsql set search_path = '' as $$
declare
  sim jsonb;
  w public.work_item;
begin
  if p_cenario = 1 then
    return jsonb_build_object('erro', 'O cenário baseline é o estado real e não muda. Escolha um cenário de simulação para mover itens.');
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

-- Desfaz a mudança de um item num cenário (volta ao lugar do baseline).
create or replace function central.api_desfazer(p_cenario bigint, p_wi bigint) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if p_cenario = 1 then
    return jsonb_build_object('erro', 'O cenário baseline não tem mudanças para desfazer.');
  end if;
  delete from public.alteracao_plano where cenario_id = p_cenario and work_item_id = p_wi;
  return jsonb_build_object('salvo', true);
end
$$;

-- Alertas: os registrados pelo time e os calculados agora a partir do plano do cenário.
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
    select 'registrado'::text as origem, al.tipo, al.funcionario_id, al.data, al.mensagem
    from public.alerta al where al.cenario_id = p_cenario
  ),
  sobrecarga as (
    select 'calculado'::text, 'SOBRECARGA'::text, s.funcionario_id, min(s.semana),
           'Chega a ' || max(s.pct) || '% de utilização'
           || case when count(*) > 1 then ' em ' || count(*) || ' semanas' else '' end
           || ', a partir da semana de ' || to_char(min(s.semana), 'DD/MM') || '.'
    from semanas s where s.faixa = 'Sobrecarregado' group by s.funcionario_id
  ),
  conflito as (
    select 'calculado'::text, 'CONFLITO'::text, c.funcionario_id, min(c.data),
           'Tem mais trabalho do que horas disponíveis (ou trabalho em dia sem disponibilidade) em '
           || count(*) || case when count(*) = 1 then ' dia' else ' dias' end
           || ', a partir de ' || to_char(min(c.data), 'DD/MM') || '.'
    from carga c where c.conflito group by c.funcionario_id
  ),
  ausencia as (
    select 'calculado'::text, 'AUSENCIA'::text, a.funcionario_id, a.inicio,
           a.motivo || ' de ' || to_char(a.inicio, 'DD/MM')
           || case when a.fim > a.inicio then ' a ' || to_char(a.fim, 'DD/MM') else '' end
           || ' durante a ' || i.nome || ' (' || pr.nome || '), com ' || count(p.work_item_id)
           || case when count(p.work_item_id) = 1 then ' item em aberto.' else ' itens em aberto.' end
    from public.ausencia a
    join plano p on p.resp_cen = a.funcionario_id
    join public.iteracao i on i.id = p.it_cen
    join public.projeto pr on pr.id = i.projeto_id
    where a.funcionario_id is not null and a.fim >= (select dia from h)
      and a.inicio <= i.fim and a.fim >= i.inicio
    group by a.id, a.funcionario_id, a.inicio, a.fim, a.motivo, i.id, i.nome, pr.nome
  ),
  ausencia_equipe as (
    select 'calculado'::text, 'AUSENCIA'::text, null::bigint, a.inicio,
           a.motivo || ' (' || e.nome || ') em ' || to_char(a.inicio, 'DD/MM')
           || case when a.fim > a.inicio then ' a ' || to_char(a.fim, 'DD/MM') else '' end
           || ': ' || a.horas_dia || 'h por dia a menos para cada pessoa da equipe.'
    from public.ausencia a join public.equipe e on e.id = a.equipe_id
    where a.fim >= (select dia from h)
  ),
  feriado as (
    select 'calculado'::text, 'FERIADO'::text, null::bigint, fe.data,
           fe.nome || ' (' || to_char(fe.data, 'DD/MM') || ') cai dentro da '
           || string_agg(distinct i.nome || ' do ' || pr.nome, ', ') || ': um dia útil a menos.'
    from public.feriado fe
    join public.iteracao i on fe.data between i.inicio and i.fim
    join public.projeto pr on pr.id = i.projeto_id
    where fe.calendario_id = central.calendario_padrao()
      and fe.data between (select dia from h) and (select fim from jf)
      and extract(isodow from fe.data) < 6
    group by fe.data, fe.nome
  ),
  sobreposicao as (
    select 'calculado'::text, 'SOBREPOSICAO'::text, p1.resp_cen, greatest(i1.inicio, i2.inicio),
           'Tem itens em aberto em dois projetos ao mesmo tempo: ' || i1.nome || ' (' || pr1.nome || ') e '
           || i2.nome || ' (' || pr2.nome || ').'
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
           'origem', c.origem, 'tipo', c.tipo, 'gravidade', c.gravidade,
           'pessoa', c.funcionario_id, 'nome', f.nome, 'data', c.data, 'mensagem', c.mensagem
         ) order by case c.gravidade when 'alta' then 1 when 'media' then 2 else 3 end, c.data, f.nome), '[]'::jsonb)
  from classificados c left join public.funcionario f on f.id = c.funcionario_id
$$;

/* ---------- Rotas mais enxutas, pensadas para o agente IPORT AI ---------- */

-- Quem tem folga: utilização e horas livres por semana (esta e as duas seguintes).
create or replace function central.api_disponibilidade(p_cenario bigint) returns jsonb
language sql stable set search_path = '' as $$
  with h as (select date_trunc('week', central.hoje())::date as semana),
  s as (select * from central.semanas_cenario(p_cenario, (select semana from h), (select semana from h) + 20))
  select jsonb_build_object(
    'semanas', (select jsonb_agg(to_char((select semana from h) + k * 7, 'YYYY-MM-DD') order by k) from generate_series(0, 2) k),
    'pessoas', (select coalesce(jsonb_agg(jsonb_build_object(
        'nome', f.nome, 'cargo', f.cargo,
        'equipes', (select coalesce(jsonb_agg(e.nome order by e.nome), '[]'::jsonb)
                    from public.membro_equipe m join public.equipe e on e.id = m.equipe_id where m.funcionario_id = f.id),
        'semanas', (select jsonb_agg(jsonb_build_object(
                      'semana', x.semana, 'utilizacao', x.pct, 'faixa', x.faixa,
                      'horasLivres', greatest(0, x.disponiveis - x.alocadas)) order by x.semana)
                    from s x where x.funcionario_id = f.id)
      ) order by f.nome), '[]'::jsonb)
      from public.funcionario f where f.id in (select funcionario_id from s))
  )
$$;

-- Itens em aberto, com projeto, sprint e responsável (já com as mudanças do cenário).
create or replace function central.api_itens(p_cenario bigint) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.work_item_id, 'titulo', w.titulo, 'tipo', w.tipo, 'estado', p.estado, 'esforcoHoras', p.horas,
           'projeto', pr.nome, 'sprint', i.nome, 'sprintInicio', i.inicio, 'sprintFim', i.fim,
           'responsavel', f.nome, 'movidoNoCenario', p.movido
         ) order by pr.nome, i.inicio, w.titulo), '[]'::jsonb)
  from central.plano_cenario(p_cenario) p
  join public.work_item w on w.id = p.work_item_id
  join public.projeto pr on pr.id = p.projeto_id
  left join public.iteracao i on i.id = p.it_cen
  left join public.funcionario f on f.id = p.resp_cen
  where p.estado <> 'Concluido'
$$;

-- Ausências (a partir de uma semana atrás) e feriados dos próximos 120 dias.
create or replace function central.api_calendario() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'hoje', central.hoje(),
    'ausencias', (select coalesce(jsonb_agg(jsonb_build_object(
        'quem', coalesce(f.nome, 'Equipe ' || e.nome), 'inicio', a.inicio, 'fim', a.fim,
        'motivo', a.motivo, 'horasPorDia', a.horas_dia
      ) order by a.inicio), '[]'::jsonb)
      from public.ausencia a
      left join public.funcionario f on f.id = a.funcionario_id
      left join public.equipe e on e.id = a.equipe_id
      where a.fim >= central.hoje() - 7),
    'feriados', (select coalesce(jsonb_agg(jsonb_build_object('data', fe.data, 'nome', fe.nome) order by fe.data), '[]'::jsonb)
      from public.feriado fe
      where fe.calendario_id = central.calendario_padrao()
        and fe.data between central.hoje() and central.hoje() + 120)
  )
$$;

-- Equipes, coordenadores, membros e sprints de cada projeto.
create or replace function central.api_equipes() returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'equipe', e.nome, 'projeto', pr.nome, 'coordenador', c.nome,
           'membros', (select coalesce(jsonb_agg(f.nome || ' (' || f.cargo || ')' order by f.nome), '[]'::jsonb)
                       from public.membro_equipe m join public.funcionario f on f.id = m.funcionario_id
                       where m.equipe_id = e.id),
           'sprints', (select coalesce(jsonb_agg(i.nome || ': ' || to_char(i.inicio, 'DD/MM') || ' a ' || to_char(i.fim, 'DD/MM') order by i.inicio), '[]'::jsonb)
                       from public.equipe_iteracao ei join public.iteracao i on i.id = ei.iteracao_id
                       where ei.equipe_id = e.id)
         ) order by pr.nome, e.nome), '[]'::jsonb)
  from public.equipe e
  join public.projeto pr on pr.id = e.projeto_id
  left join public.funcionario c on c.id = e.coordenador_id
$$;

revoke all on all functions in schema central from public;

-- Conferência rápida.
select
  (select jsonb_array_length(central.api_contexto() -> 'cenarios'))                        as cenarios,
  (select jsonb_array_length(central.api_heatmap(1, null, 10) -> 'pessoas'))               as pessoas_heatmap,
  (select central.api_heatmap(1, null, 10) -> 'resumo')                                   as resumo_semana,
  (select jsonb_array_length(central.api_timeline(1, 'PRJ-CENTRAL') -> 'itens'))           as itens_central,
  (select jsonb_array_length(central.api_alertas(1)))                                       as alertas_baseline,
  (select jsonb_array_length(central.api_alertas(2)))                                       as alertas_cenario2,
  (select jsonb_array_length(central.api_itens(1)))                                         as itens_abertos;
