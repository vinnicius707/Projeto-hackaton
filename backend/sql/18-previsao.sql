-- =====================================================================
-- Projeto Atlas — previsão de sobrecarga (2026-10-09).
--
-- A pergunta: "quem vai estourar, quando, e o que fazer antes?".
--
-- O modelo (simples de explicar numa frase): trabalho que não cabe num
-- dia não some, ele passa para os dias seguintes da mesma pessoa.
--   * cada pessoa aguenta até 120% das horas disponíveis do dia (o teto
--     da faixa "Em risco": hora extra possível, mas sem folga);
--   * o que passar disso — ou o que cai num dia de ausência — vira
--     trabalho acumulado e chega no dia útil seguinte;
--   * a simulação começa na segunda-feira desta semana, com zero
--     acumulado, e vai até o último dia com carga planejada.
-- Carga prevista da semana = o planejado da semana + o que chegou
-- acumulado das semanas de antes. A faixa é a mesma do heatmap.
--
-- Vale para qualquer cenário: mover um item no Planejamento muda a
-- previsão daquele cenário.
--
-- Para cada pessoa em risco a API diz: a primeira semana em risco, o
-- pico, as horas acumuladas, a tendência, as causas (ausência, plano
-- acima da capacidade, acúmulo, feriado) e uma sugestão — o item em
-- aberto dela que mais pesa e quem da equipe da sprint tem a menor
-- carga para recebê-lo (o app abre a simulação no Planejamento).
--
-- Nenhum cifrão seguido de número neste arquivo.
-- =====================================================================

