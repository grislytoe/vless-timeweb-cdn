import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config import DEFAULTS, client_config, client_url, new_credentials, nginx_config, server_config, validate, timeweb_extra

XRAY = os.environ.get("XRAY_TEST_BIN")


class ConfigTests(unittest.TestCase):
    def test_rejects_nginx_injection(self):
        for domain in ("example.com; return 200;", "example.com\n}", "-example.com", "a..com"):
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                validate(dict(DEFAULTS, domain=domain))

    def test_rejects_conflicting_ports_and_ips(self):
        for changes in (dict(fallback_port=443), dict(fallback_port=80),
                        dict(cdn_domain=DEFAULTS["domain"]), dict(inbound_ip="999.1.1.1")):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate(dict(DEFAULTS, **changes))

    @unittest.skipUnless(XRAY, "Set XRAY_TEST_BIN to a real Xray binary")
    def test_real_core_and_credential_reuse(self):
        c = new_credentials(XRAY)
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            settings = work / "settings.json"
            credentials = work / "credentials.json"
            settings.write_text(json.dumps(DEFAULTS))
            credentials.write_text(json.dumps(c))
            before = credentials.read_bytes()
            subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "config.py"),
                "credentials", "--settings", str(settings), "--credentials", str(credentials),
                "--xray", XRAY], check=True)
            self.assertEqual(before, credentials.read_bytes())
            for cfg in (server_config(DEFAULTS, c), client_config(DEFAULTS, c)):
                path = work / "config.json"
                path.write_text(json.dumps(cfg))
                result = subprocess.run([XRAY, "run", "-test", "-config", str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(XRAY, "Set XRAY_TEST_BIN")
    def test_link_roundtrip(self):
        c = new_credentials(XRAY)
        link = urlsplit(client_url(DEFAULTS, c))
        params = parse_qs(link.query)
        self.assertEqual(link.username, c["uuid"])
        self.assertEqual(params["path"], [c["path"] + '/index.json'])
        self.assertEqual(params['security'], ['tls'])
        self.assertEqual(link.hostname, DEFAULTS['cdn_domain'])
        self.assertEqual(json.loads(params['extra'][0]), timeweb_extra())
        self.assertNotIn('pbk', params)
        self.assertNotIn('sid', params)

    def test_single_ipv4_and_client_uri_json_agree(self):
        s = dict(DEFAULTS)
        self.assertEqual(validate(s)['inbound_ip'], s['outbound_ip'])
        c = new_credentials(None)
        uri = urlsplit(client_url(s, c, 'Телефон'))
        q = parse_qs(uri.query)
        cfg = client_config(s, c)['outbounds'][0]
        self.assertEqual(cfg['settings']['vnext'][0]['address'], uri.hostname)
        self.assertEqual(q['sni'][0], cfg['streamSettings']['tlsSettings']['serverName'])
        self.assertEqual(q['host'][0], cfg['streamSettings']['xhttpSettings']['host'])
        self.assertEqual(json.loads(q['extra'][0]), cfg['streamSettings']['xhttpSettings']['extra'])
        server = server_config(s, c)['inbounds'][0]
        self.assertEqual(server['listen'], '127.0.0.1')
        self.assertEqual(server['streamSettings']['security'], 'none')
        nginx = nginx_config(s, tls=True, credentials=c)
        self.assertIn(c['path'] + '/', nginx)
        self.assertIn('proxy_request_buffering off', nginx)
        self.assertIn('proxy_buffering off', nginx)
        self.assertIn('proxy_bind 127.0.0.2', nginx)
        self.assertNotIn('proxy_protocol', nginx)

    def test_origin_probe_does_not_use_cdn_sni(self):
        c = new_credentials(None)
        cfg = client_config(DEFAULTS, c, address=DEFAULTS['inbound_ip'], origin=True)['outbounds'][0]
        self.assertEqual(cfg['streamSettings']['tlsSettings']['serverName'], DEFAULTS['domain'])
        self.assertEqual(cfg['streamSettings']['xhttpSettings']['host'], DEFAULTS['domain'])

    def test_old_reality_state_is_not_silently_migrated(self):
        s = dict(DEFAULTS)
        del s['deployment']
        with self.assertRaises(ValueError):
            validate(s)

    def test_rejects_cdn_domain_injection(self):
        for value in ['a.com; return 200;', 'a.com\n}', '-a.com', 'a..com', 'A.com']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate(dict(DEFAULTS, cdn_domain=value))

    def test_no_tls_required_for_bootstrap(self):
        config = nginx_config(DEFAULTS)
        self.assertNotIn("ssl_certificate", config)
        self.assertIn("/.well-known/acme-challenge/", config)


if __name__ == "__main__":
    unittest.main()
