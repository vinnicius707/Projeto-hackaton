-- A conta 111.111.111-11 é o login admin do time.
update central.usuarios set cargo = 'DIRETOR', admin = true, ativo = true where documento = '11111111111';
select id, documento, nome_completo, cargo, admin, ativo from central.usuarios order by id;
