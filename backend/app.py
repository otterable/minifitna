# app.py
import os
import sqlite3
import hashlib
import hmac
import json
import time
import logging
import threading
from datetime import datetime, timedelta, date
from functools import wraps

from flask import Flask, request, jsonify, g, make_response
from werkzeug.middleware.proxy_fix import ProxyFix
import jwt  # PyJWT

# ==== Logging (DEBUG) ====
logging.basicConfig(level=logging.DEBUG, format='[%(asctime)s] %(levelname)s %(message)s')
logging.debug("Starting app module import")

# ==== Configuration ====
SECRET_KEY = os.environ.get("APP_SECRET", "change_this_to_a_long_random_secret")
JWT_ALG = "HS256"
DB_PATH = os.environ.get("APP_DB", "minifitna.db")
logging.debug(f"Config loaded: DB_PATH={DB_PATH}, JWT_ALG={JWT_ALG}, SECRET_KEY_set={bool(SECRET_KEY)}")

# ==== App ====
app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_port=1, x_prefix=1)  # type: ignore
logging.debug("Flask app created, ProxyFix applied")

# ==== Heartbeat thread ====
def _heartbeat():
    n = 0
    while True:
        n += 1
        logging.debug(f"HEARTBEAT #{n} worker alive at {datetime.utcnow().isoformat()}Z")
        time.sleep(10)

threading.Thread(target=_heartbeat, daemon=True).start()

# ==== DB Helpers ====
def get_db():
    if "db" not in g:
        logging.debug("Opening new SQLite connection")
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    else:
        logging.debug("Reusing existing SQLite connection from g")
    return g.db

@app.teardown_appcontext
def close_db(exception):
    db = g.pop("db", None)
    if db is not None:
        logging.debug("Closing SQLite connection")
        db.close()
    if exception:
        logging.debug(f"Teardown exception: {exception}")

def init_db():
    logging.debug("Running init_db() to ensure schema")
    db = get_db()
    db.executescript(
        """
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS users(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            target_weight REAL DEFAULT 80.0,
            daily_run_km REAL DEFAULT 10.0,
            weigh_time TEXT DEFAULT '08:00',
            run_time TEXT DEFAULT '18:00'
        );

        CREATE TABLE IF NOT EXISTS weights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            day TEXT NOT NULL,
            weight_kg REAL NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(user_id, day),
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS runs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            day TEXT NOT NULL,
            distance_km REAL NOT NULL,
            duration_min REAL NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(user_id, day),
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        );
        """
    )
    db.commit()
    logging.debug("init_db() completed")

with app.app_context():
    init_db()

# ==== Request logging & CORS ====
@app.before_request
def _log_and_cors_preflight():
    logging.debug(
        f"Incoming request: {request.method} {request.path} "
        f"args={dict(request.args)} "
        f"json={(request.get_json(silent=True) if request.is_json else None)} "
        f"headers={{'Authorization': 'present' if request.headers.get('Authorization') else 'absent', "
        f"'Content-Type': request.headers.get('Content-Type'), "
        f"'Origin': request.headers.get('Origin')}}"
    )
    # Let Flask also handle OPTIONS in case Nginx forwards it.
    if request.method == "OPTIONS":
        logging.debug("Handling CORS preflight (OPTIONS) in Flask")
        resp = make_response("", 204)
        origin = request.headers.get("Origin") or "*"
        req_headers = request.headers.get("Access-Control-Request-Headers")
        resp.headers["Access-Control-Allow-Origin"] = origin
        resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,DELETE,OPTIONS,PATCH"
        resp.headers["Access-Control-Allow-Headers"] = req_headers or "Authorization,Content-Type,Accept"
        resp.headers["Access-Control-Max-Age"] = "86400"
        resp.headers["Vary"] = "Origin"
        return resp

