from pathlib import Path
import sqlite3


PASTA = Path(__file__).resolve().parent
ARQUIVO_SCHEMA = PASTA / "sqlite_schema.sql"
ARQUIVO_BANCO = PASTA / "empresa.db"


def validar_banco(conexao):
    if conexao.execute("PRAGMA foreign_keys").fetchone()[0] != 1:
        raise RuntimeError("As chaves estrangeiras nao estao habilitadas.")

    integridade = conexao.execute("PRAGMA integrity_check").fetchone()[0]
    if integridade != "ok":
        raise RuntimeError(f"Falha na verificacao de integridade: {integridade}")

    violacoes_fk = conexao.execute("PRAGMA foreign_key_check").fetchall()
    if violacoes_fk:
        raise RuntimeError(f"Foram encontradas violacoes de chave estrangeira: {violacoes_fk}")


def main():
    if sqlite3.sqlite_version_info < (3, 37, 0):
        raise RuntimeError("Este modelo requer SQLite 3.37 ou superior para suportar tabelas STRICT.")

    if ARQUIVO_BANCO.exists():
        raise FileExistsError(
            f"O banco ja existe: {ARQUIVO_BANCO}. Renomeie-o ou remova-o manualmente se quiser recria-lo."
        )

    esquema = ARQUIVO_SCHEMA.read_text(encoding="utf-8")
    conexao = None
    arquivo_criado = False

    try:
        with ARQUIVO_BANCO.open("xb"):
            arquivo_criado = True

        conexao = sqlite3.connect(ARQUIVO_BANCO)
        conexao.execute("PRAGMA foreign_keys = ON")
        conexao.executescript(esquema)
        validar_banco(conexao)
    except (OSError, sqlite3.Error, RuntimeError):
        if conexao is not None:
            conexao.close()
        if arquivo_criado:
            ARQUIVO_BANCO.unlink()
        raise

    conexao.close()
    print(f"Banco criado e validado: {ARQUIVO_BANCO}")
    print(f"SQLite {sqlite3.sqlite_version}; integrity_check=ok; foreign_key_check=ok.")


if __name__ == "__main__":
    main()
