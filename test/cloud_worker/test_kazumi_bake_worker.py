import importlib.util
import io
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'kazumi_bake_worker',
    os.path.join(HERE, '..', '..', 'server', 'cloud', 'kazumi_bake_worker.py'))
kbw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kbw)

TOKEN = 'x' * 43


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.clock = FakeClock()
        self.w = kbw.Worker(self.root, TOKEN, cap_sec=100000, idle_sec=600, clock=self.clock)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def put(self, ep, index, data):
        self.w.put_part(ep, index, io.BytesIO(data), len(data))

    def queue_one(self, duration=10):
        self.w.ready('ffmpeg', kbw.NVENC)
        self.put('e1', 0, b'abc')
        self.assertIsNone(self.w.commit('e1', 3, duration, 1440))

    def test_commit_assembles_parts_in_order(self):
        self.w.ready('ffmpeg', kbw.NVENC)
        self.put('e1', 1, b'world')
        self.put('e1', 0, b'hello ')
        self.assertEqual(self.w.parts('e1'), {0: 6, 1: 5})
        self.assertIsNotNone(self.w.commit('e1', 99, 10, 1440))
        self.assertIsNone(self.w.commit('e1', 11, 10, 1440))
        with open(self.w.source('e1'), 'rb') as f:
            self.assertEqual(f.read(), b'hello world')
        self.assertEqual(self.w.status()['episodes']['e1']['state'], 'queued')
        # A commit retried after a lost response must not fail the episode.
        self.assertIsNone(self.w.commit('e1', 11, 10, 1440))

    def test_commit_rejects_a_gap(self):
        self.w.ready('ffmpeg', kbw.NVENC)
        self.put('e1', 0, b'ab')
        self.put('e1', 2, b'cd')
        self.assertIsNotNone(self.w.commit('e1', 4, 10, 1440))

    def test_commit_before_ready_is_refused(self):
        self.put('e1', 0, b'ab')
        self.assertIsNotNone(self.w.commit('e1', 2, 10, 1440))

    def test_short_part_is_not_kept(self):
        with self.assertRaises(IOError):
            self.w.put_part('e1', 0, io.BytesIO(b'abc'), 10)
        self.assertEqual(self.w.parts('e1'), {})

    def test_bake_success_reports_progress_and_size(self):
        self.queue_one(duration=10)
        seen = []

        def fake(cmd, on_line):
            on_line('out_time_us=5000000')
            seen.append(self.w.status()['episodes']['e1']['progress'])
            with open(cmd[-1], 'wb') as f:
                f.write(b'x' * 42)
            return 0, ''

        self.w.run_ffmpeg = fake
        self.w.bake_next()
        ep = self.w.status()['episodes']['e1']
        self.assertEqual(seen, [0.5])
        self.assertEqual((ep['state'], ep['outBytes'], ep['progress']), ('done', 42, 1.0))
        self.assertFalse(os.path.exists(self.w.source('e1')))

    def test_bake_uses_the_pc_encoder_settings(self):
        self.queue_one()
        calls = []

        def fake(cmd, on_line):
            calls.append(cmd)
            with open(cmd[-1], 'wb') as f:
                f.write(b'x')
            return 0, ''

        self.w.run_ffmpeg = fake
        self.w.bake_next()
        cmd = ' '.join(calls[0])
        self.assertIn('-c:v hevc_nvenc -preset p5 -rc vbr -cq 22 -b:v 0', cmd)
        self.assertIn('h=1440:custom_shader_path=shader.glsl:format=p010le', cmd)
        self.assertIn('-profile:v main10 -tag:v hvc1 -c:a copy', cmd)

    def test_bake_retries_with_aac_then_fails(self):
        self.queue_one()
        calls = []

        def fake(cmd, on_line):
            calls.append(' '.join(cmd))
            return 1, 'first\nCould not write header\n'

        self.w.run_ffmpeg = fake
        self.w.bake_next()
        self.assertEqual(len(calls), 2)
        self.assertIn('-c:a copy', calls[0])
        self.assertIn('-c:a aac -b:a 192k', calls[1])
        ep = self.w.status()['episodes']['e1']
        self.assertEqual(ep['state'], 'failed')
        self.assertIn('Could not write header', ep['error'])

    def test_an_unexpected_error_fails_the_episode_not_the_slot(self):
        self.queue_one()

        def broken(cmd, on_line):
            raise OSError('cannot start ffmpeg')

        self.w.run_ffmpeg = broken
        self.w.bake_next()
        ep = self.w.status()['episodes']['e1']
        self.assertEqual(ep['state'], 'failed')
        self.assertIn('cannot start ffmpeg', ep['error'])

    def test_an_episode_dropped_while_queued_is_skipped(self):
        self.queue_one()
        self.w.drop('e1')
        self.w.run_ffmpeg = lambda cmd, on_line: self.fail('baked a dropped episode')
        self.w.bake_next()
        self.assertNotIn('e1', self.w.status()['episodes'])

    def test_unknown_duration_does_not_divide_by_zero(self):
        self.queue_one(duration=0)

        def fake(cmd, on_line):
            on_line('out_time_us=500000')
            with open(cmd[-1], 'wb') as f:
                f.write(b'x')
            return 0, ''

        self.w.run_ffmpeg = fake
        self.w.bake_next()
        self.assertEqual(self.w.status()['episodes']['e1']['state'], 'done')

    def test_watchdog_waits_for_boot_then_fires_on_idle(self):
        self.clock.t += 5000
        self.assertIsNone(self.w.expired())
        self.w.ready('ffmpeg', kbw.NVENC)
        self.clock.t += 599
        self.assertIsNone(self.w.expired())
        self.w.touch()
        self.clock.t += 599
        self.assertIsNone(self.w.expired())
        self.clock.t += 2
        self.assertEqual(self.w.expired(), 'idle')

    def test_watchdog_fires_on_cap_even_while_booting(self):
        w = kbw.Worker(self.root, TOKEN, cap_sec=3600, idle_sec=600, clock=self.clock)
        self.clock.t += 3601
        self.assertEqual(w.expired(), 'cap')

    def test_cap_is_only_raised_and_has_a_ceiling(self):
        w = kbw.Worker(self.root, TOKEN, cap_sec=3600, idle_sec=600, clock=self.clock)
        w.extend_cap(1800)
        self.assertEqual(w.cap_sec, 3600)
        w.extend_cap(7200)
        self.clock.t += 3601
        self.assertIsNone(w.expired())
        w.extend_cap(10 ** 9)
        self.assertEqual(w.cap_sec, kbw.MAX_CAP_SEC)
        big = kbw.Worker(self.root, TOKEN, cap_sec=kbw.MAX_CAP_SEC * 2, clock=self.clock)
        big.extend_cap(60)
        self.assertEqual(big.cap_sec, kbw.MAX_CAP_SEC * 2)

    def test_watchdog_retries_until_terminate_succeeds(self):
        self.w.ready('ffmpeg', kbw.NVENC)
        self.clock.t += 601
        attempts = []

        def terminate():
            attempts.append(1)
            if len(attempts) < 3:
                raise RuntimeError('network')

        kbw.watchdog(self.w, terminate=terminate, interval=0, sleep=lambda s: None)
        self.assertEqual(len(attempts), 3)


class HttpTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.w = kbw.Worker(self.root, TOKEN, cap_sec=100000)
        self.w.ready('ffmpeg', kbw.NVENC)
        self.terminated = threading.Event()
        self.server = ThreadingHTTPServer(
            ('127.0.0.1', 0), kbw.make_handler(self.w, self.terminated.set))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.root, ignore_errors=True)

    def call(self, method, path, data=None, token=TOKEN, headers=None):
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if token is not None:
            req.add_header('X-Kazumi-Token', token)
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def test_wrong_or_missing_token_gets_403(self):
        self.assertEqual(self.call('GET', '/status', token='nope')[0], 403)
        self.assertEqual(self.call('GET', '/status', token=None)[0], 403)
        self.assertEqual(self.call('GET', '/status')[0], 200)

    def test_upload_commit_and_range_download(self):
        self.assertEqual(self.call('PUT', '/in/e1/parts/0', b'hello')[0], 200)
        status, body, _ = self.call('GET', '/in/e1/parts')
        self.assertEqual(json.loads(body), {'parts': {'0': 5}})
        status, body, _ = self.call('POST', '/in/e1/commit',
                                    json.dumps({'size': 9, 'durationSec': 1, 'height': 1440}).encode())
        self.assertEqual(status, 409)
        status, _, _ = self.call('POST', '/in/e1/commit',
                                 json.dumps({'size': 5, 'durationSec': 1, 'height': 1440}).encode())
        self.assertEqual(status, 200)
        with open(self.w.output('e1'), 'wb') as f:
            f.write(b'0123456789')
        status, body, headers = self.call('GET', '/out/e1', headers={'Range': 'bytes=2-4'})
        self.assertEqual((status, body), (206, b'234'))
        self.assertEqual(headers['Content-Range'], 'bytes 2-4/10')
        status, _, headers = self.call('HEAD', '/out/e1')
        self.assertEqual((status, headers['Content-Length']), (200, '10'))
        self.assertEqual(self.call('DELETE', '/out/e1')[0], 200)
        self.assertFalse(os.path.exists(self.w.output('e1')))
        self.assertNotIn('e1', self.w.status()['episodes'])

    def test_shader_upload(self):
        self.assertEqual(self.call('PUT', '/shader', b'//!HOOK MAIN')[0], 200)
        with open(os.path.join(self.root, 'shader.glsl'), 'rb') as f:
            self.assertEqual(f.read(), b'//!HOOK MAIN')

    def test_bad_ids_are_not_found(self):
        self.assertEqual(self.call('GET', '/out/a.b')[0], 404)
        self.assertEqual(self.call('GET', '/out/e1/x')[0], 404)

    def test_chunked_body_is_refused(self):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_address[1], timeout=5)
        self.call('PUT', '/in/e1/parts/0', b'hello')
        # The server closes on refusal; on Windows the client may see the
        # reset before the 411. Either way the commit must not go through.
        try:
            conn.request('POST', '/in/e1/commit', body=iter([b'{"size": 5}']),
                         headers={'X-Kazumi-Token': TOKEN}, encode_chunked=True)
            self.assertEqual(conn.getresponse().status, 411)
        except ConnectionError:
            pass
        conn.close()
        self.assertEqual(self.w.status()['episodes']['e1']['state'], 'receiving')

    def test_cap_endpoint_raises_the_cap(self):
        self.w.cap_sec = 3600
        status, body, _ = self.call('POST', '/cap', json.dumps({'capSec': 7200}).encode())
        self.assertEqual((status, json.loads(body)), (200, {'capSec': 7200}))
        self.assertEqual(self.w.status()['capSec'], 7200)

    def test_shutdown_terminates(self):
        self.assertEqual(self.call('POST', '/shutdown', b'')[0], 200)
        self.assertTrue(self.terminated.wait(5))


if __name__ == '__main__':
    unittest.main()
