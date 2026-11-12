import hashlib
import getpass
import hmac
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import time
from datetime import datetime
from functools import wraps
from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, abort, redirect, render_template, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash


load_dotenv()

LOGIN_WINDOW_SECONDS = 15 * 60
LOGIN_ATTEMPT_LIMIT = 8
LOGIN_ATTEMPT_RETENTION_SECONDS = 24 * 60 * 60
SERVICE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,39}$")
SERVICE_UNIT_PATTERN = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,119}\.service$")
ANSI_ESCAPE_PATTERN = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
CONTROL_CHARACTER_PATTERN = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
SERVICE_ACTIONS = {"start", "stop", "restart"}
LOG_LINE_LIMIT = 100
LOG_CHARACTER_LIMIT = 80_000
SYSTEMD_UNITS = (
    ("docker", "Docker", "docker.service"),
    ("ssh", "Güvenli uzaktan erişim", "ssh.service"),
    ("smbd", "Dosya paylaşımı", "smbd.service"),
    ("fail2ban", "Fail2ban", "fail2ban.service"),
    ("avahi", "Yerel ağ adı (mDNS)", "avahi-daemon.service"),
    ("syncthing", "Syncthing", f"syncthing@{getpass.getuser()}.service"),
    ("backup", "Restic yedekleme zamanlayıcısı", "homelab-restic-backup.timer"),
)


def _read_environment():
    production = os.environ.get("APP_ENV", "development").strip().lower() == "production"
    return {
        "APP_ENV": "production" if production else "development",
        "SESSION_COOKIE_NAME": "__Host-admin_session" if production else "admin_session",
        "SECRET_KEY": os.environ.get("SECRET_KEY", ""),
        "ADMIN_USERNAME": os.environ.get("ADMIN_USERNAME", ""),
        "ADMIN_PASSWORD_HASH": os.environ.get("ADMIN_PASSWORD_HASH", ""),
        "LOGIN_THROTTLE_DB": os.environ.get(
            "LOGIN_THROTTLE_DB", str(Path("instance") / "login-attempts.sqlite3")
        ),
        "ADMIN_SERVICES_FILE": os.environ.get(
            "ADMIN_SERVICES_FILE", str(Path("instance") / "admin-services.json")
        ),
        "TRUST_PROXY_HEADERS": os.environ.get(
            "TRUST_PROXY_HEADERS", ""
        ).strip().lower() in {"1", "true", "yes"},
        "SESSION_COOKIE_SECURE": production
        or os.environ.get("SESSION_COOKIE_SECURE", "").strip().lower() in {"1", "true", "yes"},
    }


def _validate_settings(app):
    if not app.config["SECRET_KEY"] or len(app.config["SECRET_KEY"]) < 32:
        raise RuntimeError("SECRET_KEY must be configured with at least 32 characters.")
    if "replace-with" in app.config["SECRET_KEY"].lower():
        raise RuntimeError("SECRET_KEY must not use a placeholder value.")
    if not app.config["ADMIN_USERNAME"].strip():
        raise RuntimeError("ADMIN_USERNAME must be configured.")
    if app.config["ADMIN_USERNAME"].strip().lower().startswith("replace-with"):
        raise RuntimeError("ADMIN_USERNAME must not use a placeholder value.")
    password_hash = app.config["ADMIN_PASSWORD_HASH"]
    if not password_hash:
        raise RuntimeError("ADMIN_PASSWORD_HASH must be configured.")
    try:
        check_password_hash(password_hash, "")
    except (TypeError, ValueError) as error:
        raise RuntimeError("ADMIN_PASSWORD_HASH is not a valid Werkzeug password hash.") from error


def _read_cpu_times():
    fields = Path("/proc/stat").read_text(encoding="ascii").splitlines()[0].split()[1:]
    values = [int(value) for value in fields]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    # guest ve guest_nice (son iki alan) user/nice içinde zaten sayılır; iki kez eklenmez.
    return sum(values[:8]), idle