create or replace function central.previsao_cenario(p_cenario bigint, p_teto numeric default 1.2)
returns table (
  funcionario_id bigint, data date, disponiveis numeric, planejadas numeric,
  acumulado_antes numeric, feitas numeric, acumulado numeric, conflito boolean
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  r record;
  pessoa bigint := null;
  acum numeric := 0;
  demanda numeric;
begin
  for r in
    select c.funcionario_id as f, c.data as d, c.horas_disponiveis as disp, c.horas_alocadas as aloc, c.conflito as cf
    from central.carga_cenario(p_cenario) c
    where c.data >= date_trunc('week', central.hoje())::date
    order by c.funcionario_id, c.data
  loop
    if pessoa is distinct from r.f then
      pessoa := r.f;
      acum := 0;
    end if;
    demanda := r.aloc + acum;
    funcionario_id := r.f;
    data := r.d;
    disponiveis := r.disp;
    planejadas := r.aloc;
    acumulado_antes := acum;
    feitas := least(demanda, r.disp * p_teto);
    acum := demanda - feitas;
    acumulado := acum;
    conflito := r.cf;
    return next;
  end loop;
end
$$;

create or replace function central.api_previsao(p_cenario bigint) returns jsonb
language sql stable set search_path = '' as $$
  with h as (select central.hoje() as dia, date_trunc('week', central.hoje())::date as semana),
  membros as (select distinct m.funcionario_id from public.membro_equipe m),
  -- O horizonte: esta semana e as 7 seguintes (o mesmo dos alertas).
  dia as (
    select p.* from central.previsao_cenario(p_cenario) p
    where p.funcionario_id in (select funcionario_id from membros)
      and p.data < (select semana from h) + 8 * 7
  ),
  sem as (
    select d.funcionario_id, date_trunc('week', d.data)::date as semana,
           round(sum(d.disponiveis), 1) as disp,
           round(sum(d.planejadas), 1) as plano,
           round((array_agg(d.acumulado_antes order by d.data))[1], 1) as chega,
           round((array_agg(d.acumulado order by d.data desc))[1], 1) as acum_fim,
           bool_or(d.conflito) as conflito
    from dia d group by 1, 2
  ),
  -- Na previsão, o conflito de um dia só não pinta a semana: o trabalho
  -- daquele dia já foi levado para os dias seguintes. Fica "Conflito" a
  -- semana sem nenhuma hora disponível e com trabalho.
  semf0 as (
    select s.*, s.plano + s.chega as prevista,
           case when s.disp > 0 then round(100 * s.plano / s.disp) end as pct_plano,
           case when s.disp > 0 then round(100 * (s.plano + s.chega) / s.disp) end as pct,
           central.faixa(s.disp, s.plano, s.conflito) as faixa_plano,
           central.faixa(s.disp, s.plano + s.chega, false) as faixa
    from sem s
  ),
  -- Gravidade: 2 = sobrecarregado ou em conflito, 1 = em risco, 0 = ok.
  semf as (
    select s.*, case when s.faixa in ('Sobrecarregado', 'Conflito') then 2 when s.faixa = 'Em risco' then 1 else 0 end as grav
    from semf0 s
  ),
  -- Uso de cada pessoa em cada sprint (para escolher quem recebe um item).
  uso_sprint as (select * from central.sprints_cenario(p_cenario)),
  plano as (
    select pc.*, i.nome as sprint_nome, i.inicio as sprint_inicio, i.fim as sprint_fim, w.titulo
    from central.plano_cenario(p_cenario) pc
    join public.iteracao i on i.id = pc.it_cen
    join public.work_item w on w.id = pc.work_item_id
    where pc.estado <> 'Concluido' and pc.resp_cen is not null and pc.horas > 0
      and i.fim >= (select dia from h)
  ),
  pessoa as (
    select f.id, f.nome, f.cargo, f.calendario_feriados_id,
      coalesce((select s.grav from semf s where s.funcionario_id = f.id and s.semana = (select semana from h)), 0) as grav_agora,
      coalesce((select max(s.grav) from semf s where s.funcionario_id = f.id), 0) as grav_max,
      (select min(s.semana) from semf s where s.funcionario_id = f.id and s.grav > 0) as primeira,
      coalesce((select round(max(d.acumulado), 1) from dia d where d.funcionario_id = f.id), 0) as acum_max,
      coalesce((select round((array_agg(d.acumulado order by d.data desc))[1], 1) from dia d where d.funcionario_id = f.id), 0) as acum_fim,
      (select round(regr_slope(s.pct, (s.semana - (select semana from h)) / 7.0)::numeric, 1)
         from semf s where s.funcionario_id = f.id and s.pct is not null) as inclinacao
    from public.funcionario f
    where f.id in (select funcionario_id from membros)
      and f.id in (select funcionario_id from dia)
  ),
  pessoa2 as (
    select p.*,
      case p.grav_max when 2 then 'alta' when 1 then 'media' else 'ok' end as nivel,
      p.grav_agora > 0 as agora,
      p.grav_max > p.grav_agora as piora,
      -- A primeira semana pior que esta (para quem vai piorar), ou a primeira em risco.
      coalesce((select min(s.semana) from semf s where s.funcionario_id = p.id and s.grav > p.grav_agora), p.primeira) as quando,
      -- O dia em que o acumulado volta a zero (null: não acumulou, ou não volta no horizonte).
      (select min(d.data) from dia d where d.funcionario_id = p.id and d.acumulado < 0.05
         and d.data > (select min(d2.data) from dia d2 where d2.funcionario_id = p.id and d2.acumulado >= 0.05)) as normaliza
    from pessoa p
  ),
  -- A sugestão: o item em aberto da primeira sprint em risco (o maior), para
  -- quem tem a menor carga naquela sprint — de preferência da mesma equipe,
  -- se alguém ali estiver abaixo de 100%.
  sugestao as (
    select p.id as pessoa_id, it.work_item_id, it.titulo, it.horas, it.it_cen, it.sprint_nome, it.projeto_id,
           dest.funcionario_id as dest_id, dest.nome as dest_nome, dest.pct as dest_pct, dest.faixa as dest_faixa,
           dest.mesma_equipe
    from pessoa2 p
    cross join lateral (
      select pl.* from plano pl
      where pl.resp_cen = p.id and pl.sprint_fim >= p.quando
      order by pl.sprint_inicio, pl.horas desc, pl.work_item_id
      limit 1
    ) it
    cross join lateral (
      select u.funcionario_id, f2.nome, u.pct, u.faixa,
             exists (select 1 from public.membro_equipe m1 join public.membro_equipe m2 on m2.equipe_id = m1.equipe_id
                     where m1.funcionario_id = p.id and m2.funcionario_id = u.funcionario_id) as mesma_equipe
      from (select distinct m.funcionario_id from public.equipe_iteracao ei
            join public.membro_equipe m on m.equipe_id = ei.equipe_id
            where ei.iteracao_id = it.it_cen and m.funcionario_id <> p.id) c
      join public.funcionario f2 on f2.id = c.funcionario_id and f2.ativo
      join uso_sprint u on u.funcionario_id = c.funcionario_id and u.iteracao_id = it.it_cen
      where u.pct is not null and u.pct < 100
      order by case when exists (select 1 from public.membro_equipe m1 join public.membro_equipe m2 on m2.equipe_id = m1.equipe_id
                                 where m1.funcionario_id = p.id and m2.funcionario_id = u.funcionario_id) then 0 else 1 end,
               u.pct, f2.nome
      limit 1
    ) dest
    where p.nivel <> 'ok'
  )
  select jsonb_build_object(
    'hoje', (select dia from h),
    'semanaAtual', (select semana from h),
    'teto', 120,
    'ate', (select max(d.data) from dia d),
    'semanas', (select coalesce(jsonb_agg(x.semana order by x.semana), '[]'::jsonb)
                from (select distinct semana from semf) x),
    'equipe', (select coalesce(jsonb_agg(jsonb_build_object(
                  'semana', x.semana, 'disponiveis', x.disp, 'planejadas', x.plano, 'previstas', x.prev,
                  'pctPlano', case when x.disp > 0 then round(100 * x.plano / x.disp) end,
                  'pct', case when x.disp > 0 then round(100 * x.prev / x.disp) end) order by x.semana), '[]'::jsonb)
               from (select semana, sum(disp) as disp, sum(plano) as plano, sum(prevista) as prev from semf group by 1) x),
    'resumo', (select jsonb_build_object(
                  'alta', count(*) filter (where nivel = 'alta'),
                  'media', count(*) filter (where nivel = 'media'),
                  'pioram', count(*) filter (where piora),
                  'horasAcumuladas', coalesce(sum(acum_max), 0),
                  'primeiro', (select jsonb_build_object('pessoa', p.id, 'nome', p.nome, 'semana', p.quando, 'nivel', p.nivel)
                               from pessoa2 p where p.piora
                               order by p.quando, p.grav_max desc, p.nome limit 1))
               from pessoa2),
    'pessoas', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.nome, 'cargo', p.cargo,
        'equipes', (select coalesce(jsonb_agg(m.equipe_id order by m.equipe_id), '[]'::jsonb)
                    from public.membro_equipe m where m.funcionario_id = p.id),
        'nivel', p.nivel,
        'agora', p.agora,
        'piora', p.piora,
        'primeira', p.primeira,
        'quando', p.quando,
        'faixaAgora', (select s.faixa from semf s where s.funcionario_id = p.id and s.semana = (select semana from h)),
        'pico', (select jsonb_build_object('pct', s.pct, 'semana', s.semana, 'faixa', s.faixa)
                 from semf s where s.funcionario_id = p.id
                 order by s.pct desc nulls last, s.grav desc, s.semana limit 1),
        'semanasConflito', (select coalesce(jsonb_agg(s.semana order by s.semana), '[]'::jsonb)
                            from semf s where s.funcionario_id = p.id and s.faixa = 'Conflito'),
        'acumuladoMax', p.acum_max,
        'acumuladoFim', p.acum_fim,
        'normaliza', p.normaliza,
        'tendencia', case when p.inclinacao is null then 'estavel'
                          when p.inclinacao > 2 then 'sobe' when p.inclinacao < -2 then 'desce' else 'estavel' end,
        'inclinacao', p.inclinacao,
        'causas', (
            -- Ausências (da pessoa ou da equipe) que batem com trabalho planejado
            -- ou caem numa semana em risco.
            coalesce((select jsonb_agg(jsonb_build_object(
                'codigo', case when a.equipe_id is null then 'AUSENCIA' else 'AUSENCIA_EQUIPE' end,
                'dados', jsonb_build_object('motivo', a.motivo, 'equipe', e.nome, 'inicio', a.inicio, 'fim', a.fim,
                  'horas', (select round(sum(greatest(0, d.planejadas - d.disponiveis)), 1) from dia d
                            where d.funcionario_id = p.id and d.data between a.inicio and a.fim))) order by a.inicio)
              from public.ausencia a left join public.equipe e on e.id = a.equipe_id
              where (a.funcionario_id = p.id
                     or a.equipe_id in (select m.equipe_id from public.membro_equipe m where m.funcionario_id = p.id))
                and a.fim >= (select semana from h)
                and a.inicio <= (select max(d.data) from dia d where d.funcionario_id = p.id)
                and (exists (select 1 from dia d where d.funcionario_id = p.id and d.data between a.inicio and a.fim
                               and d.planejadas > d.disponiveis)
                     or exists (select 1 from semf s where s.funcionario_id = p.id and s.grav > 0
                                  and a.inicio <= s.semana + 6 and a.fim >= s.semana))), '[]'::jsonb)
            -- O próprio plano já passa da capacidade.
            || coalesce((select jsonb_build_array(jsonb_build_object('codigo', 'PLANO_ACIMA',
                  'dados', jsonb_build_object('pct', max(s.pct_plano), 'semanas', count(*))))
                from semf s where s.funcionario_id = p.id and s.pct_plano > 100
                having count(*) > 0), '[]'::jsonb)
            -- Trabalho que não cabe nem com 120% e vai se acumulando.
            || case when p.acum_max >= 1 then jsonb_build_array(jsonb_build_object('codigo', 'ACUMULO',
                  'dados', jsonb_build_object('horas', p.acum_max, 'normaliza', p.normaliza, 'fim', p.acum_fim)))
               else '[]'::jsonb end
            -- Feriados na semana em que o risco começa.
            || coalesce((select jsonb_agg(jsonb_build_object('codigo', 'FERIADO',
                  'dados', jsonb_build_object('feriado', fe.nome, 'data', fe.data)) order by fe.data)
                from public.feriado fe
                where p.quando is not null
                  and fe.calendario_id = coalesce(p.calendario_feriados_id, central.calendario_padrao())
                  and fe.data between p.quando and p.quando + 4), '[]'::jsonb)
        ),
        'sugestao', (select jsonb_build_object(
                       'item', jsonb_build_object('id', sg.work_item_id, 'titulo', sg.titulo, 'esforco', sg.horas,
                                                  'sprint', sg.it_cen, 'sprintNome', sg.sprint_nome, 'projeto', sg.projeto_id),
                       'para', jsonb_build_object('id', sg.dest_id, 'nome', sg.dest_nome, 'pct', sg.dest_pct, 'faixa', sg.dest_faixa,
                                                  'mesmaEquipe', sg.mesma_equipe))
                     from sugestao sg where sg.pessoa_id = p.id),
        'semanas', (select coalesce(jsonb_object_agg(to_char(s.semana, 'YYYY-MM-DD'), jsonb_build_object(
                      'disponiveis', s.disp, 'planejadas', s.plano, 'chega', s.chega, 'acumulado', s.acum_fim,
                      'pctPlano', s.pct_plano, 'faixaPlano', s.faixa_plano, 'pct', s.pct, 'faixa', s.faixa)), '{}'::jsonb)
                    from semf s where s.funcionario_id = p.id)
      ) order by case p.nivel when 'alta' then 1 when 'media' then 2 else 3 end, p.piora desc, p.quando nulls last, p.nome), '[]'::jsonb)
      from pessoa2 p)
  )
$$;

revoke all on all functions in schema central from public;

select
  (select central.api_previsao(1) -> 'resumo') as resumo,
  (select central.api_previsao(1) -> 'equipe') as equipe,
  (select jsonb_agg(jsonb_build_object('nome', x ->> 'nome', 'nivel', x ->> 'nivel', 'agora', x -> 'faixaAgora',
          'piora', x -> 'piora', 'quando', x -> 'quando', 'pico', x -> 'pico', 'acum', x -> 'acumuladoMax',
          'norm', x -> 'normaliza', 'tend', x -> 'tendencia', 'causas', x -> 'causas', 'sugestao', x -> 'sugestao'))
   from jsonb_array_elements(central.api_previsao(1) -> 'pessoas') x where x ->> 'nivel' <> 'ok') as pessoas,
  (select jsonb_array_length(central.api_previsao(2) -> 'pessoas')) as pessoas_cenario2;