@app.after_request
def _log_and_cors_response(resp):
    try:
        if request.path.startswith("/api"):
            # Single source of truth for CORS headers (do NOT duplicate in Nginx)
            origin = request.headers.get("Origin") or "*"
            req_headers = request.headers.get("Access-Control-Request-Headers")
            resp.headers["Access-Control-Allow-Origin"] = origin
            resp.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,DELETE,OPTIONS,PATCH"
            resp.headers["Access-Control-Allow-Headers"] = req_headers or "Authorization,Content-Type,Accept"
            resp.headers["Access-Control-Expose-Headers"] = "Content-Type,Authorization"
            resp.headers["Vary"] = "Origin"
        body_preview = resp.get_data(as_text=True)
        if len(body_preview) > 400:
            body_preview = body_preview[:400] + "...(truncated)"
        logging.debug(f"Outgoing response: status={resp.status_code} path={request.path} body={body_preview}")
    except Exception as e:
        logging.debug(f"Error logging/adding CORS to response: {e}")
    return resp

# ==== Root / Health / Ping / Debug ====
@app.route("/", methods=["GET"])
def root():
    logging.debug("Root / called")
    return jsonify({"service": "minifitna", "status": "ok", "endpoints": ["/health", "/api/*"]}), 200

@app.route("/health", methods=["GET"])
def health():
    logging.debug("Health check called")
    try:
        db = get_db()
        db.execute("SELECT 1")
        return jsonify({"status": "ok"}), 200
    except Exception as e:
        logging.debug(f"Health check error: {e}")
        return jsonify({"status": "error", "detail": str(e)}), 500

@app.route("/api/ping", methods=["GET"])
def ping():
    logging.debug("Ping called")
    return jsonify({"pong": True, "utc": datetime.utcnow().isoformat() + "Z"}), 200

@app.route("/api/debug/echo", methods=["POST"])
def debug_echo():
    payload = request.get_json(silent=True)
    logging.debug(f"/api/debug/echo payload={payload}")
    return jsonify({"ok": True, "you_sent": payload}), 200

# ==== Security helpers ====
def _hash_password(password: str) -> str:
    logging.debug("Hashing password with PBKDF2_HMAC (salt static in demo)")
    salt = b"static_salt_change_me"
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 200_000)
    return dk.hex()

def _verify_password(password: str, password_hash: str) -> bool:
    logging.debug("Verifying password via compare_digest")
    return hmac.compare_digest(_hash_password(password), password_hash)

def create_token(user_id: int, username: str) -> str:
    logging.debug(f"Creating JWT for user_id={user_id}, username={username}")
    payload = {
        "sub": user_id,
        "username": username,
        "iat": int(time.time()),
        "exp": int(time.time()) + 60 * 60 * 24 * 14,
    }
    token = jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALG)
    logging.debug("JWT created")
    return token

def auth_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            logging.debug("auth_required: missing or malformed Authorization header")
            return jsonify({"error": "missing_token"}), 401
        token = auth.split(" ", 1)[1]
        try:
            payload = jwt.decode(token, SECRET_KEY, algorithms=[JWT_ALG])
            logging.debug(f"auth_required: token valid for user_id={payload.get('sub')}, username={payload.get('username')}")
        except jwt.PyJWTError as e:
            logging.debug(f"auth_required: invalid token error={e}")
            return jsonify({"error": "invalid_token"}), 401
        g.user_id = int(payload["sub"])
        g.username = payload["username"]
        return fn(*args, **kwargs)
    return wrapper

# ==== Utilities ====
def today_str() -> str:
    s = date.today().isoformat()
    logging.debug(f"today_str() -> {s}")
    return s

def row_to_dict(row: sqlite3.Row) -> dict:
    d = {k: row[k] for k in row.keys()}
    logging.debug(f"row_to_dict -> {d}")
    return d

