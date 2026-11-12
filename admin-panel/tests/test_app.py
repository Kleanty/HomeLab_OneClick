import json, os, tempfile, unittest
from pathlib import Path
import subprocess
from unittest.mock import patch
from werkzeug.security import generate_password_hash

_tmp = tempfile.TemporaryDirectory()
os.environ.update({
    "SECRET_KEY": "test-secret-key-with-at-least-32-characters",
    "ADMIN_USERNAME": "admin",
    "ADMIN_PASSWORD_HASH": generate_password_hash("test-password"),
    "LOGIN_THROTTLE_DB": str(Path(_tmp.name) / "import.sqlite3"),
    "APP_ENV": "development",
    "SESSION_COOKIE_SECURE": "false",
})
import app as panel_app
from app import create_app

class PanelTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.services=Path(self.tmp.name)/"services.json"
        self.services.write_text(json.dumps([{
            "id":"n8n","label":"n8n","container":"n8n",
            "compose_file":"/srv/homelab/compose/ai/compose.yaml",
            "compose_service":"n8n","actions":["start","stop","restart"]
        }]))
        self.app=create_app({
            "TESTING":True,"APP_ENV":"development","SESSION_COOKIE_SECURE":False,
            "SESSION_COOKIE_NAME":"admin_session",
            "SECRET_KEY":"test-secret-key-with-at-least-32-characters",
            "ADMIN_USERNAME":"admin","ADMIN_PASSWORD_HASH":generate_password_hash("test-password"),
            "LOGIN_THROTTLE_DB":str(Path(self.tmp.name)/"throttle.sqlite3"),
            "ADMIN_SERVICES_FILE":str(self.services)
        })
        self.client=self.app.test_client()
    def tearDown(self): self.tmp.cleanup()
    def token(self):
        self.client.get("/login")
        with self.client.session_transaction() as s: return s["csrf_token"]
    def login(self):
        return self.client.post("/login",data={"username":"admin","password":"test-password","csrf_token":self.token()})
    def test_login_csrf_and_auth(self):
        self.assertEqual(self.client.get("/panel").status_code,302)
        self.assertEqual(self.client.post("/login",data={"username":"admin","password":"test-password"}).status_code,400)
        self.assertEqual(self.login().status_code,302)
        self.assertEqual(self.client.get("/panel").status_code,200)
    def test_password_not_reflected(self):
        self.client.post("/login",data={"username":"admin","password":"wrong-secret","csrf_token":self.token()})
        self.assertNotIn(b"wrong-secret",self.client.get("/login").data)
    def test_dashboard_renders_system_and_app_status(self):
        self.login()
        def fake_command(command, **_kwargs):
            if "status" in str(command):
                return subprocess.CompletedProcess(command,0,stdout="running\n",stderr="")
            return subprocess.CompletedProcess(command,0,stdout=(
                "Result=exit-code\nExecMainStatus=1\n"
                "ExecMainTimestamp=Sun 2026-11-08 18:00:00 UTC\n"
            ),stderr="")
        with patch("app.subprocess.run", side_effect=fake_command) as run:
            with patch("app.collect_host_snapshot", return_value={
                "hostname":"test-host","captured_at":"08.11.2026 19:00",
                "cpu_percent":12,"memory":{"percent":50,"used":"8.0 GB","total":"16.0 GB"},
                "root_disk":{"percent":40,"used":"40 GB","free":"60 GB","total":"100 GB"},
                "homelab_disk":{"percent":30,"used":"30 GB","free":"70 GB","total":"100 GB"},
                "uptime":"1g 2s 3d"
            }), patch("app.collect_system_services", return_value=[
                {"id":"docker","label":"Docker","unit":"docker.service","status":"active"},
                {"id":"backup","label":"Restic yedekleme zamanlayıcısı","unit":"homelab-restic-backup.timer","status":"inactive"},
            ]):
                response=self.client.get("/panel")
        self.assertEqual(response.status_code,200)
        self.assertIn(b"Genel bak",response.data)
        self.assertIn(b"16.0 GB",response.data)
        self.assertIn(b"Uygulamalar",response.data)
        self.assertIn(b"Disk ve yedekleme",response.data)
        self.assertIn(b"Salt okunur konsol",response.data)
        self.assertEqual(run.call_count,2)
        self.assertIn("/usr/local/sbin/homelab-docker-control", run.call_args_list[0].args[0])

    def test_dashboard_shows_backup_result(self):
        self.login()
        def fake_command(command, **_kwargs):
            if "show" in command:
                return subprocess.CompletedProcess(command,0,stdout=(
                    "Result=success\nExecMainStatus=0\n"
                    "ExecMainTimestamp=Sun 2026-11-08 03:15:00 UTC\n"),stderr="")
            return subprocess.CompletedProcess(command,0,stdout="active\n",stderr="")
        with patch("app.subprocess.run", side_effect=fake_command):
            with patch("app.collect_host_snapshot", return_value={
                "hostname":"h","captured_at":"08.11.2026 19:00","cpu_percent":1,
                "memory":{"percent":1,"used":"1 GB","total":"2 GB"},
                "root_disk":None,"homelab_disk":None,"uptime":"1s"}):
                body=self.client.get("/panel").data.decode()
        self.assertIn("Son yedek başarılı", body)
        self.assertIn("Sun 2026-11-08 03:15:00 UTC", body)

    def test_readonly_console_has_no_command_input(self):
        self.assertEqual(self.client.get("/panel/console").status_code,302)
        self.login()
        with patch("app.subprocess.run", return_value=subprocess.CompletedProcess([],0,stdout="running\n",stderr="")) as run:
            with patch("app.collect_host_snapshot", return_value={
                "hostname":"test-host","captured_at":"08.11.2026 19:00",
                "cpu_percent":12,"memory":{"percent":50,"used":"8.0 GB","total":"16.0 GB"},
                "root_disk":None,"homelab_disk":None,"uptime":"1g 2s 3d"
            }), patch("app.collect_system_services", return_value=[
                {"id":"backup","label":"Restic yedekleme zamanlayıcısı","unit":"homelab-restic-backup.timer","status":"active"},
            ]):
                response=self.client.get("/panel/console?cmd=unexpected")
        self.assertEqual(response.status_code,200)
        self.assertIn(b"SALT OKUNUR DURUM RAPORU",response.data)
        self.assertIn(b"komut kabul etmez",response.data)
        self.assertNotIn(b"name=\"cmd\"",response.data)
        self.assertNotIn(b"unexpected",response.data)
        self.assertEqual(run.call_count,2)
        self.assertEqual(run.call_args_list[0].args[0][:3],["systemctl","show","homelab-restic-backup.service"])
        self.assertEqual(run.call_args_list[1].args[0][-2:],["n8n","status"])
        self.assertTrue(all("shell" not in call.kwargs for call in run.call_args_list))

    def test_backup_summary_reports_failed_run(self):
        output = "Result=exit-code\nExecMainStatus=1\nExecMainTimestamp=Sun 2026-11-08 18:00:00 UTC\n"
        with patch("app.subprocess.run", return_value=subprocess.CompletedProcess([],0,stdout=output,stderr="")):
            summary=panel_app.collect_backup_summary()
        self.assertEqual(summary, {"result":"failed","last_run":"Sun 2026-11-08 18:00:00 UTC"})

    def test_dashboard_system_service_states(self):
        with patch("app.subprocess.run") as run:
            run.side_effect = [
                __import__("subprocess").CompletedProcess([],0,stdout="active\n",stderr=""),
                __import__("subprocess").CompletedProcess([],3,stdout="inactive\n",stderr=""),
                __import__("subprocess").CompletedProcess([],4,stdout="not-found\n",stderr=""),
                __import__("subprocess").CompletedProcess([],1,stdout="",stderr="error"),
                __import__("subprocess").CompletedProcess([],0,stdout="activating\n",stderr=""),
                __import__("subprocess").CompletedProcess([],0,stdout="active\n",stderr=""),
                __import__("subprocess").CompletedProcess([],3,stdout="inactive\n",stderr=""),
            ]
            services=panel_app.collect_system_services()
        self.assertEqual(services[0]["status"],"active")
        self.assertEqual(services[1]["status"],"inactive")
        self.assertEqual(services[2]["status"],"unknown")
        self.assertEqual(services[3]["status"],"unknown")
        self.assertEqual(services[4]["status"],"activating")
        self.assertEqual(run.call_count,7)

    def test_service_configuration_is_allowlisted(self):
        self.login()
        with patch("app.subprocess.run", return_value=subprocess.CompletedProcess([],0,stdout="running\n",stderr="")) as run:
            with patch("app.collect_host_snapshot", return_value={
                "hostname":"test-host","captured_at":"08.11.2026 19:00",
                "cpu_percent":12,"memory":{"percent":50,"used":"8.0 GB","total":"16.0 GB"},
                "root_disk":None,"homelab_disk":None,"uptime":"1g 2s 3d"
            }), patch("app.collect_system_services", return_value=[
                {"id":"backup","label":"Restic yedekleme zamanlayıcısı","unit":"homelab-restic-backup.timer","status":"inactive"},
            ]), patch("app.collect_backup_summary", return_value={"status":"inactive","result":"unknown","last_run":"-"}):
                response=self.client.get("/panel")
        self.assertEqual(response.status_code,200)
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(command[-2:], ["n8n", "status"])
        self.assertIn("/usr/local/sbin/homelab-docker-control", command)
    def test_url_message_is_not_reflected(self):
        self.login()
        with patch("app.subprocess.run", return_value=subprocess.CompletedProcess([],0,stdout="running\n",stderr="")):
            body=self.client.get("/panel?message=SAHTE-UYARI").data
        self.assertNotIn(b"SAHTE-UYARI",body)
    def test_invalid_service_id_not_found(self):
        self.login()
        self.assertEqual(self.client.get("/panel/logs/../../etc/passwd").status_code,404)
    def test_production_cookie_security(self):
        prod=create_app({"TESTING":True,"APP_ENV":"production","SESSION_COOKIE_SECURE":True,
            "SESSION_COOKIE_NAME":"__Host-admin_session","SECRET_KEY":"test-secret-key-with-at-least-32-characters",
            "ADMIN_USERNAME":"admin","ADMIN_PASSWORD_HASH":generate_password_hash("test-password"),
            "LOGIN_THROTTLE_DB":str(Path(self.tmp.name)/"prod.sqlite3"),
            "ADMIN_SERVICES_FILE":str(self.services)})
        c=prod.test_client(); c.get("/login")
        with c.session_transaction() as s: csrf=s["csrf_token"]
        r=c.post("/login",data={"username":"admin","password":"test-password","csrf_token":csrf})
        self.assertIn("Secure",r.headers["Set-Cookie"])
        self.assertIn("HttpOnly",r.headers["Set-Cookie"])
        self.assertEqual(r.headers["X-Frame-Options"],"DENY")

if __name__=="__main__": unittest.main()
