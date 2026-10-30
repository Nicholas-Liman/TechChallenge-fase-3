
import os
import sys
import logging
from functools import wraps

import psycopg2
import requests
from psycopg2.extras import RealDictCursor
from psycopg2.pool import SimpleConnectionPool
from flask import Flask, request, jsonify
from dotenv import load_dotenv

# Configura o logging
logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# Carrega .env para desenvolvimento local
load_dotenv()

app = Flask(__name__)

# Configuração
DATABASE_URL = os.getenv("DATABASE_URL")
AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL")

if not DATABASE_URL or not AUTH_SERVICE_URL:
    log.critical("Erro: DATABASE_URL e AUTH_SERVICE_URL devem ser definidos.")
    sys.exit(1)

# Pool de conexão com o banco
try:
    pool = SimpleConnectionPool(1, 5, dsn=DATABASE_URL)
    log.info("Pool de conexões com o PostgreSQL inicializado.")
except psycopg2.OperationalError as e:
    log.critical("Erro fatal ao conectar ao PostgreSQL: %s", e)
    sys.exit(1)


# Middleware de autenticação
def require_auth(f):
    """Valida a chave de API contra o auth-service."""

    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get("Authorization")

        if not auth_header:
            return jsonify({"error": "Authorization header obrigatório"}), 401

        try:
            validate_url = f"{AUTH_SERVICE_URL}/validate"
            response = requests.get(
                validate_url,
                headers={"Authorization": auth_header},
                timeout=3
            )

            if response.status_code != 200:
                log.warning(
                    "Falha na validação da chave (status: %s)",
                    response.status_code
                )
                return jsonify({"error": "Chave de API inválida"}), 401

        except requests.exceptions.Timeout:
            log.error("Timeout ao conectar com o auth-service")
            return jsonify({
                "error": "Serviço de autenticação indisponível (timeout)"
            }), 504

        except requests.exceptions.RequestException as e:
            log.error("Erro ao conectar com o auth-service: %s", e)
            return jsonify({
                "error": "Serviço de autenticação indisponível"
            }), 503

        return f(*args, **kwargs)

    return decorated


# Endpoints da API

@app.route('/health')
def health():
    return jsonify({"status": "ok"})


@app.route('/flags', methods=['POST'])
@require_auth
def create_flag():
    """Cria uma nova definição de feature flag."""
    data = request.get_json()

    if not data or 'name' not in data:
        return jsonify({"error": "'name' é obrigatório"}), 400

    name = data['name']
    description = data.get('description', '')
    is_enabled = data.get('is_enabled', False)

    conn = None
    cur = None

    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            "INSERT INTO flags "
            "(name, description, is_enabled, created_at, updated_at) "
            "VALUES (%s, %s, %s, NOW(), NOW()) RETURNING *",
            (name, description, is_enabled)
        )

        new_flag = cur.fetchone()
        conn.commit()

        log.info("Flag '%s' criada com sucesso.", name)
        return jsonify(new_flag), 201

    except psycopg2.IntegrityError:
        if conn:
            conn.rollback()

        log.warning("Tentativa de criar flag duplicada: '%s'", name)
        return jsonify({"error": f"Flag '{name}' já existe"}), 409

    except Exception as e:
        if conn:
            conn.rollback()

        log.error("Erro ao criar flag: %s", e)
        return jsonify({
            "error": "Erro interno do servidor",
            "details": str(e)
        }), 500

    finally:
        if cur:
            cur.close()
        if conn:
            pool.putconn(conn)


@app.route('/flags', methods=['GET'])
@require_auth
def get_flags():
    """Lista todas as feature flags."""
    conn = None
    cur = None

    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT * FROM flags ORDER BY name")

        flags = cur.fetchall()
        return jsonify(flags)

    except Exception as e:
        log.error("Erro ao buscar flags: %s", e)
        return jsonify({
            "error": "Erro interno do servidor",
            "details": str(e)
        }), 500

    finally:
        if cur:
            cur.close()
        if conn:
            pool.putconn(conn)


@app.route('/flags/<string:name>', methods=['GET'])
@require_auth
def get_flag(name):
    """Busca uma feature flag específica pelo nome."""
    conn = None
    cur = None

    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        cur.execute(
            "SELECT * FROM flags WHERE name = %s",
            (name,)
        )

        flag = cur.fetchone()

        if not flag:
            return jsonify({"error": "Flag não encontrada"}), 404

        return jsonify(flag)

    except Exception as e:
        log.error("Erro ao buscar flag '%s': %s", name, e)
        return jsonify({
            "error": "Erro interno do servidor",
            "details": str(e)
        }), 500

    finally:
        if cur:
            cur.close()
        if conn:
            pool.putconn(conn)


@app.route('/flags/<string:name>', methods=['PUT'])
@require_auth
def update_flag(name):
    """Atualiza a descrição ou o status de uma feature flag."""
    data = request.get_json()

    if not data:
        return jsonify({"error": "Corpo da requisição obrigatório"}), 400

    has_description = "description" in data
    has_is_enabled = "is_enabled" in data

    if not has_description and not has_is_enabled:
        return jsonify({
            "error": (
                "Pelo menos um campo "
                "('description', 'is_enabled') é obrigatório"
            )
        }), 400

    conn = None
    cur = None

    try:
        conn = pool.getconn()
        cur = conn.cursor(cursor_factory=RealDictCursor)

        if has_description and has_is_enabled:
            cur.execute(
                """
                UPDATE flags
                SET description = %s,
                    is_enabled = %s,
                    updated_at = NOW()
                WHERE name = %s
                RETURNING *
                """,
                (data["description"], data["is_enabled"], name)
            )

        elif has_description:
            cur.execute(
                """
                UPDATE flags
                SET description = %s,
                    updated_at = NOW()
                WHERE name = %s
                RETURNING *
                """,
                (data["description"], name)
            )

        else:
            cur.execute(
                """
                UPDATE flags
                SET is_enabled = %s,
                    updated_at = NOW()
                WHERE name = %s
                RETURNING *
                """,
                (data["is_enabled"], name)
            )

        if cur.rowcount == 0:
            return jsonify({"error": "Flag não encontrada"}), 404

        updated_flag = cur.fetchone()
        conn.commit()

        log.info("Flag '%s' atualizada com sucesso.", name)
        return jsonify(updated_flag), 200

    except Exception as e:
        if conn:
            conn.rollback()

        log.error("Erro ao atualizar flag '%s': %s", name, e)
        return jsonify({
            "error": "Erro interno do servidor",
            "details": str(e)
        }), 500

    finally:
        if cur:
            cur.close()
        if conn:
            pool.putconn(conn)


@app.route('/flags/<string:name>', methods=['DELETE'])
@require_auth
def delete_flag(name):
    """Deleta uma feature flag."""
    conn = None
    cur = None

    try:
        conn = pool.getconn()
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM flags WHERE name = %s",
            (name,)
        )

        if cur.rowcount == 0:
            return jsonify({"error": "Flag não encontrada"}), 404

        conn.commit()

        log.info("Flag '%s' deletada com sucesso.", name)
        return "", 204

    except Exception as e:
        if conn:
            conn.rollback()

        log.error("Erro ao deletar flag '%s': %s", name, e)
        return jsonify({
            "error": "Erro interno do servidor",
            "details": str(e)
        }), 500

    finally:
        if cur:
            cur.close()
        if conn:
            pool.putconn(conn)


if __name__ == '__main__':
    port = int(os.getenv("PORT", 8002))
    host = os.getenv("HOST", "127.0.0.1")
    app.run(host=host, port=port, debug=False)