def _format_bytes(value):
    amount = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if amount < 1024 or unit == "TB":
            return f"{amount:.0f} {unit}" if unit == "B" else f"{amount:.1f} {unit}"
        amount /= 1024
    return f"{amount:.1f} TB"


def collect_host_snapshot(base_path="/srv/homelab"):
    try:
        start_total, start_idle = _read_cpu_times()
        time.sleep(0.12)
        end_total, end_idle = _read_cpu_times()
        delta_total = end_total - start_total
        cpu_percent = (
            round(100 * (1 - (end_idle - start_idle) / delta_total))
            if delta_total > 0 else None
        )
    except (OSError, ValueError, IndexError, ZeroDivisionError):
        cpu_percent = None

    memory = {"percent": None, "used": "Bilinmiyor", "total": "Bilinmiyor"}
    try:
        memory_values = {}
        for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
            key, value = line.split(":", 1)
            if key in {"MemTotal", "MemAvailable"}:
                memory_values[key] = int(value.strip().split()[0]) * 1024
        total = memory_values["MemTotal"]
        available = memory_values["MemAvailable"]
        used = total - available
        memory = {
            "percent": round(100 * used / total) if total else None,
            "used": _format_bytes(used),
            "total": _format_bytes(total),
        }
    except (OSError, ValueError, KeyError, IndexError):
        pass

    def disk_usage(path):
        try:
            usage = shutil.disk_usage(path)
        except OSError:
            return None
        return {
            "percent": round(100 * usage.used / usage.total) if usage.total else 0,
            "used": _format_bytes(usage.used),
            "free": _format_bytes(usage.free),
            "total": _format_bytes(usage.total),
        }

    uptime = None
    try:
        uptime_seconds = int(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0]))
        days, remainder = divmod(uptime_seconds, 86400)
        hours, minutes = divmod(remainder, 3600)
        minutes //= 60
        uptime = f"{days} gün {hours} sa {minutes} dk" if days else f"{hours} sa {minutes} dk"
    except (OSError, ValueError, IndexError):
        pass

    return {
        "hostname": os.uname().nodename if hasattr(os, "uname") else os.environ.get("COMPUTERNAME", "Sunucu"),
        "captured_at": datetime.now().astimezone().strftime("%d.%m.%Y %H:%M"),
        "cpu_percent": cpu_percent,
        "memory": memory,
        "root_disk": disk_usage("/"),
        "homelab_disk": disk_usage(base_path),
        "uptime": uptime,
    }