# ==== Auth ====
@app.route("/api/register", methods=["POST"])
def register():
    logging.debug("Register endpoint called")
    data = request.get_json(force=True)
    username = (data.get("username") or "").strip().lower()
    password = data.get("password") or ""
    logging.debug(f"/api/register payload username={username}, password_len={len(password)}")
    if not username or not password:
        logging.debug("Register validation failed: username/password missing")
        return jsonify({"error": "username_password_required"}), 400

    db = get_db()
    try:
        db.execute("INSERT INTO users (username, password_hash) VALUES (?, ?)", (username, _hash_password(password)))
        db.commit()
        logging.debug(f"User inserted: {username}")
    except sqlite3.IntegrityError:
        logging.debug(f"Register conflict: username_taken {username}")
        return jsonify({"error": "username_taken"}), 409

    user_id = db.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()["id"]
    token = create_token(user_id, username)
    logging.debug(f"Register success: user_id={user_id}")
    return jsonify({"token": token, "username": username})

@app.route("/api/login", methods=["POST"])
def login():
    logging.debug("Login endpoint called")
    data = request.get_json(force=True)
    username = (data.get("username") or "").strip().lower()
    password = data.get("password") or ""
    logging.debug(f"/api/login payload username={username}, password_len={len(password)}")
    if not username or not password:
        logging.debug("Login validation failed: username/password missing")
        return jsonify({"error": "username_password_required"}), 400

    db = get_db()
    row = db.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
    if not row:
        logging.debug("Login failed: user not found")
        return jsonify({"error": "invalid_credentials"}), 401
    if not _verify_password(password, row["password_hash"]):
        logging.debug("Login failed: bad password")
        return jsonify({"error": "invalid_credentials"}), 401

    token = create_token(row["id"], username)
    logging.debug(f"Login success: user_id={row['id']}")
    return jsonify({"token": token, "username": username})

# ==== Profile, Weights, Runs, Summary ====
@app.route("/api/me", methods=["GET"])
@auth_required
def me_get():
    logging.debug(f"/api/me GET for user_id={g.user_id}")
    db = get_db()
    row = db.execute(
        "SELECT id, username, target_weight, daily_run_km, weigh_time, run_time FROM users WHERE id = ?",
        (g.user_id,),
    ).fetchone()
    logging.debug(f"/api/me GET row={dict(row) if row else None}")
    return jsonify(row_to_dict(row))

@app.route("/api/me", methods=["PUT"])
@auth_required
def me_update():
    logging.debug(f"/api/me PUT for user_id={g.user_id}")
    data = request.get_json(force=True)
    target_weight = float(data.get("target_weight", 80.0))
    daily_run_km = float(data.get("daily_run_km", 10.0))
    weigh_time = data.get("weigh_time", "08:00")
    run_time = data.get("run_time", "18:00")
    logging.debug(f"/api/me PUT payload target_weight={target_weight}, daily_run_km={daily_run_km}, weigh_time={weigh_time}, run_time={run_time}")

    db = get_db()
    db.execute(
        "UPDATE users SET target_weight=?, daily_run_km=?, weigh_time=?, run_time=? WHERE id=?",
        (target_weight, daily_run_km, weigh_time, run_time, g.user_id),
    )
    db.commit()
    row = db.execute(
        "SELECT id, username, target_weight, daily_run_km, weigh_time, run_time FROM users WHERE id = ?",
        (g.user_id,),
    ).fetchone()
    logging.debug("/api/me PUT updated row fetched")
    return jsonify(row_to_dict(row))

@app.route("/api/weights", methods=["GET"])
@auth_required
def weights_list():
    start = request.args.get("start")
    end = request.args.get("end")
    logging.debug(f"/api/weights GET user_id={g.user_id} start={start} end={end}")
    db = get_db()
    sql = "SELECT * FROM weights WHERE user_id=?"
    params = [g.user_id]
    if start:
        sql += " AND day >= ?"
        params.append(start)
    if end:
        sql += " AND day <= ?"
        params.append(end)
    sql += " ORDER BY day DESC"
    rows = db.execute(sql, params).fetchall()
    logging.debug(f"/api/weights GET returned {len(rows)} rows")
    return jsonify([row_to_dict(r) for r in rows])

