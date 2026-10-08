# Banco da empresa

O modelo esta definido em [`sqlite_schema.sql`](sqlite_schema.sql). SQLite nao possui o comando
`CREATE DATABASE`: o banco e um arquivo. O inicializador abaixo cria `empresa.db` nesta pasta,
executa o esquema e valida a integridade e as chaves estrangeiras.

```powershell
python iniciar_empresa.py
```

O inicializador exige SQLite 3.37 ou superior e nao sobrescreve um `empresa.db` existente.
Para abrir o banco pelo terminal, use `sqlite3 empresa.db`; em cada conexao, habilite as chaves
estrangeiras com `PRAGMA foreign_keys = ON;`.