def collect_system_services():
    services = []
    for service_id, label, unit in SYSTEMD_UNITS:
        try:
            result = subprocess.run(
                ["systemctl", "is-active", unit],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=3,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            app_status = "unknown"
        else:
            app_status = result.stdout.strip() if result.returncode in {0, 3, 4} else "unknown"
            if app_status not in {"active", "inactive", "failed", "activating", "deactivating", "unknown"}:
                app_status = "unknown"
        services.append({
            "id": service_id,
            "label": label,
            "unit": unit,
            "status": app_status,
        })
    return services


def collect_backup_summary():
    try:
        result = subprocess.run(
            [
                "systemctl",
                "show",
                "homelab-restic-backup.service",
                "--property=Result",
                "--property=ExecMainStatus",
                "--property=ExecMainTimestamp",
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"result": "unknown", "last_run": None}
    if result.returncode != 0:
        return {"result": "unknown", "last_run": None}
    values = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value.strip()
    timestamp = values.get("ExecMainTimestamp") or None
    status = values.get("Result", "")
    exit_code = values.get("ExecMainStatus", "")
    if not timestamp:
        outcome = "not-run"
    elif status == "success" and exit_code == "0":
        outcome = "success"
    else:
        outcome = "failed"
    return {"result": outcome, "last_run": timestamp}


def create_app(test_config=None):
    app = Flask(__name__, instance_relative_config=True)
    settings = _read_environment()
    if "LOGIN_THROTTLE_DB" not in os.environ:
        settings["LOGIN_THROTTLE_DB"] = str(Path(app.instance_path) / "login-attempts.sqlite3")
    app.config.from_mapping(
        settings,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_PATH="/",
        PERMANENT_SESSION_LIFETIME=1800,
        SESSION_REFRESH_EACH_REQUEST=False,
        MAX_CONTENT_LENGTH=16 * 1024,
    )
    if test_config:
        app.config.update(test_config)
    _validate_settings(app)
    if app.config["TRUST_PROXY_HEADERS"]:
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)

    def connect_throttle_db():
        database_path = Path(app.config["LOGIN_THROTTLE_DB"])
        database_path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(database_path, timeout=5)
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS login_attempts (
                bucket_hash TEXT NOT NULL,
                attempted_at REAL NOT NULL
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_login_attempts_bucket_time "
            "ON login_attempts (bucket_hash, attempted_at)"
        )
        return connection

    def make_attempt_buckets(username):
        remote_address = request.remote_addr or "unknown"
        account_name = username.strip().casefold()[:254]
        secret = app.config["SECRET_KEY"].encode("utf-8")
        raw_buckets = (f"ip:{remote_address}", f"account:{account_name}")
        return [
            hmac.new(secret, bucket.encode("utf-8"), hashlib.sha256).hexdigest()
            for bucket in raw_buckets
        ]

    def consume_login_attempt(buckets):
        now = time.time()
        connection = connect_throttle_db()
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM login_attempts WHERE attempted_at < ?",
                (now - LOGIN_ATTEMPT_RETENTION_SECONDS,),
            )
            for bucket in buckets:
                count = connection.execute(
                    "SELECT COUNT(*) FROM login_attempts "
                    "WHERE bucket_hash = ? AND attempted_at > ?",
                    (bucket, now - LOGIN_WINDOW_SECONDS),
                ).fetchone()[0]
                if count >= LOGIN_ATTEMPT_LIMIT:
                    connection.commit()
                    return True
            connection.executemany(
                "INSERT INTO login_attempts (bucket_hash, attempted_at) VALUES (?, ?)",
                ((bucket, now) for bucket in buckets),
            )
            connection.commit()
            return False
        except sqlite3.Error:
            connection.rollback()
            app.logger.exception("Login throttling database operation failed.")
            abort(503)
        finally:
            connection.close()

    def clear_login_attempts(buckets):
        connection = connect_throttle_db()
        try:
            connection.execute("BEGIN IMMEDIATE")
            connection.executemany(
                "DELETE FROM login_attempts WHERE bucket_hash = ?",
                ((bucket,) for bucket in buckets),
            )
            connection.commit()
        except sqlite3.Error:
            connection.rollback()
            app.logger.exception("Login throttling database operation failed.")
            abort(503)
        finally:
            connection.close()

    def get_csrf_token():
        token = session.get("csrf_token")
        if not token:
            token = secrets.token_urlsafe(32)
            session["csrf_token"] = token
        return token

    def validate_csrf_token():
        expected = session.get("csrf_token", "")
        supplied = request.form.get("csrf_token", "")
        if not expected or not supplied or not hmac.compare_digest(expected, supplied):
            abort(400, description="Invalid form token.")

    def login_required(view):
        @wraps(view)
        def wrapped_view(*args, **kwargs):
            if session.get("authenticated") is not True:
                return redirect(url_for("login"))
            return view(*args, **kwargs)

        return wrapped_view


    def load_admin_services():
        services_path = Path(app.config["ADMIN_SERVICES_FILE"])
        if not services_path.exists():
            return []
        try:
            data = json.loads(services_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            app.logger.exception("Configured Docker services could not be read.")
            abort(503, description="Service configuration is unavailable.")
        if not isinstance(data, list) or len(data) > 30:
            abort(503, description="Service configuration is invalid.")
        services, seen_ids = [], set()
        for item in data:
            required = {"id", "label", "container", "compose_file", "compose_service", "actions"}
            if not isinstance(item, dict) or set(item) != required:
                abort(503, description="Service configuration is invalid.")
            sid, label, container, compose_file, compose_service, actions = (
                item["id"], item["label"], item["container"], item["compose_file"],
                item["compose_service"], item["actions"]
            )
            if (
                not isinstance(sid, str) or not SERVICE_ID_PATTERN.fullmatch(sid) or sid in seen_ids
                or not isinstance(label, str) or not label.strip() or len(label) > 80
                or not isinstance(container, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]{1,64}", container)
                or not isinstance(compose_file, str) or not re.fullmatch(r"/srv/homelab/compose/(ai|cloud|dockge|monitoring|monitoring-agent|storage|web|adguard|notify)/compose\.yaml", compose_file)
                or not isinstance(compose_service, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]{1,64}", compose_service)
                or not isinstance(actions, list) or len(actions) > 3
                or any(not isinstance(a, str) or a not in SERVICE_ACTIONS for a in actions)
                or len(set(actions)) != len(actions)
            ):
                abort(503, description="Service configuration is invalid.")
            seen_ids.add(sid)
            services.append({"id": sid, "label": label.strip(), "container": container,
                             "compose_file": compose_file, "compose_service": compose_service,
                             "actions": actions})
        return services

    def find_admin_service(service_id):
        return next((x for x in load_admin_services() if x["id"] == service_id), None)

    def run_docker_helper(service, operation):
        if operation not in {"status", "logs", "start", "stop", "restart"}:
            return None
        try:
            result = subprocess.run(
                ["sudo", "-n", "/usr/local/sbin/homelab-docker-control", service["id"], operation],
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                errors="replace", timeout=15, check=False
            )
        except (OSError, subprocess.TimeoutExpired):
            app.logger.exception("Docker helper failed: service_id=%s operation=%s", service["id"], operation)
            return None
        if result.returncode != 0:
            app.logger.warning("Docker helper returned %s: service_id=%s operation=%s",
                               result.returncode, service["id"], operation)
            return None
        output = result.stdout[-LOG_CHARACTER_LIMIT:]
        return CONTROL_CHARACTER_PATTERN.sub("", ANSI_ESCAPE_PATTERN.sub("", output)).strip()

    @app.after_request
    def set_security_headers(response):
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'self'; form-action 'self'; "
            "frame-ancestors 'none'; base-uri 'self'; object-src 'none'",
        )
        if app.config["APP_ENV"] == "production":
            response.headers.setdefault("Strict-Transport-Security", "max-age=31536000")
        return response

    @app.get("/")
    def index():
        if session.get("authenticated") is True:
            return redirect(url_for("panel"))
        return redirect(url_for("login"))

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if session.get("authenticated") is True:
            return redirect(url_for("panel"))

        error = None
        if request.method == "POST":
            validate_csrf_token()
            username = request.form.get("username", "")
            password = request.form.get("password", "")
            buckets = make_attempt_buckets(username)
            if consume_login_attempt(buckets):
                error = "Giriş başarısız. Lütfen daha sonra tekrar dene."
            else:
                username_matches = hmac.compare_digest(
                    username.strip(), app.config["ADMIN_USERNAME"].strip()
                )
                password_matches = check_password_hash(
                    app.config["ADMIN_PASSWORD_HASH"], password
                )
                if username_matches and password_matches:
                    clear_login_attempts(buckets)
                    session.clear()
                    session.permanent = True
                    session["authenticated"] = True
                    session["csrf_token"] = secrets.token_urlsafe(32)
                    return redirect(url_for("panel"))
                error = "Kullanıcı adı veya şifre hatalı."

        response = app.make_response(
            render_template("login.html", csrf_token=get_csrf_token(), error=error)
        )
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/panel")
    @login_required
    def panel():
        services = [
            dict(x, status=run_docker_helper(x, "status") or "unknown")
            for x in load_admin_services()
        ]
        running_services = sum(service["status"] == "running" for service in services)
        system_services = collect_system_services()
        backup = collect_backup_summary()
        backup["status"] = next(
            (service["status"] for service in system_services if service["id"] == "backup"),
            "unknown",
        )
        response = app.make_response(
            render_template(
                "panel.html",
                csrf_token=get_csrf_token(),
                services=services,
                running_services=running_services,
                host=collect_host_snapshot(),
                system_services=system_services,
                backup=backup,
                message=session.pop("notice", ""),
            )
        )
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/panel/console")
    @login_required
    def readonly_console():
        host = collect_host_snapshot()
        system_services = collect_system_services()
        backup = collect_backup_summary()
        backup["status"] = next(
            (service["status"] for service in system_services if service["id"] == "backup"),
            "unknown",
        )
        services = [
            dict(x, status=run_docker_helper(x, "status") or "unknown")
            for x in load_admin_services()
        ]
        memory = host["memory"]
        disk = host["root_disk"]
        homelab_disk = host["homelab_disk"]
        last_backup = {
            "success": "Başarılı",
            "failed": "Başarısız",
            "not-run": "Henüz çalışmadı",
        }.get(backup["result"], "Bilinmiyor")
        report = [
            "HOMELAB · SALT OKUNUR DURUM RAPORU",
            f"Sunucu: {host['hostname']}",
            f"Ölçüm zamanı: {host['captured_at']}",
            f"CPU: {host['cpu_percent']}%" if host["cpu_percent"] is not None else "CPU: Bilinmiyor",
            f"Bellek: {memory['used']} / {memory['total']} ({memory['percent']}%)"
            if memory["percent"] is not None else "Bellek: Bilinmiyor",
            f"Sistem diski: {disk['percent']}% dolu, {disk['free']} boş"
            if disk else "Sistem diski: Bilinmiyor",
            f"HomeLab diski: {homelab_disk['percent']}% dolu, {homelab_disk['free']} boş"
            if homelab_disk else "HomeLab diski: Bilinmiyor",
            f"Çalışma süresi: {host['uptime'] or 'Bilinmiyor'}",
            "",
            "DOCKER UYGULAMALARI",
            *[f"  [{service['status']}] {service['label']}" for service in services],
            "",
            "LINUX SERVİSLERİ",
            *[f"  [{service['status']}] {service['label']} ({service['unit']})"
              for service in system_services],
            "",
            "RESTIC YEDEKLEME",
            f"  Zamanlayıcı: {backup['status']}",
            f"  Son görev: {last_backup}",
            f"  Son çalışma: {backup['last_run'] or 'Kayıt yok'}",
            "",
            "Bu rapor sabit, salt okunur kontrollerden oluşturulur. Komut çalıştırma alanı değildir.",
        ]
        response = app.make_response(
            render_template(
                "console.html",
                csrf_token=get_csrf_token(),
                services=services,
                host=host,
                report="\n".join(report),
            )
        )
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/panel/logs/<service_id>")
    @login_required
    def service_logs(service_id):
        service = find_admin_service(service_id)
        if service is None:
            abort(404)
        app.logger.info(
            "Admin service logs viewed: username=%s service_id=%s",
            app.config["ADMIN_USERNAME"],
            service_id,
        )
        logs = run_docker_helper(service, "logs")
        response = app.make_response(
            (
                render_template(
                    "logs.html",
                    csrf_token=get_csrf_token(),
                    service=service,
                    logs=logs,
                ),
                200 if logs is not None else 503,
            )
        )
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.post("/panel/services/<service_id>/<action>")
    @login_required
    def control_service(service_id, action):
        validate_csrf_token()
        service = find_admin_service(service_id)
        if service is None or action not in service["actions"]:
            abort(404)
        result = run_docker_helper(service, action)
        app.logger.info(
            "Admin service action: username=%s action=%s service_id=%s outcome=%s",
            app.config["ADMIN_USERNAME"],
            action,
            service_id,
            "success" if result is not None else "failure",
        )
        message = (
            f"{service['label']}: {action} işlemi gönderildi."
            if result is not None
            else f"{service['label']}: işlem tamamlanamadı; Docker durumunu ve yetkili yardımcı servisi kontrol et."
        )
        session["notice"] = message
        return redirect(url_for("panel"))

    @app.post("/logout")
    @login_required
    def logout():
        validate_csrf_token()
        session.clear()
        return redirect(url_for("login", signed_out="1"))

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