@app.route("/api/weights", methods=["POST"])
@auth_required
def weights_add():
    data = request.get_json(force=True)
    day = data.get("day") or today_str()
    weight_kg = float(data.get("weight_kg"))
    logging.debug(f"/api/weights POST user_id={g.user_id} day={day} weight_kg={weight_kg}")
    db = get_db()
    db.execute(
        "INSERT INTO weights (user_id, day, weight_kg) VALUES (?, ?, ?) "
        "ON CONFLICT(user_id, day) DO UPDATE SET weight_kg=excluded.weight_kg",
        (g.user_id, day, weight_kg),
    )
    db.commit()
    logging.debug("/api/weights POST upserted")
    return jsonify({"status": "ok", "day": day, "weight_kg": weight_kg})

@app.route("/api/runs", methods=["GET"])
@auth_required
def runs_list():
    start = request.args.get("start")
    end = request.args.get("end")
    logging.debug(f"/api/runs GET user_id={g.user_id} start={start} end={end}")
    db = get_db()
    sql = "SELECT * FROM runs WHERE user_id=?"
    params = [g.user_id]
    if start:
        sql += " AND day >= ?"
        params.append(start)
    if end:
        sql += " AND day <= ?"
        params.append(end)
    sql += " ORDER BY day DESC"
    rows = db.execute(sql, params).fetchall()
    logging.debug(f"/api/runs GET returned {len(rows)} rows")
    return jsonify([row_to_dict(r) for r in rows])

@app.route("/api/runs", methods=["POST"])
@auth_required
def runs_add():
    data = request.get_json(force=True)
    day = data.get("day") or today_str()
    distance_km = float(data.get("distance_km"))
    duration_min = float(data.get("duration_min"))
    logging.debug(f"/api/runs POST user_id={g.user_id} day={day} distance_km={distance_km} duration_min={duration_min}")
    db = get_db()
    db.execute(
        "INSERT INTO runs (user_id, day, distance_km, duration_min) VALUES (?, ?, ?, ?) "
        "ON CONFLICT(user_id, day) DO UPDATE SET distance_km=excluded.distance_km, duration_min=excluded.duration_min",
        (g.user_id, day, distance_km, duration_min),
    )
    db.commit()
    logging.debug("/api/runs POST upserted")
    return jsonify({"status": "ok", "day": day, "distance_km": distance_km, "duration_min": duration_min})

@app.route("/api/summary", methods=["GET"])
@auth_required
def summary():
    logging.debug(f"/api/summary GET user_id={g.user_id}")
    db = get_db()
    w = db.execute("SELECT weight_kg, day FROM weights WHERE user_id=? ORDER BY day DESC LIMIT 1", (g.user_id,)).fetchone()
    latest_weight = w["weight_kg"] if w else None
    latest_weight_day = w["day"] if w else None
    u = db.execute("SELECT target_weight, daily_run_km FROM users WHERE id=?", (g.user_id,)).fetchone()
    target_weight = u["target_weight"]
    daily_run_km = u["daily_run_km"]
    delta_to_target = None if latest_weight is None else (latest_weight - target_weight)
    start7 = (date.today() - timedelta(days=6)).isoformat()
    r7 = db.execute("SELECT SUM(distance_km) AS km FROM runs WHERE user_id=? AND day >= ?", (g.user_id, start7)).fetchone()
    run_7d_km = float(r7["km"] or 0.0)

    def streak(table: str) -> int:
        d = date.today()
        s = 0
        while True:
            exists = db.execute(f"SELECT 1 FROM {table} WHERE user_id=? AND day=? LIMIT 1", (g.user_id, d.isoformat())).fetchone()
            if not exists:
                break
            s += 1
            d -= timedelta(days=1)
        logging.debug(f"/api/summary streak calc table={table} result={s}")
        return s

    payload = {
        "latest_weight": latest_weight,
        "latest_weight_day": latest_weight_day,
        "delta_to_target": delta_to_target,
        "daily_run_goal_km": float(daily_run_km),
        "run_7d_km": run_7d_km,
        "weigh_streak": streak("weights"),
        "run_streak": streak("runs")
    }
    logging.debug(f"/api/summary payload={payload}")
    return jsonify(payload)

if __name__ == "__main__":
    logging.debug("Running app via __main__ on port 8743")
    app.run(host="0.0.0.0", port=8743, debug=False)
