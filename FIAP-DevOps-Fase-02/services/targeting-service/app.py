
import os
import sys
import logging
from functools import wraps

import psycopg2
import requests
from dotenv import load_dotenv
from flask import Flask, jsonify, request
from psycopg2.extras import Json, RealDictCursor
from psycopg2.pool import SimpleConnectionPool

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s"
)
log = logging.getLogger(__name__)

load_dotenv()

app = Flask(__name__)

DATABASE_URL = os.getenv("DATABASE_URL")
AUTH_SERVICE_URL = os.getenv("AUTH_SERVICE_URL", "").rstrip("/")

if not DATABASE_URL or not AUTH_SERVICE_URL:
    log.critical("DATABASE_URL e AUTH_SERVICE_URL devem ser definidos.")
    sys.exit(1)

try:
    pool = SimpleConnectionPool(1, 5, dsn=DATABASE_URL)
    log.info("Pool PostgreSQL do targeting-service inicializado.")
except psycopg2.OperationalError:
    log.exception("Falha ao inicializar conexão com PostgreSQL.")
    sys.exit(1)


def require_auth(f):
    """Valida a chave de API usando o auth-service."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get("Authorization")

        if not auth_header:
            return jsonify({"error": "Authorization header obrigatório"}), 401

        try:
            response = requests.get(
                f"{AUTH_SERVICE_URL}/validate",
                headers={"Authorization": auth_header},
                timeout=3
            )

            if response.status_code != 200:
                log.warning(
                    "Falha na validação da chave. Status: %s",
                    response.status_code
                )
                return jsonify({"error": "Chave de API inválida"}), 401

        except requests.exceptions.Timeout:
            log.error("Timeout ao conectar com auth-service.")
            return jsonify({
                "error": "Serviço de autenticação indisponível (timeout)"
            }), 504

        except requests.exceptions.RequestException:
            log.exception("Erro de comunicação com auth-service.")
            return jsonify({
                "error": "Serviço de autenticação indisponível"
            }), 503

        finally:
            if "response" in locals():
                response.close()

        return f(*args, **kwargs)

    return decorated


def get_json_body():
    """Obtém e valida um corpo JSON."""
    if not request.is_json:
        return None

    data = request.get_json(silent=True)

    if not isinstance(data, dict):
        return None

    return data


def release_connection(conn, cursor=None, rollback=False):
    """Fecha cursor e devolve conexão ao pool."""
    if cursor is not None:
        try:
            cursor.close()
        except psycopg2.Error:
            log.exception("Erro ao fechar cursor PostgreSQL.")

    if conn is not None:
        try:
            if rollback:
                conn.rollback()

            pool.putconn(conn)
        except psycopg2.Error:
            log.exception("Erro ao devolver conexão ao pool.")
            try:
                pool.putconn(conn, close=True)
            except psycopg2.Error:
                log.exception("Erro ao descartar conexão PostgreSQL.")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/rules", methods=["POST"])
@require_auth
def create_rule():
    """Cria uma nova regra de segmentação."""
    data = get_json_body()

    if not data or "flag_name" not in data or "rules" not in data:
        return jsonify({
            "error": "'flag_name' e 'rules' (JSON) são obrigatórios"
        }), 400

    flag_name = data["flag_name"]
    rules_obj = data["rules"]
    is_enabled = data.get("is_enabled", True)

    if not isinstance(flag_name, str) or not flag_name.strip():
        return jsonify({"error": "flag_name deve ser um texto não vazio"}), 400

    if len(flag_name) > 100:
        return jsonify({"error": "flag_name deve ter no máximo 100 caracteres"}), 400

    if not isinstance(rules_obj, (dict, list)):
        return jsonify({"error": "rules deve ser um objeto ou lista JSON"}), 400

    if not isinstance(is_enabled, bool):
        return jsonify({"error": "is_enabled deve ser booleano"}), 400

    conn = None
    cursor = None
    rollback = False

    try:
        conn = pool.getconn()
        cursor = conn.cursor(cursor_factory=RealDictCursor)

        cursor.execute(
            """
            INSERT INTO targeting_rules
                (flag_name, is_enabled, rules, created_at, updated_at)
            VALUES (%s, %s, %s, NOW(), NOW())
            RETURNING *
            """,
            (flag_name, is_enabled, Json(rules_obj))
        )

        new_rule = cursor.fetchone()
        conn.commit()

        log.info("Regra criada para flag '%s'.", flag_name)
        return jsonify(new_rule), 201

    except psycopg2.IntegrityError:
        rollback = True
        log.warning("Tentativa de criar regra duplicada: '%s'.", flag_name)
        return jsonify({
            "error": "Regra para a flag já existe"
        }), 409

    except psycopg2.Error:
        rollback = True
        log.exception("Erro PostgreSQL ao criar regra.")

        return jsonify({"error": "Erro interno do servidor"}), 500

    except Exception:
        rollback = True
        log.exception("Erro inesperado ao criar regra.")

        return jsonify({"error": "Erro interno do servidor"}), 500

    finally:
        release_connection(conn, cursor, rollback)


@app.route("/rules/<string:flag_name>", methods=["GET"])
@require_auth
def get_rule(flag_name):
    """Busca uma regra pelo nome da flag."""
    conn = None
    cursor = None

    try:
        conn = pool.getconn()
        cursor = conn.cursor(cursor_factory=RealDictCursor)

        cursor.execute(
            "SELECT * FROM targeting_rules WHERE flag_name = %s",
            (flag_name,)
        )

        rule = cursor.fetchone()

        if not rule:
            return jsonify({"error": "Regra não encontrada"}), 404

        return jsonify(rule), 200

    except Exception:
        log.exception("Erro ao buscar regra '%s'.", flag_name)
        return jsonify({"error": "Erro interno do servidor"}), 500

    finally:
        release_connection(conn, cursor)


@app.route("/rules/<string:flag_name>", methods=["PUT"])
@require_auth
def update_rule(flag_name):
    """Atualiza uma regra de segmentação."""
    data = get_json_body()

    if not data:
        return jsonify({"error": "Corpo JSON da requisição obrigatório"}), 400

    has_rules = "rules" in data
    has_enabled = "is_enabled" in data

    if not has_rules and not has_enabled:
        return jsonify({
            "error": "Pelo menos um campo ('rules', 'is_enabled') é obrigatório"
        }), 400

    rules_obj = data.get("rules")
    is_enabled = data.get("is_enabled")

    if has_rules and not isinstance(rules_obj, (dict, list)):
        return jsonify({"error": "rules deve ser um objeto ou lista JSON"}), 400

    if has_enabled and not isinstance(is_enabled, bool):
        return jsonify({"error": "is_enabled deve ser booleano"}), 400

    if has_rules and has_enabled:
        query = """
            UPDATE targeting_rules
            SET rules = %s, is_enabled = %s
            WHERE flag_name = %s
            RETURNING *
        """
        values = (Json(rules_obj), is_enabled, flag_name)

    elif has_rules:
        query = """
            UPDATE targeting_rules
            SET rules = %s
            WHERE flag_name = %s
            RETURNING *
        """
        values = (Json(rules_obj), flag_name)

    else:
        query = """
            UPDATE targeting_rules
            SET is_enabled = %s
            WHERE flag_name = %s
            RETURNING *
        """
        values = (is_enabled, flag_name)

    conn = None
    cursor = None
    rollback = False

    try:
        conn = pool.getconn()
        cursor = conn.cursor(cursor_factory=RealDictCursor)

        cursor.execute(query, values)
        updated_rule = cursor.fetchone()

        if not updated_rule:
            return jsonify({"error": "Regra não encontrada"}), 404

        conn.commit()

        log.info("Regra atualizada para flag '%s'.", flag_name)
        return jsonify(updated_rule), 200

    except Exception:
        rollback = True
        log.exception("Erro ao atualizar regra '%s'.", flag_name)
        return jsonify({"error": "Erro interno do servidor"}), 500

    finally:
        release_connection(conn, cursor, rollback)


@app.route("/rules/<string:flag_name>", methods=["DELETE"])
@require_auth
def delete_rule(flag_name):
    """Deleta uma regra de segmentação."""
    conn = None
    cursor = None
    rollback = False

    try:
        conn = pool.getconn()
        cursor = conn.cursor()

        cursor.execute(
            "DELETE FROM targeting_rules WHERE flag_name = %s",
            (flag_name,)
        )

        if cursor.rowcount == 0:
            return jsonify({"error": "Regra não encontrada"}), 404

        conn.commit()

        log.info("Regra deletada para flag '%s'.", flag_name)
        return "", 204

    except Exception:
        rollback = True
        log.exception("Erro ao deletar regra '%s'.", flag_name)
        return jsonify({"error": "Erro interno do servidor"}), 500

    finally:
        release_connection(conn, cursor, rollback)


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8003))
    app.run(
        host=os.getenv("HOST", "127.0.0.1"),
        port=port,
        debug=False
    )
