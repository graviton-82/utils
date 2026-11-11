"""Regression tests with fake external commands; no services or root required."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('RS_', 'PG'))}
        self.env.update(PATH=f'{self.bin}:/usr/bin:/bin', TEST_DIR=str(self.work))
        self.command('curl', '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
kind = 'cpu' if 'system.cpu' in sys.argv[-1] else 'ram'
if os.getenv('CURL_FAIL'): sys.exit(1)
fixture = Path(os.environ['TEST_DIR']) / (kind + '.json')
if fixture.exists(): print(fixture.read_text()); sys.exit()
labels = ['time','user','system','iowait'] if kind == 'cpu' else ['time','used','free','cached','buffers']
rows = [[200,10,5,1],[100,90,5,1]] if kind == 'cpu' else [[200,100,200,300,400]]
print(json.dumps({'labels': labels, 'data':rows}))
''')
        self.command('ssh', '''#!/usr/bin/python3
import os, sys
from pathlib import Path
p = Path(os.environ['TEST_DIR']) / 'ssh_calls'
p.write_text(p.read_text() + '1' if p.exists() else '1')
if os.getenv('SSH_FAIL'): sys.exit(255)
if os.getenv('SSH_PARTIAL'):
    sys.stdin.read(); print('HOST|OK|fake-host'); sys.exit(124)
os.execvp('bash', ['bash', '-s'])
''')
        self.command('df', '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['TEST_DIR']) / 'df_args'
with p.open('a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
if os.getenv('DF_FAIL'): sys.exit(1)
print('Filesystem blocks used available capacity mounted')
print('/dev/fake 100 20 80 20% /')
''')
        self.command('ip', '#!/bin/bash\n[[ ! ${IP_FAIL:-} ]]\n')
        self.command('sudo', '#!/bin/bash\n[[ ! ${SUDO_FAIL:-} ]] || exit 1\nprintf "%s\\n" "${VPN_DATA:-3|2|10}"\n')
        self.command('pg_isready', '#!/bin/bash\n[[ ! ${PG_DOWN:-} ]]\n')
        self.command('psql', '''#!/bin/bash
[[ ! ${PG_FAIL:-} ]] || { echo 'password=DO_NOT_LEAK' >&2; exit 1; }
printf '%s\n' "${PG_DATA:-10|100|3|7|0|0|0}"
''')

    def command(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_stats(self, *args, expected=0, **env):
        result = subprocess.run([str(ROOT / 'remote_stats.sh'), *args],
                                env=self.env | env, text=True, capture_output=True,
                                timeout=8)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def metrics(self, result):
        return {m['name']: m for m in json.loads(result.stdout)['metrics']}

    def test_newest_timestamp_and_single_connection(self):
        result = self.run_stats('fake-host', '--json')
        self.assertIn('total=16.0%', self.metrics(result)['CPU']['detail'])
        self.assertEqual((self.work / 'ssh_calls').read_text(), '1')
        self.assertNotIn('\x1b', result.stdout)

    def test_local_execution_bypasses_ssh(self):
        self.run_stats('localhost', '--json')
        self.assertFalse((self.work / 'ssh_calls').exists())

    def test_mount_is_literal_in_local_and_remote_collection(self):
        marker = self.work / 'injected'
        mount = f'/space " quote \' $(touch {marker}) `touch {marker}`; literal $HOME'
        for host in ('localhost', 'fake-host'):
            result = self.run_stats(host, mount, '--json')
            self.assertIn(mount, self.metrics(result)['DISK']['detail'])
        self.assertFalse(marker.exists())
        for line in (self.work / 'df_args').read_text().splitlines():
            self.assertEqual(json.loads(line)[1:], ['--', mount])

    def test_invalid_cli(self):
        cases = [[], ['-oProxyCommand=bad'], ['host', '--profile'],
                 ['host', '--profile', 'oops'], ['host', '--bad'],
                 ['host', '/', '/tmp'], ['host', '--timeout', '0'],
                 ['host', '--interval', 'bad'], ['host;echo bad']]
        for args in cases:
            with self.subTest(args=args):
                self.run_stats(*args, expected=2)
        self.run_stats('--help')
        self.run_stats('host', '--json', expected=2, RS_CPU_WARN='80', RS_CPU_CRIT='70')
        self.assertFalse((self.work / 'ssh_calls').exists())

    def test_bad_netdata(self):
        fixtures = ['{}', '{broken', json.dumps({'labels':['time','user'], 'data':[[1,0]]}),
                    json.dumps({'labels':['time','user','system','iowait'], 'data':[]}),
                    json.dumps({'labels':['time','user','system','iowait'], 'data':[[1,None,0,0]]})]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                (self.work / 'cpu.json').write_text(fixture)
                metrics = self.metrics(self.run_stats('host', '--json', expected=1))
                self.assertEqual(metrics['CPU']['status'], 'UNKNOWN')
                self.assertEqual(metrics['DISK']['status'], 'OK')

    def test_collector_failures_preserve_reachable_host(self):
        result = self.run_stats('host', '--json', expected=1, CURL_FAIL='1', DF_FAIL='1')
        metrics = self.metrics(result)
        self.assertNotIn('HOST', metrics)
        for name in ('CPU', 'RAM', 'DISK', 'INOD'):
            self.assertEqual(metrics[name]['status'], 'UNKNOWN')
        self.assertIn('http_failed', metrics['CPU']['detail'])

    def test_small_numeric_samples_and_configurable_threshold(self):
        (self.work / 'cpu.json').write_text(json.dumps({
            'labels':['time','user','system','iowait'], 'data':[[1,1e-9,0,0]]}))
        result = self.run_stats('host', '--json')
        self.assertEqual(self.metrics(result)['CPU']['status'], 'OK')
        (self.work / 'cpu.json').unlink()
        result = self.run_stats('host', '--json', RS_CPU_WARN='10')
        self.assertEqual(self.metrics(result)['CPU']['status'], 'WARNING')

    def test_zero_ram_is_unknown(self):
        (self.work / 'ram.json').write_text(json.dumps({
            'labels':['time','used','free','cached','buffers'], 'data':[[1,0,0,0,0]]}))
        self.assertEqual(self.metrics(self.run_stats('host', '--json', expected=1))['RAM']['status'], 'UNKNOWN')

    def test_vpn_errors_and_idle(self):
        result = self.run_stats('host', '--profile', 'vpn', '--json', expected=1, SUDO_FAIL='1')
        self.assertEqual(self.metrics(result)['VPN']['status'], 'CRITICAL')
        for value in ('garbage', '', '2|3|5', '0|0|5', '2|1|-1'):
            # A blank line from a helper is invalid too.
            result = self.run_stats('host', '--profile', 'vpn', '--json', expected=1,
                                    VPN_DATA=value if value else '\n')
            self.assertEqual(self.metrics(result)['VPN']['status'], 'UNKNOWN')
        result = self.run_stats('host', '--profile', 'vpn', '--json', VPN_DATA='3|0|-1')
        self.assertEqual(self.metrics(result)['VPN']['status'], 'OK')
        self.assertIn('idle_or_no_handshake', self.metrics(result)['VPN']['detail'])
        result = self.run_stats('host', '--profile', 'vpn', '--json', IP_FAIL='1')
        self.assertEqual(self.metrics(result)['VPN']['status'], 'CRITICAL')

    def test_postgres_states_and_sanitized_debug(self):
        result = self.run_stats('host', '--profile', 'db', '--json', PG_DATA='90|100|5|85|0|0|1')
        self.assertEqual(self.metrics(result)['PG']['status'], 'CRITICAL')
        result = self.run_stats('host', '--profile', 'db', '--json', PG_DOWN='1')
        self.assertEqual(self.metrics(result)['PG']['status'], 'CRITICAL')
        result = self.run_stats('host', '--profile', 'db', '--json', '--debug', expected=1, PG_FAIL='1')
        self.assertIn('query_failed', result.stderr)
        self.assertNotIn('DO_NOT_LEAK', result.stdout + result.stderr)
        result = self.run_stats('host', '--profile', 'db', '--json', expected=1, PG_DATA='bad')
        self.assertEqual(self.metrics(result)['PG']['status'], 'UNKNOWN')

    def test_unreachable_and_partial_snapshot(self):
        result = self.run_stats('host', '--json', expected=1, SSH_FAIL='1')
        self.assertEqual(self.metrics(result)['HOST']['status'], 'OFFLINE')
        result = self.run_stats('host', '--json', expected=1, SSH_PARTIAL='1')
        metrics = self.metrics(result)
        self.assertNotIn('HOST', metrics)
        self.assertEqual(metrics['CPU']['status'], 'UNKNOWN')

    def test_deadline(self):
        self.command('ssh', '#!/bin/bash\nsleep 10\n')
        self.run_stats('host', '--json', '--timeout', '1', expected=1)

    def test_refresh_keeps_arguments(self):
        mount = '/path with "quotes" $dollar; semicolon'
        proc = subprocess.Popen([str(ROOT / 'remote_stats.sh'), 'host', mount,
                                 '--interval', '1', '--no-color'], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            import time
            end = time.monotonic() + 5
            while time.monotonic() < end:
                p = self.work / 'ssh_calls'
                if p.exists() and len(p.read_text()) >= 2:
                    break
                time.sleep(.05)
            else:
                self.fail('refresh did not collect twice')
        finally:
            proc.terminate()
            out, err = proc.communicate(timeout=4)
        self.assertNotIn('\x1b', out)
        self.assertEqual(err, '')
        for line in (self.work / 'df_args').read_text().splitlines():
            self.assertEqual(json.loads(line)[-1], mount)

    def test_source_has_no_side_effects(self):
        result = subprocess.run(['bash', '-c', 'source "$1"', 'test', str(ROOT / 'remote_stats.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_helper_only_returns_aggregates(self):
        # Substitute only the absolute wg executable in a temporary helper copy.
        # Production keeps an absolute path and a fixed PATH under sudo.
        wg = self.bin / 'wg'
        self.command('wg', '''#!/usr/bin/python3
import sys, time
assert sys.argv[1:] == ['show','wg0','latest-handshakes']
print('PUBLIC_KEY_A', int(time.time()))
print('PUBLIC_KEY_B', 0)
''')
        helper = self.work / 'helper'
        helper.write_text((ROOT / 'helpers/wg-dashboard-stats').read_text().replace('/usr/bin/wg', str(wg)))
        result = subprocess.run(['bash', str(helper)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r'^2\|1\|[0-9]+\n$')
        self.assertNotIn('PUBLIC_KEY', result.stdout)
        result = subprocess.run(['bash', str(helper), '-x'], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.command('wg', '#!/bin/bash\necho malformed\n')
        result = subprocess.run(['bash', str(helper)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
