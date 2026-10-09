-- =====================================================================
-- Projeto Atlas — dados de exemplo: a carga diária passa a descontar as
-- ausências (pedido do usuário em 2026-10-09).
--
-- O problema: a public.carga_diaria do time dava 8h disponíveis em todo
-- dia útil, até nas férias (a Ana Souza aparecia com 8h livres de 13 a
-- 24/10). As ausências estavam gravadas (public.ausencia), mas não
-- chegavam à carga.
--
-- A correção, só no cenário 1 (baseline), a partir da cópia original:
--   horas fora no dia = a soma das ausências da pessoa e das equipes dela
--                       (horas_dia 0, ou maior que a jornada, = o dia todo),
--                       até o limite da jornada;
--   disponíveis       = jornada − horas fora;
--   alocadas          = a rotina do dia encolhe na proporção do tempo fora,
--                       mas os itens em aberto da sprint continuam
--                       pendurados na pessoa (esforço ÷ dias úteis da
--                       sprint, a mesma conta do central.carga_cenario);
--   conflito          = o que o time marcou, ou trabalho em dia sem
--                       nenhuma hora disponível.
-- Ou seja: férias com item em aberto viram conflito, e uma consulta de
-- meio período deixa o dia mais apertado.
--
-- A cópia original fica em central.carga_diaria_original (feita uma vez
-- só). central.restaurar_carga_original() devolve tudo como o time
-- gravou; central.recalcular_carga_baseline() aplica de novo (rodar
-- depois de mudar a public.ausencia).
--
-- Nenhum cifrão seguido de número neste arquivo.
-- =====================================================================

create table if not exists central.carga_diaria_original as
  select * from public.carga_diaria where false;

insert into central.carga_diaria_original
select * from public.carga_diaria
where not exists (select 1 from central.carga_diaria_original);

create unique index if not exists carga_diaria_original_chave
  on central.carga_diaria_original (cenario_id, funcionario_id, data);
alter table central.carga_diaria_original enable row level security;

create or replace function central.recalcular_carga_baseline() returns jsonb
language plpgsql set search_path = '' as $$
declare
  mudadas int;
begin
  with orig as (
    select * from central.carga_diaria_original where cenario_id = 1
  ),
  fora as (
    select o.funcionario_id, o.data,
           least(o.horas_disponiveis, sum(
             case when a.horas_dia <= 0 or a.horas_dia >= o.horas_disponiveis
                  then o.horas_disponiveis else a.horas_dia end)) as horas
    from orig o
    join public.ausencia a
      on o.data between a.inicio and a.fim
     and (a.funcionario_id = o.funcionario_id
          or a.equipe_id in (select m.equipe_id from public.membro_equipe m where m.funcionario_id = o.funcionario_id))
    group by o.funcionario_id, o.data, o.horas_disponiveis
  ),
  itens as (
    select x.pessoa as funcionario_id, x.data, sum(x.horas / x.n) as horas
    from (
      select w.id, w.responsavel_id as pessoa, w.esforco as horas, g.d::date as data,
             count(*) over (partition by w.id) as n
      from public.work_item w
      join public.iteracao i on i.id = w.iteracao_id
      join public.funcionario f on f.id = w.responsavel_id
      cross join lateral generate_series(i.inicio, i.fim, interval '1 day') g(d)
      where w.estado <> 'Concluido' and coalesce(w.esforco, 0) > 0
        and extract(isodow from g.d) < 6
        and not exists (
          select 1 from public.feriado fe
          where fe.calendario_id = coalesce(f.calendario_feriados_id, central.calendario_padrao())
            and fe.data = g.d::date)
    ) x
    group by 1, 2
  ),
  novo as (
    select o.cenario_id, o.funcionario_id, o.data,
           o.horas_disponiveis - coalesce(fo.horas, 0) as disp,
           case when fo.horas is null or o.horas_disponiveis = 0 then o.horas_alocadas
                else round(o.horas_alocadas * (o.horas_disponiveis - fo.horas) / o.horas_disponiveis
                           + coalesce(it.horas, 0) * fo.horas / o.horas_disponiveis, 1)
           end as aloc,
           o.conflito
    from orig o
    left join fora fo on fo.funcionario_id = o.funcionario_id and fo.data = o.data
    left join itens it on it.funcionario_id = o.funcionario_id and it.data = o.data
  ),
  final as (
    select n.*, n.conflito or (n.disp = 0 and n.aloc > 0) as conflito_final from novo n
  )
  update public.carga_diaria c
     set horas_disponiveis = f.disp, horas_alocadas = f.aloc, conflito = f.conflito_final
  from final f
  where c.cenario_id = f.cenario_id and c.funcionario_id = f.funcionario_id and c.data = f.data
    and (c.horas_disponiveis, c.horas_alocadas, c.conflito) is distinct from (f.disp, f.aloc, f.conflito_final);
  get diagnostics mudadas = row_count;

  return jsonb_build_object(
    'linhasMudadas', mudadas,
    'diasComAusencia', (select count(*) from public.carga_diaria c join central.carga_diaria_original o
                          using (cenario_id, funcionario_id, data)
                        where c.cenario_id = 1 and c.horas_disponiveis < o.horas_disponiveis),
    'diasEmConflito', (select count(*) from public.carga_diaria where cenario_id = 1 and conflito));
end
$$;

create or replace function central.restaurar_carga_original() returns jsonb
language plpgsql set search_path = '' as $$
declare
  mudadas int;
begin
  update public.carga_diaria c
     set horas_disponiveis = o.horas_disponiveis, horas_alocadas = o.horas_alocadas, conflito = o.conflito
  from central.carga_diaria_original o
  where c.cenario_id = o.cenario_id and c.funcionario_id = o.funcionario_id and c.data = o.data
    and (c.horas_disponiveis, c.horas_alocadas, c.conflito) is distinct from (o.horas_disponiveis, o.horas_alocadas, o.conflito);
  get diagnostics mudadas = row_count;
  return jsonb_build_object('linhasRestauradas', mudadas);
end
$$;

revoke all on all functions in schema central from public;

select
  (select count(*) from central.carga_diaria_original) as copia_original,
  central.recalcular_carga_baseline() as resultado,
  (select json_agg(x order by x.funcionario_id, x.data) from (
     select c.funcionario_id, c.data, o.horas_disponiveis as disp_antes, c.horas_disponiveis as disp,
            o.horas_alocadas as aloc_antes, c.horas_alocadas as aloc, c.conflito
     from public.carga_diaria c join central.carga_diaria_original o using (cenario_id, funcionario_id, data)
     where c.horas_disponiveis <> o.horas_disponiveis) x) as dias_mudados;
