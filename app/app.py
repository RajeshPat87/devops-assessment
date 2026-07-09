"""Hello World web tier.

Reads non-sensitive config from environment variables (injected via
ConfigMap) and DB credentials from environment variables (injected via
Secret). Exposes:
  /        -> hello message + visit counter stored in PostgreSQL
  /healthz -> liveness (process is up)
  /readyz  -> readiness (DB reachable)
"""

import os

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)

APP_ENV = os.getenv("APP_ENV", "local")
GREETING = os.getenv("GREETING", "Hello World")

DB_HOST = os.getenv("DB_HOST", "postgres")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "appdb")
DB_USER = os.getenv("DB_USER", "appuser")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")


def get_conn():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=3,
    )


def ensure_table(conn):
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS visits ("
            "id SERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT now())"
        )
    conn.commit()


@app.route("/")
def index():
    try:
        conn = get_conn()
        ensure_table(conn)
        with conn.cursor() as cur:
            cur.execute("INSERT INTO visits DEFAULT VALUES")
            conn.commit()
            cur.execute("SELECT count(*) FROM visits")
            count = cur.fetchone()[0]
        conn.close()
        return jsonify(message=GREETING, env=APP_ENV, visits=count)
    except Exception as exc:  # pragma: no cover
        return jsonify(message=GREETING, env=APP_ENV, db_error=str(exc)), 500


@app.route("/healthz")
def healthz():
    return jsonify(status="ok")


@app.route("/readyz")
def readyz():
    try:
        conn = get_conn()
        conn.close()
        return jsonify(status="ready")
    except Exception as exc:
        return jsonify(status="not-ready", error=str(exc)), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
