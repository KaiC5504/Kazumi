# Cloud Bake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One menu item on a show rents a Sydney L40S on Runpod, which bakes the season alongside the laptop, then deletes itself.

**Architecture:** A stdlib Python worker (a Flutter asset, gzip+base64 in the pod's env) serves an HTTP API on the pod's public TCP port, guarded by a per-run token. On the app side, `RunpodApi` talks to Runpod REST v2 and `CloudBakeWorkerClient` talks to the worker over parted transfers. `CloudBakeSession` is a plain Dart scheduler with injected dependencies: the cloud takes episodes from the front, the laptop from the back. `UpscaleController` owns the session, and the download page shows a banner and ☁ status text.

**Tech Stack:** Flutter/Dart (dart:io `HttpClient`, MobX, Hive settings via `GStorage`), Python 3 stdlib (`http.server`, `unittest`), Runpod REST v2 + GraphQL `podTerminate`.

**Spec:** `docs/superpowers/specs/2026-10-06-cloud-bake-design.md`

## Global Constraints

- Fork rules from `CLAUDE.md`:
  - `dart format` only files this fork added. Never run it on upstream files; hand-format edits there to match the surrounding style.
  - Don't bump dependencies.
  - Add no new packages: `url_launcher`, `mobx`, `flutter_mobx`, `path` and `flutter_test` are already there.
- Never commit secrets. The Runpod API key lives only in Hive (`SettingsKeys.runpodApiKey`); tests use fake keys like `rk_test`.
- GPU and place, exactly:
  - GPU id `NVIDIA L40S`, data center `OC-AU-1`, cloud `SECURE`.
  - Image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`.
  - Disk 50 GB, port `8080/tcp`, env `NVIDIA_DRIVER_CAPABILITIES=all`.
- Encoder settings must match the PC bake:
  - NVENC: `-c:v hevc_nvenc -preset p5 -rc vbr -cq 22 -b:v 0`, format `p010le`.
  - Vulkan fallback: `-c:v hevc_vulkan -rc_mode cqp -qp 19 -tune hq`, format `p010`.
  - Both: `-profile:v main10 -tag:v hvc1 -movflags +faststart`. Audio is `-c:a copy`, then a retry with `-c:a aac -b:a 192k`.
- Worker header `X-Kazumi-Token`, token from the pod env `KAZUMI_TOKEN` (32 random bytes, base64url).
- Self-destruct: 600 s after the last authenticated request (counted from boot completion), or at `KAZUMI_CAP_SEC`. Cap = `max(1800, 1.5 × estimated cloud seconds)`.
- Estimate constants: cloud 7.7× realtime, laptop 2.7× realtime, startup 300 s.
- The cloud keeps at most 2 episodes waiting beyond the 2 baking, so at most 4 handed over at once. At most 2 downloads at once. Poll every 5 s. Give up on a pod that isn't ready after 5 min. A pod with no successful `/status` for 10 min counts as lost.
- UI copy is Chinese, exactly as written in the tasks below.
- Desktop only: everything is gated on `UpscaleController.canBake`.

## Changes from the spec, found while planning (2026-10-06)

1. **Self-destruct uses GraphQL, not runpodctl or REST.**
   - The pod's own `RUNPOD_API_KEY` gets 403 on REST v2.
   - It authenticates on `https://api.runpod.io/graphql`. `podTerminate` on a fake id returned `POD_NOT_FOUND` (with the owner's user id), not `UNAUTHORIZED`, and `pod(input:{podId})` on its own pod returned data.
   - So the worker calls `mutation { podTerminate(input: {podId: "<RUNPOD_POD_ID>"}) }` itself.
   - Final proof: the manual pod's watchdog deleting itself at the end of today's run. Task 8 checks it again live.
2. **Env size is fine.** A CPU pod accepted an 8 KB env value (`hq94cxjxkugqdc`, deleted). The worker ships in env, with no bootstrap fallback. A test keeps the packed worker ≤ 8000 characters.
3. **REST v2 is pinned** (base `https://api.runpod.io`):
   - `GET /v2/catalog/gpus/{id}?include=AVAILABILITY&product=POD&cloud=SECURE` returns `price.secure` and `dataCenters[{id, availability}]`. Availability is one of `HIGH/MEDIUM/LOW/NONE`; OC-AU-1 showed `LOW`.
   - `POST /v2/pods` accepts the body fields above plus `entrypoint`/`cmd`.
   - `GET /v2/pods/{id}` returns `runtime.ports[{private, public, ip, type}]`, `status`, `cost` and `createdAt`.
   - `DELETE /v2/pods/{id}` returns 204, or 404 when it's already gone. `GET /v2/pods` returns `{pods: [...]}`.
   - Errors are `application/problem+json` `{title, status, detail}`.
4. **The pod is released as soon as the cloud has nothing left to do,** not after the laptop's last episode. That saves money; the estimate's `cloudSec` follows this.
5. **`cloudBakeActivePod` is dropped.** Every pod the app makes is named `kazumi-bake-<6 chars>`, so the startup check lists pods by that prefix.
6. **The banner shows done counts** ("☁ 3 · 本机 1 · 共 25 集"), not x/y, because the split between lanes is decided as the run goes.
7. **HLS downloads are remuxed first.** Episodes stored as a playlist plus segments are remuxed (`-c copy`) into `upscaled/cloud_input.mkv` before upload and deleted after. Single-file downloads upload as-is.
8. **When fallbacks go to the laptop:**
   - A failed upload, a pod that never gets ready, and a lost pod always hand their episodes to the laptop, even with 同时用本机烘焙 off.
   - Only a pod-side ffmpeg failure follows the switch: laptop if on, `failed` if off, as in the spec.
9. **No SSH on the pod.** The pod's entrypoint is overridden by the worker start command.
10. **Too few episodes.** If the estimate gives the cloud 0 episodes (for example, one episode with the laptop lane on), nothing is rented. The flow toasts 集数太少，本机烘焙更快 and queues a local bake-all.

## Review Focus

1. **An episode stored as `.m3u8` plus segments** (most sources other than aafun). It must reach the pod as one file, and the pod must not see a playlist pointing at missing segments. Covered by `cloudRemuxArgs` in Task 6.
2. **The owner baking an episode the cloud session holds,** via the episode's ✨ button or 全部烘焙超分. It must not bake twice. Covered by `holds()` in Task 5 and the `enqueueBake` guard in Task 6.
3. **The app killed or the PC asleep mid-run.** The pod must delete itself within about 10.5 min, and the next app start must offer to delete any leftover. Covered by the watchdog tests in Task 1, the `leftoverPods` test in Task 6, and the kill test in Task 8.
4. **A show with too few episodes for the cloud to help.** Nothing must be rented. Covered by the single-episode estimate in Task 2 and the flow branch in Task 7.
5. **ffprobe can't read the duration (0).** The estimate must use 1440 s, and the worker's progress must not divide by zero. Covered by the estimate test in Task 2 and the `max(1, durationSec)` test in Task 1.

Also covered: a stale `.part` from an earlier stopped run is discarded before downloading (Task 5).

---

## File Structure

| File | Role |
|---|---|
| `assets/cloud/kazumi_bake_worker.py` (new) | Pod worker: boot, encoder probe, HTTP API, 2 bake slots, watchdog |
| `test/cloud_worker/test_kazumi_bake_worker.py` (new) | Python `unittest` for the worker (run locally; CI runs Dart only) |
| `lib/services/upscale/cloud/cloud_worker_script.dart` (new) | Packs the worker for env, start command |
| `lib/services/upscale/cloud/cloud_bake_estimate.dart` (new) | Lane simulation, cost, cap |
| `lib/services/upscale/cloud/runpod_api.dart` (new) | `CloudPodApi` interface + Runpod REST v2 client |
| `lib/services/upscale/cloud/cloud_bake_worker_client.dart` (new) | `CloudWorker` interface + HTTP client for the worker |
| `lib/services/upscale/cloud/cloud_bake_session.dart` (new) | The scheduler: lanes, polling, downloads, fallbacks, stop, release |
| `lib/services/upscale/upscale_controller.dart` | `_finishBake`, GPU lock, quote/start/stop, leftovers |
| `lib/services/storage/settings_keys.dart` | `runpodApiKey`, `cloudBakeIncludeLocal` |
| `lib/pages/download/cloud_bake_sheets.dart` (new) | Flow, confirm sheet, no-stock dialog, banner, leftover dialog, status text |
| `lib/pages/download/download_page.dart` | Menu item, banner, ☁ status, hide cancel on cloud-held |
| `lib/pages/settings/download_settings.dart` | 云端烘焙 (Runpod) section |
| `lib/pages/init_page.dart` | Leftover pod check after start-up |
| `pubspec.yaml` | Asset `assets/cloud/kazumi_bake_worker.py` |
| `test/cloud_worker_script_test.dart`, `test/cloud_bake_estimate_test.dart`, `test/runpod_api_test.dart`, `test/cloud_bake_worker_client_test.dart`, `test/cloud_bake_session_test.dart`, `test/cloud_bake_controller_test.dart`, `test/cloud_bake_sheets_test.dart` (new) | Dart tests |

---

### Task 1: Pod worker

**Files:**
- Create: `assets/cloud/kazumi_bake_worker.py`
- Create: `test/cloud_worker/test_kazumi_bake_worker.py`
- Create: `lib/services/upscale/cloud/cloud_worker_script.dart`
- Create: `test/cloud_worker_script_test.dart`
- Modify: `pubspec.yaml` (assets list, after `- assets/statements/`)

**Interfaces:**
- Produces, as the HTTP contract (all requests need `X-Kazumi-Token`, otherwise 403):
  - `GET /status` returns `{state, error, encoder, slots, uptimeSec, capSec, episodes: {id: {state, progress, outBytes, error}}}`.
  - `PUT /shader` takes the GLSL body.
  - `GET /in/{id}/parts` returns `{parts: {"0": bytes, ...}}`.
  - `PUT /in/{id}/parts/{n}` takes a raw body.
  - `POST /in/{id}/commit` takes `{size, durationSec, height}` and returns 200 `{error: null}` or 409 `{error}`.
  - `GET`/`HEAD /out/{id}` supports `Range`. `DELETE /out/{id}`. `POST /shutdown`.
  - Episode ids match `^[A-Za-z0-9_-]{1,64}$`.
- Produces, in Dart:
  - `const cloudWorkerAsset = 'assets/cloud/kazumi_bake_worker.py'`
  - `const maxPackedWorkerLength = 8000`
  - `String packWorkerScript(String source)`
  - `const cloudWorkerStartCommand`

- [ ] **Step 1: Write the failing Python tests**

`test/cloud_worker/test_kazumi_bake_worker.py`:

```python
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
    os.path.join(HERE, '..', '..', 'assets', 'cloud', 'kazumi_bake_worker.py'))
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

    def test_shutdown_terminates(self):
        self.assertEqual(self.call('POST', '/shutdown', b'')[0], 200)
        self.assertTrue(self.terminated.wait(5))


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest discover -s test/cloud_worker -v`

Expected: an error at import (`FileNotFoundError` for `kazumi_bake_worker.py`).

- [ ] **Step 3: Write the worker**

`assets/cloud/kazumi_bake_worker.py`:

```python
#!/usr/bin/env python3
# Kazumi cloud bake worker. Runs on a rented Runpod GPU: takes episodes over
# HTTP, bakes them with the same Anime4K chain and encoder settings as the PC,
# serves the results back, and deletes its own pod once the PC goes quiet.
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SLOTS = 2
ID_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
NVENC = (['-c:v', 'hevc_nvenc', '-preset', 'p5', '-rc', 'vbr', '-cq', '22', '-b:v', '0'], 'p010le')
VULKAN = (['-c:v', 'hevc_vulkan', '-rc_mode', 'cqp', '-qp', '19', '-tune', 'hq'], 'p010')
FFMPEG_RELEASES = 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest'
FFMPEG_FALLBACK = ('https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/'
                   'ffmpeg-n8.0-latest-linux64-gpl-8.0.tar.xz')


def log(message):
    print(time.strftime('%H:%M:%S'), message, flush=True)


class Worker:
    def __init__(self, root, token, cap_sec, idle_sec=600, clock=time.monotonic):
        self.root = root
        self.token = token
        self.cap_sec = cap_sec
        self.idle_sec = idle_sec
        self.clock = clock
        self.started = clock()
        self.last_contact = None
        self.state = 'booting'
        self.error = None
        self.ffmpeg = None
        self.encoder = None
        self.episodes = {}
        self.queue = []
        self.cond = threading.Condition()
        for name in ('in', 'out'):
            os.makedirs(os.path.join(root, name), exist_ok=True)

    def part_dir(self, ep):
        return os.path.join(self.root, 'in', ep)

    def source(self, ep):
        return os.path.join(self.root, 'in', ep + '.src')

    def output(self, ep):
        return os.path.join(self.root, 'out', ep + '.mp4')

    def ready(self, ffmpeg, encoder):
        self.ffmpeg, self.encoder = ffmpeg, encoder
        self.state = 'ready'
        self.last_contact = self.clock()

    def broken(self, error):
        self.state, self.error = 'broken', error
        self.last_contact = self.clock()

    def touch(self):
        # The idle clock only starts once boot is over; downloading ffmpeg can
        # take a while and nobody is talking to us yet.
        if self.last_contact is not None:
            self.last_contact = self.clock()

    def expired(self):
        now = self.clock()
        if now - self.started > self.cap_sec:
            return 'cap'
        if self.last_contact is not None and now - self.last_contact > self.idle_sec:
            return 'idle'
        return None

    def parts(self, ep):
        d = self.part_dir(ep)
        if not os.path.isdir(d):
            return {}
        return {int(n): os.path.getsize(os.path.join(d, n)) for n in os.listdir(d) if n.isdigit()}

    def put_part(self, ep, index, stream, length):
        d = self.part_dir(ep)
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, '%d.tmp' % index)
        left = length
        with open(tmp, 'wb') as f:
            while left > 0:
                chunk = stream.read(min(1 << 20, left))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        if left:
            os.remove(tmp)
            raise IOError('part %d ended %d bytes early' % (index, left))
        os.replace(tmp, os.path.join(d, str(index)))
        with self.cond:
            self.episodes.setdefault(ep, self._entry('receiving'))

    def commit(self, ep, size, duration_sec, height):
        with self.cond:
            if self.episodes.get(ep, {}).get('state') in ('queued', 'baking', 'done'):
                return None
        if self.state != 'ready':
            return 'worker is %s' % self.state
        parts = self.parts(ep)
        total = sum(parts.values())
        if total != size or sorted(parts) != list(range(len(parts))):
            return 'have %d bytes in %d parts, expected %d' % (total, len(parts), size)
        with open(self.source(ep), 'wb') as out:
            for i in range(len(parts)):
                with open(os.path.join(self.part_dir(ep), str(i)), 'rb') as f:
                    shutil.copyfileobj(f, out, 1 << 20)
        shutil.rmtree(self.part_dir(ep), ignore_errors=True)
        with self.cond:
            entry = self._entry('queued')
            entry.update(durationSec=duration_sec, height=height)
            self.episodes[ep] = entry
            self.queue.append(ep)
            self.cond.notify()
        return None

    @staticmethod
    def _entry(state):
        return {'state': state, 'progress': 0.0, 'outBytes': 0, 'error': None}

    def status(self):
        with self.cond:
            episodes = {k: {f: v[f] for f in ('state', 'progress', 'outBytes', 'error')}
                        for k, v in self.episodes.items()}
        return {'state': self.state, 'error': self.error,
                'encoder': self.encoder[0][1] if self.encoder else None,
                'slots': SLOTS, 'uptimeSec': int(self.clock() - self.started),
                'capSec': self.cap_sec, 'episodes': episodes}

    def drop(self, ep):
        with self.cond:
            self.episodes.pop(ep, None)
        for p in (self.output(ep), self.source(ep)):
            try:
                os.remove(p)
            except OSError:
                pass

    def slot(self):
        while True:
            self.bake_next()

    def bake_next(self):
        with self.cond:
            while not self.queue:
                self.cond.wait()
            ep = self.queue.pop(0)
            info = self.episodes[ep]
            info['state'] = 'baking'
        error = None
        for copy_audio in (True, False):
            error = self.bake(ep, info, copy_audio)
            if error is None:
                break
            log('%s failed (copy_audio=%s): %s' % (ep, copy_audio, error))
        try:
            os.remove(self.source(ep))
        except OSError:
            pass
        with self.cond:
            if error is None:
                info.update(state='done', progress=1.0, outBytes=os.path.getsize(self.output(ep)))
            else:
                info.update(state='failed', error=error)

    def bake(self, ep, info, copy_audio):
        args, fmt = self.encoder
        height = info['height']
        part = self.output(ep) + '.part'
        cmd = [self.ffmpeg, '-hide_banner', '-y', '-nostats', '-loglevel', 'error',
               '-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk',
               '-i', self.source(ep), '-map', '0:v:0', '-map', '0:a:0?',
               '-vf', 'libplacebo=w=trunc(iw*%d/ih/2)*2:h=%d:custom_shader_path=shader.glsl:format=%s'
               % (height, height, fmt),
               *args, '-profile:v', 'main10', '-tag:v', 'hvc1',
               *(['-c:a', 'copy'] if copy_audio else ['-c:a', 'aac', '-b:a', '192k']),
               '-movflags', '+faststart', '-progress', 'pipe:1', '-f', 'mp4', part]
        duration_us = max(1.0, float(info['durationSec'])) * 1e6

        def on_line(line):
            if line.startswith('out_time_us='):
                try:
                    info['progress'] = min(1.0, max(0.0, int(line[12:]) / duration_us))
                except ValueError:
                    pass

        code, err = self.run_ffmpeg(cmd, on_line)
        if code != 0:
            lines = err.strip().splitlines()
            return 'ffmpeg %d: %s' % (code, lines[-1] if lines else '')
        os.replace(part, self.output(ep))
        return None

    def run_ffmpeg(self, cmd, on_line):
        p = subprocess.Popen(cmd, cwd=self.root, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        err = []
        reader = threading.Thread(target=lambda: err.append(p.stderr.read()))
        reader.start()
        for line in p.stdout:
            on_line(line.strip())
        p.wait()
        reader.join()
        return p.returncode, ''.join(err)


def terminate_pod(url='https://api.runpod.io/graphql'):
    # The pod's own key is refused by REST v2 but GraphQL accepts it, and
    # podTerminate is scoped to the account that owns the pod.
    pod = os.environ.get('RUNPOD_POD_ID', '')
    query = 'mutation { podTerminate(input: {podId: "%s"}) }' % pod
    req = urllib.request.Request(url, json.dumps({'query': query}).encode(), {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + os.environ.get('RUNPOD_API_KEY', ''),
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.loads(r.read() or b'{}')
    if body.get('errors'):
        raise RuntimeError(body['errors'][0].get('message'))


def watchdog(worker, terminate=terminate_pod, interval=30, sleep=time.sleep):
    while True:
        reason = worker.expired()
        if reason:
            log('terminating pod (%s)' % reason)
            try:
                terminate()
                return
            except Exception as e:
                log('terminate failed: %s' % e)
        sleep(interval)


def fetch_ffmpeg(root):
    url = FFMPEG_FALLBACK
    try:
        with urllib.request.urlopen(FFMPEG_RELEASES, timeout=30) as r:
            assets = [a['browser_download_url'] for a in json.load(r)['assets']]
        # Master builds need a newer driver (610+) than Runpod hosts carry;
        # the n8.x release builds don't.
        found = [u for u in assets
                 if re.search(r'/ffmpeg-n8\.\d+-latest-linux64-gpl-8\.\d+\.tar\.xz$', u)]
        if found:
            url = sorted(found)[-1]
    except Exception as e:
        log('release lookup failed, using fallback: %s' % e)
    archive = os.path.join(root, 'ffmpeg.tar.xz')
    urllib.request.urlretrieve(url, archive)
    with tarfile.open(archive) as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith('/bin/ffmpeg'))
        member.name = 'ffmpeg'
        tar.extract(member, root, filter='data')
    os.remove(archive)
    exe = os.path.join(root, 'ffmpeg')
    os.chmod(exe, 0o755)
    return exe


def write_icd(root):
    # The image's GLX ICD can't create a Vulkan instance without a display;
    # the EGL one can.
    path = os.path.join(root, 'egl_icd.json')
    with open(path, 'w') as f:
        json.dump({'file_format_version': '1.0.1',
                   'ICD': {'library_path': 'libEGL_nvidia.so.0', 'api_version': '1.4.312'}}, f)
    os.environ['VK_ICD_FILENAMES'] = path


def probe_encoder(ffmpeg, root):
    # Some hosts refuse NVENC sessions ("unsupported device"), so try a real
    # encode before trusting it.
    for args, fmt in (NVENC, VULKAN):
        cmd = [ffmpeg, '-hide_banner', '-loglevel', 'error',
               '-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk',
               '-f', 'lavfi', '-i', 'testsrc2=s=1920x1080:d=2',
               '-vf', 'libplacebo=w=2560:h=1440:format=%s' % fmt,
               *args, '-profile:v', 'main10', '-f', 'null', '-']
        result = subprocess.run(cmd, cwd=root, stdin=subprocess.DEVNULL, capture_output=True)
        if result.returncode == 0:
            return args, fmt
        log('%s probe failed: %s' % (args[1], result.stderr.decode(errors='replace')[-300:]))
    return None


def boot(worker):
    try:
        ffmpeg = fetch_ffmpeg(worker.root)
        write_icd(worker.root)
        encoder = probe_encoder(ffmpeg, worker.root)
        if encoder is None:
            worker.broken('no working HEVC encoder (NVENC and Vulkan both failed)')
        else:
            worker.ready(ffmpeg, encoder)
    except Exception as e:
        worker.broken('boot failed: %s' % e)
    log('boot: %s %s' % (worker.state, worker.error or ''))


def make_handler(worker, terminate):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.route('GET')

        def do_HEAD(self):
            self.route('HEAD')

        def do_PUT(self):
            self.route('PUT')

        def do_POST(self):
            self.route('POST')

        def do_DELETE(self):
            self.route('DELETE')

        def reply(self, code, body=None):
            data = json.dumps(body if body is not None else {}).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            if code >= 400:
                # The request body may be unread; don't reuse the connection.
                self.send_header('Connection', 'close')
                self.close_connection = True
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)

        def body(self):
            return self.rfile.read(int(self.headers.get('Content-Length', 0)))

        def route(self, method):
            if not hmac.compare_digest(self.headers.get('X-Kazumi-Token', ''), worker.token):
                return self.reply(403, {'error': 'forbidden'})
            worker.touch()
            parts = self.path.split('?')[0].strip('/').split('/')
            try:
                if parts == ['status'] and method == 'GET':
                    return self.reply(200, worker.status())
                if parts == ['shader'] and method == 'PUT':
                    with open(os.path.join(worker.root, 'shader.glsl'), 'wb') as f:
                        f.write(self.body())
                    return self.reply(200)
                if parts == ['shutdown'] and method == 'POST':
                    self.reply(200)
                    threading.Thread(target=terminate, daemon=True).start()
                    return
                if len(parts) >= 2 and ID_RE.match(parts[1]):
                    ep = parts[1]
                    if parts[0] == 'in':
                        if parts[2:] == ['parts'] and method == 'GET':
                            return self.reply(200, {'parts': {str(k): v for k, v in worker.parts(ep).items()}})
                        if len(parts) == 4 and parts[2] == 'parts' and parts[3].isdigit() and method == 'PUT':
                            worker.put_part(ep, int(parts[3]), self.rfile,
                                            int(self.headers.get('Content-Length', 0)))
                            return self.reply(200)
                        if parts[2:] == ['commit'] and method == 'POST':
                            req = json.loads(self.body() or b'{}')
                            error = worker.commit(ep, int(req['size']), float(req.get('durationSec', 0)),
                                                  int(req.get('height', 1440)))
                            return self.reply(409 if error else 200, {'error': error})
                    if parts[0] == 'out' and len(parts) == 2:
                        if method in ('GET', 'HEAD'):
                            return self.send_output(ep)
                        if method == 'DELETE':
                            worker.drop(ep)
                            return self.reply(200)
                self.reply(404, {'error': 'not found'})
            except Exception as e:
                log('%s %s failed: %s' % (method, self.path, e))
                self.reply(500, {'error': str(e)})

        def send_output(self, ep):
            path = worker.output(ep)
            if not os.path.exists(path):
                return self.reply(404, {'error': 'not ready'})
            size = os.path.getsize(path)
            start, end = 0, size
            match = re.match(r'bytes=(\d+)-(\d*)$', self.headers.get('Range', ''))
            if match:
                start = int(match.group(1))
                end = min(size, int(match.group(2)) + 1 if match.group(2) else size)
            self.send_response(206 if match else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(end - start))
            self.send_header('Accept-Ranges', 'bytes')
            if match:
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end - 1, size))
            self.end_headers()
            if self.command == 'HEAD':
                return
            with open(path, 'rb') as f:
                f.seek(start)
                left = end - start
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)

    return Handler


def main():
    token = os.environ.get('KAZUMI_TOKEN', '')
    if len(token) < 32:
        sys.exit('KAZUMI_TOKEN missing')
    root = os.environ.get('KAZUMI_ROOT', '/root/kazumi')
    worker = Worker(root, token, int(os.environ.get('KAZUMI_CAP_SEC', '7200')))
    for _ in range(SLOTS):
        threading.Thread(target=worker.slot, daemon=True).start()
    threading.Thread(target=boot, args=(worker,), daemon=True).start()
    threading.Thread(target=watchdog, args=(worker,), daemon=True).start()
    server = ThreadingHTTPServer(('0.0.0.0', 8080), make_handler(worker, terminate_pod))
    server.daemon_threads = True
    log('listening on 8080')
    server.serve_forever()


if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Run the Python tests to verify they pass**

Run: `python -m unittest discover -s test/cloud_worker -v`

Expected: 16 tests, all `ok`.

- [ ] **Step 5: Write the failing packing test**

`test/cloud_worker_script_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';

void main() {
  final source = File(cloudWorkerAsset).readAsStringSync();

  test('the packed worker fits in a pod env value', () {
    expect(packWorkerScript(source).length, lessThanOrEqualTo(maxPackedWorkerLength));
  });

  test('packing round-trips through base64 and gzip', () {
    final packed = packWorkerScript(source);
    expect(utf8.decode(gzip.decode(base64.decode(packed))), source);
  });

  test('the start command unpacks the env value and runs it', () {
    expect(cloudWorkerStartCommand, contains(r'"$KAZUMI_WORKER" | base64 -d | gunzip'));
    expect(cloudWorkerStartCommand, contains('exec python3 -u'));
  });
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `fvm flutter test test/cloud_worker_script_test.dart`

Expected: FAIL, because `cloud_worker_script.dart` doesn't exist.

- [ ] **Step 7: Write the packer and register the asset**

`lib/services/upscale/cloud/cloud_worker_script.dart`:

```dart
import 'dart:convert';
import 'dart:io';

const cloudWorkerAsset = 'assets/cloud/kazumi_bake_worker.py';

/// Runpod accepted an 8 KB env value when this was measured (2026-10-06).
const maxPackedWorkerLength = 8000;

/// The pod has no copy of the worker, so it travels in its env.
String packWorkerScript(String source) =>
    base64.encode(GZipCodec(level: 9).encode(utf8.encode(source)));

const cloudWorkerStartCommand =
    r'echo "$KAZUMI_WORKER" | base64 -d | gunzip > /kazumi_worker.py'
    r' && exec python3 -u /kazumi_worker.py';
```

In `pubspec.yaml`, add under `assets:` after `- assets/statements/`:

```yaml
    - assets/cloud/kazumi_bake_worker.py
```

- [ ] **Step 8: Run the Dart test to verify it passes**

Run: `fvm flutter test test/cloud_worker_script_test.dart`

Expected: 3 tests pass. If the size test fails, the worker grew past 8000 packed characters. Trim log strings rather than raising the limit; the limit is what was measured.

- [ ] **Step 9: Format and commit**

```bash
fvm dart format lib/services/upscale/cloud/cloud_worker_script.dart test/cloud_worker_script_test.dart
git add assets/cloud/kazumi_bake_worker.py test/cloud_worker/test_kazumi_bake_worker.py lib/services/upscale/cloud/cloud_worker_script.dart test/cloud_worker_script_test.dart pubspec.yaml
git commit -m "feat(upscale): pod worker that bakes episodes on a rented GPU"
```

---

### Task 2: Estimate

**Files:**
- Create: `lib/services/upscale/cloud/cloud_bake_estimate.dart`
- Test: `test/cloud_bake_estimate_test.dart`

**Interfaces:**
- Produces:
  - `class CloudBakeRates` (static consts).
  - `class CloudBakeEstimate`, with `cloudCount`, `localCount`, `cloudSec`, `finishSec`, `capSec`, `cost(double)` and `maxCost(double)`.
  - `CloudBakeEstimate.forDurations(List<int> durationsSec, {required bool includeLocal})`.

- [ ] **Step 1: Write the failing test**

`test/cloud_bake_estimate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';

void main() {
  // 1540 s bakes in 200 s on the pod (7.7x) and ~570 s on the laptop (2.7x).
  test('the laptop takes from the back while the pod starts up', () {
    final e = CloudBakeEstimate.forDurations([1540, 1540, 1540], includeLocal: true);
    expect((e.cloudCount, e.localCount), (2, 1));
    expect(e.cloudSec, 300 + 200 + 200 + 60);
    expect(e.finishSec, 760);
    expect(e.capSec, 1800);
  });

  test('cloud only puts every episode on the pod', () {
    final e = CloudBakeEstimate.forDurations([1540, 1540, 1540], includeLocal: false);
    expect((e.cloudCount, e.localCount), (3, 0));
    expect(e.cloudSec, 960);
  });

  test('an unknown duration counts as a 24-minute episode', () {
    final e = CloudBakeEstimate.forDurations([0], includeLocal: false);
    expect(e.cloudSec, (300 + 1440 / 7.7 + 60).ceil());
  });

  test('one episode with the laptop on never reaches the pod', () {
    final e = CloudBakeEstimate.forDurations([1440], includeLocal: true);
    expect((e.cloudCount, e.localCount, e.cloudSec), (0, 1, 0));
  });

  test('the cap is 1.5x the cloud time once that passes 30 minutes', () {
    final durations = List.filled(25, 1440);
    final e = CloudBakeEstimate.forDurations(durations, includeLocal: false);
    expect(e.capSec, (e.cloudSec * 1.5).ceil());
    expect(e.cost(1.09), closeTo(e.cloudSec / 3600 * 1.09, 1e-9));
    expect(e.maxCost(1.09), closeTo(e.capSec / 3600 * 1.09, 1e-9));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/cloud_bake_estimate_test.dart`

Expected: FAIL (the file doesn't exist).

- [ ] **Step 3: Implement**

`lib/services/upscale/cloud/cloud_bake_estimate.dart`:

```dart
import 'dart:math';

/// Measured on 2026-10-06 (see the cloud bake spec). Retune from logs here.
class CloudBakeRates {
  /// Two concurrent bakes on a Sydney L40S.
  static const cloudRealtime = 7.7;

  /// The laptop's RTX 4070; a second concurrent bake doesn't help.
  static const localRealtime = 2.7;
  static const startupSec = 300;
  static const downloadTailSec = 60;
  static const minCapSec = 1800;
  static const unknownDurationSec = 1440;
}

class CloudBakeEstimate {
  const CloudBakeEstimate({
    required this.cloudCount,
    required this.localCount,
    required this.cloudSec,
    required this.finishSec,
  });

  final int cloudCount;
  final int localCount;

  /// How long the pod lives: from creation until its last episode is home.
  final int cloudSec;
  final int finishSec;

  int get capSec =>
      max(CloudBakeRates.minCapSec, (cloudSec * 1.5).ceil());

  double cost(double pricePerHour) => cloudSec / 3600 * pricePerHour;

  double maxCost(double pricePerHour) => capSec / 3600 * pricePerHour;

  /// Plays both lanes over the season in order: the pod from the front once
  /// it has started, the laptop from the back, each taking the next episode
  /// as soon as it is free.
  factory CloudBakeEstimate.forDurations(
    List<int> durationsSec, {
    required bool includeLocal,
  }) {
    final d = [
      for (final s in durationsSec)
        s > 0 ? s : CloudBakeRates.unknownDurationSec,
    ];
    var front = 0;
    var back = d.length - 1;
    var cloudFree = CloudBakeRates.startupSec.toDouble();
    var localFree = includeLocal ? 0.0 : double.infinity;
    var cloudCount = 0;
    var localCount = 0;
    while (front <= back) {
      if (cloudFree <= localFree) {
        cloudFree += d[front++] / CloudBakeRates.cloudRealtime;
        cloudCount++;
      } else {
        localFree += d[back--] / CloudBakeRates.localRealtime;
        localCount++;
      }
    }
    final cloudSec = cloudCount == 0
        ? 0
        : (cloudFree + CloudBakeRates.downloadTailSec).ceil();
    final localSec = localCount == 0 ? 0 : localFree.ceil();
    return CloudBakeEstimate(
      cloudCount: cloudCount,
      localCount: localCount,
      cloudSec: cloudSec,
      finishSec: max(cloudSec, localSec),
    );
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `fvm flutter test test/cloud_bake_estimate_test.dart`

Expected: 5 pass.

- [ ] **Step 5: Format and commit**

```bash
fvm dart format lib/services/upscale/cloud/cloud_bake_estimate.dart test/cloud_bake_estimate_test.dart
git add lib/services/upscale/cloud/cloud_bake_estimate.dart test/cloud_bake_estimate_test.dart
git commit -m "feat(upscale): estimate a cloud bake's split, time and cost"
```

---

### Task 3: Runpod REST client

**Files:**
- Create: `lib/services/upscale/cloud/runpod_api.dart`
- Test: `test/runpod_api_test.dart`

**Interfaces:**
- Consumes: `cloudWorkerStartCommand` (Task 1).
- Produces:
  - `const cloudWorkerPort = 8080`, `const cloudPodNamePrefix = 'kazumi-bake-'`.
  - `RunpodException(message, {statusCode, noCapacity})`.
  - `CloudOffer(available, pricePerHour)`.
  - `CloudPodInfo(id, name, status, costPerHour, workerUri, createdAt)`, with `gone` and `CloudPodInfo.fromJson`.
  - `abstract class CloudPodApi`, with `sydneyOffer()`, `createPod({name, env, diskGb})`, `getPod(id)` (null when absent), `deletePod(id)` and `listPods()`.
  - `RunpodApi(apiKey, {Uri? base}) implements CloudPodApi`.
  - `RunpodException runpodError(int status, String body)`.

- [ ] **Step 1: Write the failing test**

`test/runpod_api_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';

class _Call {
  _Call(this.method, this.uri, this.auth, this.body);
  final String method;
  final Uri uri;
  final String? auth;
  final String body;
}

void main() {
  late HttpServer server;
  late List<_Call> calls;
  late (int, String) Function(_Call) respond;
  late RunpodApi api;

  setUp(() async {
    calls = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final call = _Call(
        request.method,
        request.uri,
        request.headers.value(HttpHeaders.authorizationHeader),
        await utf8.decodeStream(request),
      );
      calls.add(call);
      final (status, body) = respond(call);
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    api = RunpodApi('rk_test', base: Uri.parse('http://127.0.0.1:${server.port}'));
  });

  tearDown(() => server.close(force: true));

  test('reads Sydney stock and the secure price', () async {
    respond = (_) => (200, jsonEncode({
          'id': 'NVIDIA L40S',
          'price': {'secure': 1.09, 'community': 0.79},
          'dataCenters': [
            {'id': 'US-TX-3', 'availability': 'HIGH'},
            {'id': 'OC-AU-1', 'availability': 'LOW'},
          ],
        }));
    final offer = await api.sydneyOffer();
    expect((offer.available, offer.pricePerHour), (true, 1.09));
    expect(calls.single.auth, 'Bearer rk_test');
    expect(calls.single.uri.path, '/v2/catalog/gpus/NVIDIA%20L40S');
    expect(calls.single.uri.queryParameters, {
      'include': 'AVAILABILITY',
      'product': 'POD',
      'cloud': 'SECURE',
    });
  });

  test('no Sydney entry means no stock', () async {
    respond = (_) => (200, jsonEncode({
          'price': {'secure': 1.09},
          'dataCenters': [{'id': 'US-TX-3', 'availability': 'HIGH'}],
        }));
    expect((await api.sydneyOffer()).available, false);
  });

  test('creates the pod with the verified shape', () async {
    respond = (_) => (201, jsonEncode({
          'id': 'pod1',
          'name': 'kazumi-bake-abc123',
          'status': 'PROVISIONING',
          'cost': 1.09,
        }));
    final pod = await api.createPod(
      name: 'kazumi-bake-abc123',
      env: {'KAZUMI_TOKEN': 't'},
      diskGb: 50,
    );
    expect((pod.id, pod.costPerHour, pod.workerUri), ('pod1', 1.09, null));
    final body = jsonDecode(calls.single.body) as Map<String, dynamic>;
    expect(calls.single.method, 'POST');
    expect(calls.single.uri.path, '/v2/pods');
    expect(body['image'], 'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404');
    expect(body['cloud'], 'SECURE');
    expect(body['dataCenterIds'], ['OC-AU-1']);
    expect(body['gpu'], {'id': 'NVIDIA L40S', 'count': 1});
    expect(body['disk'], 50);
    expect(body['ports'], ['8080/tcp']);
    expect(body['env'], {'NVIDIA_DRIVER_CAPABILITIES': 'all', 'KAZUMI_TOKEN': 't'});
    expect(body['entrypoint'], ['/bin/bash', '-c']);
    expect((body['cmd'] as List).single, contains('KAZUMI_WORKER'));
  });

  test('finds the worker port in the pod runtime', () async {
    respond = (_) => (200, jsonEncode({
          'id': 'pod1',
          'name': 'kazumi-bake-abc123',
          'status': 'RUNNING',
          'cost': 1.09,
          'createdAt': '2026-10-06T05:24:17.081Z',
          'runtime': {
            'ports': [
              {'ip': '100.65.24.109', 'private': 19123, 'public': 60215, 'type': 'http'},
              {'ip': '160.250.71.215', 'private': 8080, 'public': 42651, 'type': 'tcp'},
            ],
          },
        }));
    final pod = await api.getPod('pod1');
    expect(pod!.workerUri, Uri.parse('http://160.250.71.215:42651'));
    expect(pod.createdAt, DateTime.utc(2026, 10, 6, 5, 24, 17, 81));
  });

  test('a missing pod reads as null and deletes quietly', () async {
    respond = (_) => (404, jsonEncode({'title': 'Not Found', 'status': 404, 'detail': 'pod not found'}));
    expect(await api.getPod('gone'), isNull);
    await api.deletePod('gone');
    expect(calls.map((c) => c.method), ['GET', 'DELETE']);
  });

  test('lists pods', () async {
    respond = (_) => (200, jsonEncode({
          'pods': [
            {'id': 'a', 'name': 'kazumi-bake-x', 'status': 'RUNNING', 'cost': 1.09},
          ],
        }));
    final pods = await api.listPods();
    expect(pods.single.name, 'kazumi-bake-x');
  });

  group('error mapping', () {
    String problem(String detail) => jsonEncode({'title': 'x', 'status': 400, 'detail': detail});

    test('401 is a bad key', () {
      expect(runpodError(401, problem('unauthorized')).message, 'Runpod API Key 无效');
    });
    test('balance problems say so', () {
      expect(runpodError(402, problem('Insufficient balance to deploy')).message, 'Runpod 余额不足');
    });
    test('capacity problems are flagged as no stock', () {
      final e = runpodError(409, problem('There are no instances currently available'));
      expect((e.noCapacity, e.message), (true, '悉尼暂无可用 GPU'));
    });
    test('anything else keeps the detail', () {
      expect(runpodError(500, problem('boom')).message, 'Runpod 返回错误 500: boom');
    });
  });

  test('errors from the server surface as RunpodException', () async {
    respond = (_) => (401, problem401);
    expect(api.sydneyOffer(), throwsA(isA<RunpodException>()));
  });
}

final problem401 = jsonEncode({'title': 'Unauthorized', 'status': 401, 'detail': 'bad key'});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/runpod_api_test.dart`

Expected: FAIL (`runpod_api.dart` doesn't exist).

- [ ] **Step 3: Implement**

`lib/services/upscale/cloud/runpod_api.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';

const cloudWorkerPort = 8080;
const cloudPodNamePrefix = 'kazumi-bake-';

class RunpodException implements Exception {
  const RunpodException(
    this.message, {
    this.statusCode,
    this.noCapacity = false,
  });

  final String message;
  final int? statusCode;
  final bool noCapacity;

  @override
  String toString() => message;
}

class CloudOffer {
  const CloudOffer({required this.available, required this.pricePerHour});

  final bool available;
  final double pricePerHour;
}

class CloudPodInfo {
  const CloudPodInfo({
    required this.id,
    required this.name,
    required this.status,
    required this.costPerHour,
    this.workerUri,
    this.createdAt,
  });

  final String id;
  final String name;
  final String status;
  final double costPerHour;

  /// Where the worker listens, once Runpod has mapped its port.
  final Uri? workerUri;
  final DateTime? createdAt;

  bool get gone => status == 'TERMINATED';

  factory CloudPodInfo.fromJson(Map<String, dynamic> json) {
    Uri? worker;
    final runtime = json['runtime'] as Map<String, dynamic>?;
    for (final entry in runtime?['ports'] as List? ?? const []) {
      final port = entry as Map<String, dynamic>;
      if (port['private'] == cloudWorkerPort &&
          port['type'] == 'tcp' &&
          port['ip'] is String &&
          port['public'] is int) {
        worker = Uri(
          scheme: 'http',
          host: port['ip'] as String,
          port: port['public'] as int,
        );
      }
    }
    return CloudPodInfo(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      costPerHour: (json['cost'] as num?)?.toDouble() ?? 0,
      workerUri: worker,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

/// What a cloud bake needs from Runpod; the session is tested against a fake.
abstract class CloudPodApi {
  Future<CloudOffer> sydneyOffer();

  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  });

  /// Null once the pod no longer exists.
  Future<CloudPodInfo?> getPod(String id);

  Future<void> deletePod(String id);

  Future<List<CloudPodInfo>> listPods();
}

/// Runpod REST v2 (https://api.runpod.io/v2/openapi.json).
class RunpodApi implements CloudPodApi {
  RunpodApi(this.apiKey, {Uri? base})
    : base = base ?? Uri.parse('https://api.runpod.io');

  final String apiKey;
  final Uri base;

  static const gpuId = 'NVIDIA L40S';
  static const dataCenterId = 'OC-AU-1';

  /// The image the 2026-10-06 runs were verified on (driver 580, python3).
  static const image = 'runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404';

  @override
  Future<CloudOffer> sydneyOffer() async {
    final json = await _request(
      'GET',
      ['v2', 'catalog', 'gpus', gpuId],
      query: {'include': 'AVAILABILITY', 'product': 'POD', 'cloud': 'SECURE'},
    );
    final price = (json['price'] as Map<String, dynamic>?)?['secure'] as num?;
    String availability = 'NONE';
    for (final entry in json['dataCenters'] as List? ?? const []) {
      final center = entry as Map<String, dynamic>;
      if (center['id'] == dataCenterId) {
        availability = center['availability'] as String? ?? 'NONE';
      }
    }
    return CloudOffer(
      available: availability != 'NONE',
      pricePerHour: price?.toDouble() ?? 0,
    );
  }

  @override
  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  }) async {
    final json = await _request(
      'POST',
      ['v2', 'pods'],
      body: {
        'name': name,
        'image': image,
        'cloud': 'SECURE',
        'dataCenterIds': [dataCenterId],
        'gpu': {'id': gpuId, 'count': 1},
        'disk': diskGb,
        'ports': ['$cloudWorkerPort/tcp'],
        // Without this the container gets no graphics libraries, so no Vulkan.
        'env': {'NVIDIA_DRIVER_CAPABILITIES': 'all', ...env},
        'entrypoint': ['/bin/bash', '-c'],
        'cmd': [cloudWorkerStartCommand],
      },
    );
    return CloudPodInfo.fromJson(json);
  }

  @override
  Future<CloudPodInfo?> getPod(String id) async {
    try {
      return CloudPodInfo.fromJson(await _request('GET', ['v2', 'pods', id]));
    } on RunpodException catch (e) {
      if (e.statusCode == HttpStatus.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<void> deletePod(String id) async {
    try {
      await _request('DELETE', ['v2', 'pods', id]);
    } on RunpodException catch (e) {
      if (e.statusCode != HttpStatus.notFound) rethrow;
    }
  }

  @override
  Future<List<CloudPodInfo>> listPods() async {
    final json = await _request('GET', ['v2', 'pods']);
    return [
      for (final pod in json['pods'] as List? ?? const [])
        CloudPodInfo.fromJson(pod as Map<String, dynamic>),
    ];
  }

  Future<Map<String, dynamic>> _request(
    String method,
    List<String> segments, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = base.replace(pathSegments: segments, queryParameters: query);
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw runpodError(response.statusCode, text);
      }
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw const RunpodException('无法连接到 Runpod');
    } on TimeoutException {
      throw const RunpodException('连接 Runpod 超时');
    } finally {
      client.close(force: true);
    }
  }
}

@visibleForTesting
RunpodException runpodError(int status, String body) {
  var detail = body;
  try {
    final json = jsonDecode(body);
    if (json is Map) {
      detail = '${json['detail'] ?? json['title'] ?? json['error'] ?? body}';
    }
  } on FormatException {
    // Not JSON; keep the raw body.
  }
  final lower = detail.toLowerCase();
  if (status == HttpStatus.unauthorized) {
    return RunpodException('Runpod API Key 无效', statusCode: status);
  }
  if (lower.contains('balance') ||
      lower.contains('insufficient funds') ||
      lower.contains('credit')) {
    return RunpodException('Runpod 余额不足', statusCode: status);
  }
  if (status == HttpStatus.forbidden) {
    return RunpodException('Runpod API Key 权限不足 (需要读写权限)', statusCode: status);
  }
  if (lower.contains('capacity') ||
      lower.contains('no instances') ||
      lower.contains('not available') ||
      lower.contains('no available')) {
    return RunpodException('悉尼暂无可用 GPU', statusCode: status, noCapacity: true);
  }
  return RunpodException('Runpod 返回错误 $status: $detail', statusCode: status);
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `fvm flutter test test/runpod_api_test.dart`

Expected: all pass. If the `path` assertion fails on encoding, `Uri.pathSegments` encodes the space as `%20`; assert against `calls.single.uri.pathSegments.last == 'NVIDIA L40S'` instead. Don't change the request.

- [ ] **Step 5: Format and commit**

```bash
fvm dart format lib/services/upscale/cloud/runpod_api.dart test/runpod_api_test.dart
git add lib/services/upscale/cloud/runpod_api.dart test/runpod_api_test.dart
git commit -m "feat(upscale): Runpod REST client for renting the Sydney GPU"
```

---

### Task 4: Worker client

**Files:**
- Create: `lib/services/upscale/cloud/cloud_bake_worker_client.dart`
- Test: `test/cloud_bake_worker_client_test.dart`

**Interfaces:**
- Consumes: `runParts`, `downloadInParts`, `partCount`, `partLength` and `transferPartSize` from `package:kazumi/services/download/parted_transfer.dart`.
- Produces:
  - `CloudWorkerException(message, {statusCode})`.
  - `WorkerEpisode(state, progress, outBytes, error)`.
  - `WorkerStatus(state, episodes, encoder, error)`.
  - `abstract class CloudWorker`, with `status()`, `putShader(String)`, `upload(id, File, {onProgress, stopped})`, `commit(id, {size, durationSec, height})`, `download(id, File target, {expectedBytes, onProgress, stopped})`, `drop(id)` and `shutdown()`.
  - `CloudBakeWorkerClient(Uri base, String token, {int partSize})`.

- [ ] **Step 1: Write the failing test**

`test/cloud_bake_worker_client_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:path/path.dart' as path;

const _token = 'tok_tok_tok_tok_tok_tok_tok_tok_tok_tok';

/// A worker that keeps parts in memory and serves [output] for episode e1.
class _FakeWorker {
  final parts = <int, List<int>>{};
  final putIndices = <int>[];
  final ranges = <String>[];
  List<int> output = [];
  late HttpServer server;

  Future<Uri> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
    return Uri.parse('http://127.0.0.1:${server.port}');
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    if (request.headers.value('X-Kazumi-Token') != _token) {
      res.statusCode = 403;
      return res.close();
    }
    final p = request.uri.pathSegments;
    if (p.join('/') == 'status') {
      res.write(jsonEncode({
        'state': 'ready',
        'encoder': 'hevc_nvenc',
        'episodes': {
          'e1': {'state': 'baking', 'progress': 0.25, 'outBytes': 0, 'error': null},
        },
      }));
    } else if (p.length == 3 && p[2] == 'parts' && request.method == 'GET') {
      res.write(jsonEncode({
        'parts': {for (final e in parts.entries) '${e.key}': e.value.length},
      }));
    } else if (p.length == 4 && request.method == 'PUT') {
      final index = int.parse(p[3]);
      putIndices.add(index);
      parts[index] = body;
      res.write('{}');
    } else if (p.first == 'out' && request.method == 'HEAD') {
      res.contentLength = output.length;
    } else if (p.first == 'out' && request.method == 'GET') {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(range);
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final start = int.parse(m[1]!);
      final end = int.parse(m[2]!) + 1;
      res.statusCode = HttpStatus.partialContent;
      res.add(output.sublist(start, end));
    } else {
      res.statusCode = 404;
    }
    await res.close();
  }
}

void main() {
  late _FakeWorker fake;
  late CloudBakeWorkerClient client;
  late Directory dir;

  setUp(() async {
    fake = _FakeWorker();
    final base = await fake.start();
    client = CloudBakeWorkerClient(base, _token, partSize: 4);
    dir = Directory.systemTemp.createTempSync('cloud_client_');
  });

  tearDown(() async {
    await fake.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('reads status', () async {
    final status = await client.status();
    expect(status.state, 'ready');
    expect(status.episodes['e1']!.progress, 0.25);
  });

  test('a wrong token is reported with its status code', () async {
    final bad = CloudBakeWorkerClient(
      Uri.parse('http://127.0.0.1:${fake.server.port}'),
      'nope',
    );
    expect(
      bad.status(),
      throwsA(isA<CloudWorkerException>().having((e) => e.statusCode, 'status', 403)),
    );
  });

  test('upload skips parts the worker already has', () async {
    final source = File(path.join(dir.path, 'in.mkv'))
      ..writeAsBytesSync(utf8.encode('0123456789'));
    fake.parts[0] = utf8.encode('0123');
    var last = 0;
    await client.upload('e1', source, onProgress: (n) => last = n);
    expect(fake.putIndices..sort(), [1, 2]);
    expect(utf8.decode([...fake.parts[0]!, ...fake.parts[1]!, ...fake.parts[2]!]), '0123456789');
    expect(last, 10);
  });

  test('download resumes from the parts log', () async {
    fake.output = utf8.encode('abcdefghij');
    final target = File(path.join(dir.path, 'video.mp4'));
    File('${target.path}.part').writeAsBytesSync(utf8.encode('abcd'));
    File('${target.path}.parts').writeAsStringSync('0\n');
    await client.download('e1', target, expectedBytes: 10);
    expect(target.readAsStringSync(), 'abcdefghij');
    expect(fake.ranges.any((r) => r.startsWith('bytes=0-')), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('download refuses a size that disagrees with the status', () async {
    fake.output = Uint8List(10);
    final target = File(path.join(dir.path, 'video.mp4'));
    expect(
      client.download('e1', target, expectedBytes: 99),
      throwsA(isA<CloudWorkerException>()),
    );
    expect(target.existsSync(), isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/cloud_bake_worker_client_test.dart`

Expected: FAIL (the file doesn't exist).

- [ ] **Step 3: Implement**

`lib/services/upscale/cloud/cloud_bake_worker_client.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/download/parted_transfer.dart';

class CloudWorkerException implements Exception {
  const CloudWorkerException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class WorkerEpisode {
  const WorkerEpisode({
    required this.state,
    required this.progress,
    required this.outBytes,
    this.error,
  });

  /// receiving, queued, baking, done or failed.
  final String state;
  final double progress;
  final int outBytes;
  final String? error;

  factory WorkerEpisode.fromJson(Map<String, dynamic> json) => WorkerEpisode(
    state: json['state'] as String? ?? '',
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    outBytes: (json['outBytes'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );
}

class WorkerStatus {
  const WorkerStatus({
    required this.state,
    required this.episodes,
    this.encoder,
    this.error,
  });

  /// booting, ready or broken.
  final String state;
  final Map<String, WorkerEpisode> episodes;
  final String? encoder;
  final String? error;

  factory WorkerStatus.fromJson(Map<String, dynamic> json) => WorkerStatus(
    state: json['state'] as String? ?? '',
    encoder: json['encoder'] as String?,
    error: json['error'] as String?,
    episodes: {
      for (final e in (json['episodes'] as Map<String, dynamic>? ?? {}).entries)
        e.key: WorkerEpisode.fromJson(e.value as Map<String, dynamic>),
    },
  );
}

/// The worker on a cloud bake pod; the session is tested against a fake.
abstract class CloudWorker {
  Future<WorkerStatus> status();

  Future<void> putShader(String glsl);

  Future<void> upload(
    String id,
    File source, {
    void Function(int sent)? onProgress,
    bool Function()? stopped,
  });

  Future<void> commit(
    String id, {
    required int size,
    required double durationSec,
    required int height,
  });

  /// Fetches the finished file into [target], resuming a partial one.
  Future<void> download(
    String id,
    File target, {
    required int expectedBytes,
    void Function(int received)? onProgress,
    bool Function()? stopped,
  });

  Future<void> drop(String id);

  Future<void> shutdown();
}

class CloudBakeWorkerClient implements CloudWorker {
  CloudBakeWorkerClient(
    this.base,
    this.token, {
    this.partSize = transferPartSize,
  });

  static const tokenHeader = 'X-Kazumi-Token';
  static const _timeout = Duration(seconds: 30);

  final Uri base;
  final String token;
  final int partSize;

  @override
  Future<WorkerStatus> status() async =>
      WorkerStatus.fromJson(await _json('GET', ['status']));

  @override
  Future<void> putShader(String glsl) =>
      _json('PUT', ['shader'], raw: utf8.encode(glsl));

  @override
  Future<void> upload(
    String id,
    File source, {
    void Function(int sent)? onProgress,
    bool Function()? stopped,
  }) async {
    bool isStopped() => stopped?.call() ?? false;
    final size = await source.length();
    final json = await _json('GET', ['in', id, 'parts']);
    final done = {
      for (final e in (json['parts'] as Map<String, dynamic>? ?? {}).entries)
        int.parse(e.key): (e.value as num).toInt(),
    };
    int lengthOf(int i) => partLength(i, size, partSize);

    final pending = <int>[];
    var sent = 0;
    for (var i = 0; i < partCount(size, partSize); i++) {
      if (done[i] == lengthOf(i)) {
        sent += lengthOf(i);
      } else {
        pending.add(i);
      }
    }
    final inFlight = <int, int>{};
    void report() => onProgress?.call(
      sent + inFlight.values.fold<int>(0, (sum, n) => sum + n),
    );
    report();

    await runParts(
      pending: pending,
      attempts: 8,
      stopped: isStopped,
      transfer: (index) async {
        try {
          await _putPart(id, source, index, (n) {
            inFlight[index] = n;
            report();
          }, size);
        } finally {
          inFlight.remove(index);
        }
        sent += lengthOf(index);
        report();
      },
    );
    if (isStopped()) throw const CloudWorkerException('已停止');
  }

  Future<void> _putPart(
    String id,
    File source,
    int index,
    void Function(int sent) onProgress,
    int size,
  ) async {
    final start = index * partSize;
    final end = start + partLength(index, size, partSize);
    final client = _client();
    try {
      final request = await client.openUrl(
        'PUT',
        base.replace(pathSegments: ['in', id, 'parts', '$index']),
      );
      request.headers.set(tokenHeader, token);
      request.headers.contentType = ContentType.binary;
      request.contentLength = end - start;
      var sent = 0;
      await request.addStream(
        source.openRead(start, end).map((chunk) {
          sent += chunk.length;
          onProgress(sent);
          return chunk;
        }),
      );
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      _check(response.statusCode);
    } on SocketException {
      throw const CloudWorkerException('上传中断');
    } on HttpException {
      throw const CloudWorkerException('上传中断');
    } on TimeoutException {
      throw const CloudWorkerException('上传超时');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> commit(
    String id, {
    required int size,
    required double durationSec,
    required int height,
  }) => _json(
    'POST',
    ['in', id, 'commit'],
    body: {'size': size, 'durationSec': durationSec, 'height': height},
  );

  @override
  Future<void> download(
    String id,
    File target, {
    required int expectedBytes,
    void Function(int received)? onProgress,
    bool Function()? stopped,
  }) async {
    bool isStopped() => stopped?.call() ?? false;
    final size = await _outputSize(id);
    if (size != expectedBytes) {
      throw CloudWorkerException('云端文件大小不符 ($size / $expectedBytes)');
    }
    final tmp = File('${target.path}.part');
    final complete = await downloadInParts(
      tmpFile: tmp,
      partsLog: File('${target.path}.parts'),
      totalSize: size,
      partSize: partSize,
      stopped: isStopped,
      onProgress: onProgress,
      openRange: (start, end) => _openRange(id, start, end),
    );
    if (!complete) throw const CloudWorkerException('已停止');
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
  }

  Future<int> _outputSize(String id) async {
    final client = _client();
    try {
      final request = await client.openUrl(
        'HEAD',
        base.replace(pathSegments: ['out', id]),
      );
      request.headers.set(tokenHeader, token);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>();
      _check(response.statusCode);
      return response.contentLength;
    } on SocketException {
      throw const CloudWorkerException('无法连接到云端 GPU');
    } on TimeoutException {
      throw const CloudWorkerException('连接云端 GPU 超时');
    } finally {
      client.close(force: true);
    }
  }

  Future<Stream<List<int>>> _openRange(String id, int start, int end) async {
    final client = _client();
    try {
      final request = await client.openUrl(
        'GET',
        base.replace(pathSegments: ['out', id]),
      );
      request.headers.set(tokenHeader, token);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        throw CloudWorkerException(
          '云端返回 ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return response
          .timeout(const Duration(seconds: 60))
          .transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleError: (error, stackTrace, sink) {
                client.close(force: true);
                sink.addError(error, stackTrace);
              },
              handleDone: (sink) {
                client.close(force: true);
                sink.close();
              },
            ),
          );
    } catch (e) {
      client.close(force: true);
      if (e is SocketException) {
        throw const CloudWorkerException('无法连接到云端 GPU');
      }
      rethrow;
    }
  }

  @override
  Future<void> drop(String id) => _json('DELETE', ['out', id]);

  @override
  Future<void> shutdown() => _json('POST', ['shutdown']);

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Future<Map<String, dynamic>> _json(
    String method,
    List<String> segments, {
    Map<String, dynamic>? body,
    List<int>? raw,
  }) async {
    final client = _client();
    try {
      final request = await client.openUrl(
        method,
        base.replace(pathSegments: segments),
      );
      request.headers.set(tokenHeader, token);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      } else if (raw != null) {
        request.headers.contentType = ContentType.binary;
        request.contentLength = raw.length;
        request.add(raw);
      }
      final response = await request.close().timeout(_timeout);
      final text = await utf8.decodeStream(response);
      if (response.statusCode == HttpStatus.conflict) {
        final error = text.isEmpty ? null : jsonDecode(text)['error'];
        throw CloudWorkerException('云端拒绝: $error', statusCode: 409);
      }
      _check(response.statusCode);
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    } on SocketException {
      throw const CloudWorkerException('无法连接到云端 GPU');
    } on HttpException {
      throw const CloudWorkerException('与云端 GPU 的连接中断');
    } on TimeoutException {
      throw const CloudWorkerException('连接云端 GPU 超时');
    } finally {
      client.close(force: true);
    }
  }

  void _check(int status) {
    if (status < 200 || status >= 300) {
      throw CloudWorkerException('云端返回 $status', statusCode: status);
    }
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `fvm flutter test test/cloud_bake_worker_client_test.dart`

Expected: 5 pass.

- [ ] **Step 5: Format and commit**

```bash
fvm dart format lib/services/upscale/cloud/cloud_bake_worker_client.dart test/cloud_bake_worker_client_test.dart
git add lib/services/upscale/cloud/cloud_bake_worker_client.dart test/cloud_bake_worker_client_test.dart
git commit -m "feat(upscale): client for the cloud bake worker with resumable transfers"
```

---

### Task 5: Session (the scheduler)

**Files:**
- Create: `lib/services/upscale/cloud/cloud_bake_session.dart`
- Test: `test/cloud_bake_session_test.dart`

**Interfaces:**
- Consumes:
  - `CloudPodApi`, `CloudPodInfo`, `CloudOffer`, `RunpodException` and `cloudPodNamePrefix` (Task 3).
  - `CloudWorker`, `WorkerStatus` and `CloudWorkerException` (Task 4).
  - `CloudBakeEstimate` (Task 2).
- Produces:
  - `enum CloudBakePhase { starting, running, finishing, done, stopped }`.
  - `enum CloudEpisodeStage { uploading, waiting, baking, downloading }`.
  - `class CloudEpisodePhase(stage, [progress])`.
  - `enum LocalBakeOutcome { done, failed, cancelled }`.
  - `class CloudJob({recordKey, episodeNumber, durationSec, outputPath})`, with `id`.
  - `class CloudBakeException(message)`.
  - `class CloudBakeQuote({recordKey, jobs, offer, estimate, includeLocal, height})`.
  - `class CloudBakeSessionView`, with `phase`, `cloudDone`, `localDone`, `failed`, `total`, `startedAt`, `podStartedAt`, `podEndedAt`, `pricePerHour`, `message`, `costAt(DateTime)` and `summary(DateTime)`.
  - `class CloudBakeSession`, with `run()`, `stop()`, `holds(int)`, `view` and `recordKey`.
  - `String newCloudToken()`.

- [ ] **Step 1: Write the failing test**

`test/cloud_bake_session_test.dart`:

```dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:path/path.dart' as path;

class FakePodApi implements CloudPodApi {
  FakePodApi({this.readyAfterPolls = 0, this.createError});

  final int readyAfterPolls;
  final Object? createError;
  final created = <Map<String, String>>[];
  final names = <String>[];
  final deleted = <String>[];
  var exists = false;
  var polls = 0;

  @override
  Future<CloudOffer> sydneyOffer() async =>
      const CloudOffer(available: true, pricePerHour: 1.09);

  @override
  Future<CloudPodInfo> createPod({
    required String name,
    required Map<String, String> env,
    required int diskGb,
  }) async {
    if (createError != null) throw createError!;
    exists = true;
    created.add(env);
    names.add(name);
    return CloudPodInfo(id: 'pod1', name: name, status: 'PROVISIONING', costPerHour: 1.09);
  }

  @override
  Future<CloudPodInfo?> getPod(String id) async {
    if (!exists) return null;
    polls++;
    return CloudPodInfo(
      id: id,
      name: 'kazumi-bake-x',
      status: 'RUNNING',
      costPerHour: 1.09,
      workerUri: polls > readyAfterPolls ? Uri.parse('http://pod:1') : null,
    );
  }

  @override
  Future<void> deletePod(String id) async {
    deleted.add(id);
    exists = false;
  }

  @override
  Future<List<CloudPodInfo>> listPods() async => [];
}

class FakeWorker implements CloudWorker {
  final episodes = <String, WorkerEpisode>{};
  final failIds = <String>{};
  final uploadFailIds = <String>{};
  final shaders = <String>[];
  final drops = <String>[];
  var bakeForever = false;
  var goDarkAfterStatus = 1 << 30;
  var statusCalls = 0;
  var shutdowns = 0;

  @override
  Future<WorkerStatus> status() async {
    if (++statusCalls > goDarkAfterStatus) {
      throw const CloudWorkerException('down');
    }
    return WorkerStatus(state: 'ready', episodes: Map.of(episodes));
  }

  @override
  Future<void> putShader(String glsl) async => shaders.add(glsl);

  @override
  Future<void> upload(String id, File source,
      {void Function(int sent)? onProgress, bool Function()? stopped}) async {
    if (uploadFailIds.contains(id)) throw const CloudWorkerException('upload broke');
    onProgress?.call(await source.length());
  }

  @override
  Future<void> commit(String id,
      {required int size, required double durationSec, required int height}) async {
    episodes[id] = failIds.contains(id)
        ? const WorkerEpisode(state: 'failed', progress: 0, outBytes: 0, error: 'boom')
        : bakeForever
            ? const WorkerEpisode(state: 'baking', progress: 0.5, outBytes: 0)
            : const WorkerEpisode(state: 'done', progress: 1, outBytes: 3);
  }

  @override
  Future<void> download(String id, File target,
      {required int expectedBytes,
      void Function(int received)? onProgress,
      bool Function()? stopped}) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes([1, 2, 3]);
  }

  @override
  Future<void> drop(String id) async {
    drops.add(id);
    episodes.remove(id);
  }

  @override
  Future<void> shutdown() async => shutdowns++;
}

void main() {
  late Directory dir;
  late List<int> cloudBaked, localBaked, returned, failed;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloud_session_');
    cloudBaked = [];
    localBaked = [];
    returned = [];
    failed = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CloudBakeSession make(
    FakePodApi api,
    FakeWorker worker, {
    required bool includeLocal,
    int count = 4,
    Duration localTime = Duration.zero,
    Duration readyTimeout = const Duration(seconds: 2),
  }) {
    return CloudBakeSession(
      api: api,
      connect: (uri, token) => worker,
      recordKey: 'r',
      jobs: [
        for (var i = 1; i <= count; i++)
          CloudJob(
            recordKey: 'r',
            episodeNumber: i,
            durationSec: 1440,
            outputPath: path.join(dir.path, '$i', 'upscaled', 'video.mp4'),
          ),
      ],
      includeLocal: includeLocal,
      workerScript: 'packed',
      capSec: 1800,
      pricePerHour: 1.09,
      shader: '//!HOOK MAIN',
      targetHeight: 1440,
      prepareInput: (job) async {
        final f = File(path.join(dir.path, 'in_${job.episodeNumber}'));
        await f.writeAsBytes([0]);
        return (f, true);
      },
      bakeLocally: (job) async {
        await Future.delayed(localTime);
        localBaked.add(job.episodeNumber);
        return LocalBakeOutcome.done;
      },
      onCloudBaked: (job) async => cloudBaked.add(job.episodeNumber),
      onReturned: (job) async => returned.add(job.episodeNumber),
      onFailed: (job, error) async => failed.add(job.episodeNumber),
      pollInterval: const Duration(milliseconds: 1),
      readyTimeout: readyTimeout,
      lostAfter: const Duration(milliseconds: 30),
      deleteTimeout: const Duration(milliseconds: 50),
    );
  }

  Future<void> runIt(CloudBakeSession s) =>
      s.run().timeout(const Duration(seconds: 10));

  test('cloud only: every episode goes to the pod, which is deleted after', () async {
    final api = FakePodApi();
    final worker = FakeWorker();
    final s = make(api, worker, includeLocal: false);
    expect(s.holds(1), isTrue);
    await runIt(s);
    expect(cloudBaked..sort(), [1, 2, 3, 4]);
    expect(localBaked, isEmpty);
    expect(api.deleted, ['pod1']);
    expect(worker.shutdowns, 1);
    expect(worker.shaders, ['//!HOOK MAIN']);
    expect(api.names.single, startsWith('kazumi-bake-'));
    expect(api.created.single['KAZUMI_TOKEN']!.length, greaterThanOrEqualTo(32));
    expect(api.created.single['KAZUMI_CAP_SEC'], '1800');
    expect(api.created.single['KAZUMI_WORKER'], 'packed');
    expect(s.view.phase, CloudBakePhase.done);
    expect(s.holds(1), isFalse);
  });

  test('the laptop takes from the back', () async {
    final s = make(FakePodApi(), FakeWorker(),
        includeLocal: true, localTime: const Duration(milliseconds: 40));
    await runIt(s);
    expect(localBaked.first, 4);
    expect(cloudBaked, contains(1));
    expect({...localBaked, ...cloudBaked}, {1, 2, 3, 4});
    expect(localBaked.length + cloudBaked.length, 4);
  });

  test('a pod-side failure goes to the laptop when it is on', () async {
    final worker = FakeWorker()..failIds.add('ep2');
    final s = make(FakePodApi(), worker,
        includeLocal: true, localTime: const Duration(milliseconds: 40));
    await runIt(s);
    expect(localBaked, contains(2));
    expect(cloudBaked, isNot(contains(2)));
    expect(failed, isEmpty);
  });

  test('without the laptop a pod-side failure marks the episode failed', () async {
    final worker = FakeWorker()..failIds.add('ep2');
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(failed, [2]);
    expect(cloudBaked..sort(), [1, 3, 4]);
    expect(localBaked, isEmpty);
  });

  test('a failed upload goes to the laptop even when it is off', () async {
    final worker = FakeWorker()..uploadFailIds.add('ep1');
    await runIt(make(FakePodApi(), worker, includeLocal: false));
    expect(localBaked, [1]);
    expect(cloudBaked..sort(), [2, 3, 4]);
  });

  test('a pod that never gets ready is deleted and the laptop bakes all', () async {
    final api = FakePodApi(readyAfterPolls: 1 << 30);
    final s = make(api, FakeWorker(),
        includeLocal: false, readyTimeout: const Duration(milliseconds: 20));
    await runIt(s);
    expect(localBaked..sort(), [1, 2, 3, 4]);
    expect(api.deleted, ['pod1']);
    expect(s.view.message, contains('启动超时'));
  });

  test('no stock at creation means the laptop bakes all and nothing is deleted', () async {
    final api = FakePodApi(
        createError: const RunpodException('悉尼暂无可用 GPU', noCapacity: true));
    final s = make(api, FakeWorker(), includeLocal: false);
    await runIt(s);
    expect(localBaked..sort(), [1, 2, 3, 4]);
    expect(api.deleted, isEmpty);
    expect(s.view.message, '悉尼暂无可用 GPU');
  });

  test('losing the pod hands its episodes to the laptop', () async {
    final api = FakePodApi();
    final worker = FakeWorker()
      ..bakeForever = true
      ..goDarkAfterStatus = 2;
    final s = make(api, worker, includeLocal: false);
    await runIt(s);
    expect(localBaked..sort(), [1, 2, 3, 4]);
    expect(api.deleted, ['pod1']);
    expect(s.view.message, contains('失去联系'));
  });

  test('stop deletes the pod and returns what is unfinished', () async {
    final api = FakePodApi();
    final worker = FakeWorker()..bakeForever = true;
    final s = make(api, worker, includeLocal: false);
    final running = runIt(s);
    while (worker.episodes.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 1));
    }
    await s.stop();
    await running;
    expect(api.deleted, ['pod1']);
    expect(returned..sort(), [1, 2, 3, 4]);
    expect(localBaked, isEmpty);
    expect(s.view.phase, CloudBakePhase.stopped);
  });

  test('a partial download left by an earlier run is discarded', () async {
    final stale = File(path.join(dir.path, '1', 'upscaled', 'video.mp4.part'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    File('${path.withoutExtension(stale.path)}.parts').writeAsStringSync('0\n');
    await runIt(make(FakePodApi(), FakeWorker(), includeLocal: false, count: 1));
    expect(stale.existsSync(), isFalse);
    expect(File(path.join(dir.path, '1', 'upscaled', 'video.mp4')).readAsBytesSync(), [1, 2, 3]);
  });

  test('cost runs from pod creation to deletion', () {
    final start = DateTime(2026, 10, 6, 12);
    final view = CloudBakeSessionView(
      phase: CloudBakePhase.done,
      cloudDone: 2,
      localDone: 1,
      failed: 0,
      total: 3,
      startedAt: start,
      podStartedAt: start,
      podEndedAt: start.add(const Duration(hours: 1)),
      pricePerHour: 1.09,
    );
    expect(view.costAt(start.add(const Duration(hours: 5))), closeTo(1.09, 1e-9));
    expect(view.summary(start.add(const Duration(minutes: 68))),
        '云端烘焙完成 · 3 集 · 68 分钟 · \$1.09');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/cloud_bake_session_test.dart`

Expected: FAIL (`cloud_bake_session.dart` doesn't exist).

- [ ] **Step 3: Implement**

`lib/services/upscale/cloud/cloud_bake_session.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';

enum CloudBakePhase { starting, running, finishing, done, stopped }

enum CloudEpisodeStage { uploading, waiting, baking, downloading }

class CloudEpisodePhase {
  const CloudEpisodePhase(this.stage, [this.progress = 0]);

  final CloudEpisodeStage stage;
  final double progress;
}

enum LocalBakeOutcome { done, failed, cancelled }

class CloudBakeException implements Exception {
  const CloudBakeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CloudJob {
  const CloudJob({
    required this.recordKey,
    required this.episodeNumber,
    required this.durationSec,
    required this.outputPath,
  });

  final String recordKey;
  final int episodeNumber;
  final int durationSec;

  /// Where the baked video ends up: `<episode>/upscaled/video.mp4`.
  final String outputPath;

  /// A session covers one show, so the episode number is unique on the pod.
  String get id => 'ep$episodeNumber';
}

class CloudBakeQuote {
  const CloudBakeQuote({
    required this.recordKey,
    required this.jobs,
    required this.offer,
    required this.estimate,
    required this.includeLocal,
    required this.height,
  });

  final String recordKey;
  final List<CloudJob> jobs;
  final CloudOffer offer;
  final CloudBakeEstimate estimate;
  final bool includeLocal;
  final int height;
}

class CloudBakeSessionView {
  const CloudBakeSessionView({
    required this.phase,
    required this.cloudDone,
    required this.localDone,
    required this.failed,
    required this.total,
    required this.startedAt,
    required this.pricePerHour,
    this.podStartedAt,
    this.podEndedAt,
    this.message,
  });

  final CloudBakePhase phase;
  final int cloudDone;
  final int localDone;
  final int failed;
  final int total;
  final DateTime startedAt;
  final DateTime? podStartedAt;
  final DateTime? podEndedAt;
  final double pricePerHour;
  final String? message;

  double costAt(DateTime now) {
    final start = podStartedAt;
    if (start == null) return 0;
    final end = podEndedAt ?? now;
    return end.difference(start).inSeconds / 3600 * pricePerHour;
  }

  String summary(DateTime now) {
    final minutes = now.difference(startedAt).inMinutes;
    final cost = '\$${costAt(now).toStringAsFixed(2)}';
    if (phase == CloudBakePhase.stopped) return '已停止云端烘焙 · 费用 $cost';
    final failedText = failed > 0 ? ' · $failed 集失败' : '';
    return '云端烘焙完成 · ${cloudDone + localDone} 集 · $minutes 分钟 · $cost$failedText';
  }
}

String newCloudToken() {
  final random = Random.secure();
  return base64Url
      .encode([for (var i = 0; i < 32; i++) random.nextInt(256)])
      .replaceAll('=', '');
}

String _podName() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return cloudPodNamePrefix +
      String.fromCharCodes([
        for (var i = 0; i < 6; i++)
          chars.codeUnitAt(random.nextInt(chars.length)),
      ]);
}

/// One cloud bake of one show. The pod takes episodes from the front of the
/// list and the laptop from the back until nothing is left. Anything the pod
/// can't finish falls back to the laptop, and the pod is deleted as soon as
/// it has nothing left to do.
class CloudBakeSession {
  CloudBakeSession({
    required this.api,
    required this.connect,
    required this.recordKey,
    required List<CloudJob> jobs,
    required this.includeLocal,
    required this.workerScript,
    required this.capSec,
    required this.pricePerHour,
    required this.shader,
    required this.targetHeight,
    required this.prepareInput,
    required this.bakeLocally,
    required this.onCloudBaked,
    required this.onReturned,
    required this.onFailed,
    this.onPhase,
    this.onChanged,
    this.pollInterval = const Duration(seconds: 5),
    this.readyTimeout = const Duration(minutes: 5),
    this.lostAfter = const Duration(minutes: 10),
    this.deleteTimeout = const Duration(minutes: 2),
  }) : _pending = List.of(jobs),
       total = jobs.length,
       token = newCloudToken(),
       _startedAt = DateTime.now();

  static const maxHanded = 4;
  static const maxDownloads = 2;

  final CloudPodApi api;
  final CloudWorker Function(Uri base, String token) connect;
  final String recordKey;
  final bool includeLocal;
  final String workerScript;
  final int capSec;
  final double pricePerHour;
  final String shader;
  final int targetHeight;

  /// The file to upload, and whether it is a temporary to delete afterwards.
  final Future<(File, bool)> Function(CloudJob job) prepareInput;
  final Future<LocalBakeOutcome> Function(CloudJob job) bakeLocally;
  final Future<void> Function(CloudJob job) onCloudBaked;

  /// A stopped run gives these back unbaked.
  final Future<void> Function(CloudJob job) onReturned;
  final Future<void> Function(CloudJob job, String error) onFailed;
  final void Function(CloudJob job, CloudEpisodePhase? phase)? onPhase;
  final void Function(CloudBakeSessionView view)? onChanged;
  final Duration pollInterval;
  final Duration readyTimeout;
  final Duration lostAfter;
  final Duration deleteTimeout;
  final int total;
  final String token;

  final List<CloudJob> _pending;
  final List<CloudJob> _fallback = [];
  final Map<String, CloudJob> _held = {};
  final Set<String> _downloading = {};
  final Set<String> _freshDownloads = {};
  CloudJob? _local;
  CloudWorker? _worker;
  String? _podId;
  Future<void>? _release;
  Completer<void> _signal = Completer<void>();
  final DateTime _startedAt;
  DateTime? _podStartedAt;
  DateTime? _podEndedAt;
  double? _podPrice;
  bool _stopped = false;
  bool _lost = false;
  bool _cloudOver = false;
  bool _uploadsOver = false;
  int _cloudDone = 0;
  int _localDone = 0;
  int _failed = 0;
  CloudBakePhase _phase = CloudBakePhase.starting;
  String? _message;

  CloudBakeSessionView get view => CloudBakeSessionView(
    phase: _phase,
    cloudDone: _cloudDone,
    localDone: _localDone,
    failed: _failed,
    total: total,
    startedAt: _startedAt,
    podStartedAt: _podStartedAt,
    podEndedAt: _podEndedAt,
    pricePerHour: _podPrice ?? pricePerHour,
    message: _message,
  );

  /// True while the session still owes this episode a bake.
  bool holds(int episodeNumber) =>
      _pending.any((j) => j.episodeNumber == episodeNumber) ||
      _fallback.any((j) => j.episodeNumber == episodeNumber) ||
      _held.values.any((j) => j.episodeNumber == episodeNumber) ||
      _local?.episodeNumber == episodeNumber;

  Future<void> run() async {
    _notify();
    final local = _localLane();
    await _cloudLane();
    _cloudOver = true;
    _wake();
    await local;
    _phase = _stopped ? CloudBakePhase.stopped : CloudBakePhase.done;
    _notify();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _phase = CloudBakePhase.finishing;
    final unstarted = [..._pending, ..._fallback];
    _pending.clear();
    _fallback.clear();
    for (final job in unstarted) {
      await onReturned(job);
    }
    _wake();
    _notify();
    await _releasePod();
  }

  Future<void> _localLane() async {
    while (!_stopped) {
      final job = _nextLocal();
      if (job == null) {
        if (_cloudOver && _pending.isEmpty && _fallback.isEmpty) return;
        await _waitWake();
        continue;
      }
      _local = job;
      _notify();
      final outcome = await bakeLocally(job);
      _local = null;
      if (outcome == LocalBakeOutcome.done) _localDone++;
      if (outcome == LocalBakeOutcome.failed) _failed++;
      _notify();
      _wake();
    }
  }

  CloudJob? _nextLocal() {
    if (_fallback.isNotEmpty) return _fallback.removeAt(0);
    if ((includeLocal || _cloudOver) && _pending.isNotEmpty) {
      return _pending.removeLast();
    }
    return null;
  }

  Future<void> _cloudLane() async {
    try {
      final pod = await api.createPod(
        name: _podName(),
        diskGb: 50,
        env: {
          'KAZUMI_TOKEN': token,
          'KAZUMI_CAP_SEC': '$capSec',
          'KAZUMI_WORKER': workerScript,
        },
      );
      _podId = pod.id;
      _podStartedAt = DateTime.now();
      if (pod.costPerHour > 0) _podPrice = pod.costPerHour;
      _notify();
      if (_stopped) return;
      final worker = await _waitReady(pod.id);
      _worker = worker;
      await worker.putShader(shader);
      if (_stopped) return;
      _phase = CloudBakePhase.running;
      _notify();
      await Future.wait([_uploadLoop(worker), _pollLoop(worker)]);
    } catch (e) {
      if (!_stopped) {
        _message = e is RunpodException || e is CloudBakeException
            ? '$e'
            : '云端烘焙出错: $e';
        KazumiLogger().w('CloudBakeSession: cloud lane ended', error: e);
      }
    } finally {
      for (final job in _held.values.toList()) {
        _held.remove(job.id);
        onPhase?.call(job, null);
        if (_stopped) {
          await onReturned(job);
        } else {
          _fallback.add(job);
        }
      }
      if (!_stopped) _phase = CloudBakePhase.finishing;
      _wake();
      _notify();
      await _releasePod();
    }
  }

  Future<CloudWorker> _waitReady(String podId) async {
    final deadline = DateTime.now().add(readyTimeout);
    while (!_stopped) {
      CloudPodInfo? pod;
      try {
        pod = await api.getPod(podId);
      } on RunpodException catch (e) {
        KazumiLogger().w('CloudBakeSession: pod poll failed: $e');
      }
      final uri = pod?.workerUri;
      if (uri != null) {
        final worker = connect(uri, token);
        WorkerStatus? status;
        try {
          status = await worker.status();
        } on CloudWorkerException {
          // Still booting: the port is mapped before the worker listens.
        }
        if (status?.state == 'ready') return worker;
        if (status?.state == 'broken') {
          throw CloudBakeException('云端 GPU 环境异常: ${status!.error}');
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const CloudBakeException('云端 GPU 启动超时，改用本机烘焙');
      }
      await Future.delayed(pollInterval);
    }
    throw const CloudBakeException('已停止');
  }

  Future<void> _uploadLoop(CloudWorker worker) async {
    try {
      while (!_stopped && !_lost && _pending.isNotEmpty) {
        if (_held.length >= maxHanded) {
          await _waitWake();
          continue;
        }
        final job = _pending.removeAt(0);
        _held[job.id] = job;
        _setPhase(job, const CloudEpisodePhase(CloudEpisodeStage.uploading));
        (File, bool)? input;
        try {
          input = await prepareInput(job);
          final file = input.$1;
          final size = await file.length();
          await worker.upload(
            job.id,
            file,
            stopped: () => _stopped || _lost,
            onProgress: (sent) => _setPhase(
              job,
              CloudEpisodePhase(
                CloudEpisodeStage.uploading,
                size == 0 ? 0 : sent / size,
              ),
            ),
          );
          await worker.commit(
            job.id,
            size: size,
            durationSec: job.durationSec.toDouble(),
            height: targetHeight,
          );
          _setPhase(job, const CloudEpisodePhase(CloudEpisodeStage.waiting));
        } catch (e) {
          if (_stopped) return;
          KazumiLogger().w(
            'CloudBakeSession: upload of ${job.id} failed, laptop takes it',
            error: e,
          );
          _held.remove(job.id);
          _setPhase(job, null);
          _fallback.add(job);
        } finally {
          if (input != null && input.$2) {
            try {
              await input.$1.delete();
            } on FileSystemException {
              // Already gone.
            }
          }
          _wake();
        }
      }
    } finally {
      _uploadsOver = true;
      _wake();
    }
  }

  Future<void> _pollLoop(CloudWorker worker) async {
    var lastOk = DateTime.now();
    final downloads = <Future<void>>[];
    while (!_stopped) {
      if (_uploadsOver && _held.isEmpty) break;
      WorkerStatus? status;
      try {
        status = await worker.status();
        lastOk = DateTime.now();
      } on CloudWorkerException catch (e) {
        if (DateTime.now().difference(lastOk) > lostAfter) {
          KazumiLogger().w('CloudBakeSession: pod unreachable: $e');
          _lost = true;
          _message = '与云端 GPU 失去联系，剩余剧集改用本机烘焙';
          _wake();
          break;
        }
      }
      if (status != null) {
        for (final job in _held.values.toList()) {
          final episode = status.episodes[job.id];
          if (episode == null || _downloading.contains(job.id)) continue;
          switch (episode.state) {
            case 'queued':
              _setPhase(job, const CloudEpisodePhase(CloudEpisodeStage.waiting));
            case 'baking':
              _setPhase(
                job,
                CloudEpisodePhase(CloudEpisodeStage.baking, episode.progress),
              );
            case 'done':
              if (_downloading.length < maxDownloads) {
                downloads.add(_download(worker, job, episode.outBytes));
              }
            case 'failed':
              _held.remove(job.id);
              _setPhase(job, null);
              unawaited(worker.drop(job.id).then((_) {}, onError: (_) {}));
              if (includeLocal) {
                _fallback.add(job);
              } else {
                _failed++;
                await onFailed(job, '云端烘焙失败: ${episode.error}');
              }
              _wake();
          }
        }
      }
      await _waitWake();
    }
    await Future.wait(downloads);
  }

  Future<void> _download(CloudWorker worker, CloudJob job, int bytes) async {
    _downloading.add(job.id);
    try {
      // A .part from an earlier run holds another encode's bytes; only
      // resume within this session.
      if (_freshDownloads.add(job.id)) {
        for (final suffix in const ['.part', '.parts']) {
          final stale = File('${job.outputPath}$suffix');
          if (await stale.exists()) await stale.delete();
        }
      }
      await worker.download(
        job.id,
        File(job.outputPath),
        expectedBytes: bytes,
        stopped: () => _stopped,
        onProgress: (n) => _setPhase(
          job,
          CloudEpisodePhase(
            CloudEpisodeStage.downloading,
            bytes == 0 ? 0 : n / bytes,
          ),
        ),
      );
    } catch (e) {
      if (!_stopped) {
        KazumiLogger().w(
          'CloudBakeSession: download of ${job.id} failed, will retry',
          error: e,
        );
      }
      _downloading.remove(job.id);
      return;
    }
    _held.remove(job.id);
    _downloading.remove(job.id);
    _setPhase(job, null);
    _cloudDone++;
    try {
      await worker.drop(job.id);
    } catch (e) {
      KazumiLogger().w('CloudBakeSession: drop of ${job.id} failed', error: e);
    }
    try {
      await onCloudBaked(job);
    } catch (e) {
      KazumiLogger().e('CloudBakeSession: finishing ${job.id} failed', error: e);
    }
    _notify();
    _wake();
  }

  Future<void> _releasePod() {
    final id = _podId;
    if (id == null) return Future.value();
    return _release ??= _deletePod(id);
  }

  Future<void> _deletePod(String id) async {
    final worker = _worker;
    if (worker != null && !_lost) {
      try {
        // The worker also deletes its own pod; belt and braces.
        await worker.shutdown().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final deadline = DateTime.now().add(deleteTimeout);
    while (true) {
      try {
        await api.deletePod(id);
        final pod = await api.getPod(id);
        if (pod == null || pod.gone) break;
      } catch (e) {
        KazumiLogger().w('CloudBakeSession: deleting pod $id failed', error: e);
      }
      if (DateTime.now().isAfter(deadline)) {
        _message = '无法确认云端 GPU 已删除，请到 Runpod 控制台检查';
        break;
      }
      await Future.delayed(pollInterval);
    }
    _podEndedAt = DateTime.now();
    _notify();
  }

  void _setPhase(CloudJob job, CloudEpisodePhase? phase) =>
      onPhase?.call(job, phase);

  void _notify() => onChanged?.call(view);

  void _wake() {
    final signal = _signal;
    _signal = Completer<void>();
    signal.complete();
  }

  Future<void> _waitWake() =>
      Future.any([_signal.future, Future.delayed(pollInterval)]);
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `fvm flutter test test/cloud_bake_session_test.dart`

Expected: 11 pass.

The "laptop takes from the back" test depends on timing (a 40 ms local bake against 1 ms polls). If it flakes, raise `localTime` to 100 ms rather than loosening the assertions.

- [ ] **Step 5: Format and commit**

```bash
fvm dart format lib/services/upscale/cloud/cloud_bake_session.dart test/cloud_bake_session_test.dart
git add lib/services/upscale/cloud/cloud_bake_session.dart test/cloud_bake_session_test.dart
git commit -m "feat(upscale): cloud bake session sharing a season between the pod and the laptop"
```

---

### Task 6: Settings and controller

**Files:**
- Modify: `lib/services/storage/settings_keys.dart`: two keys after `libraryAutoUpload` (around line 584), plus the `all` list entries after `libraryAutoUpload,` (around line 773).
- Modify: `lib/services/upscale/upscale_controller.dart`
- Test: `test/cloud_bake_controller_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces, on `UpscaleController`:
  - `Observable<CloudBakeSessionView?> cloudSession` and `ObservableMap<String, CloudEpisodePhase> cloudPhases`.
  - `bool get hasRunpodKey` and `bool cloudHolds(String recordKey, int episodeNumber)`.
  - `Future<CloudBakeQuote> quoteCloudBake(String recordKey)` (throws `CloudBakeException` / `RunpodException`), `Future<void> startCloudBake(CloudBakeQuote quote)` and `Future<void> stopCloudBake()`.
  - `Future<List<CloudPodInfo>> leftoverCloudPods()` and `Future<void> deleteCloudPod(String id)`.
  - `static List<String> cloudRemuxArgs(String input, String output)` and `static List<CloudPodInfo> leftoverPods(List<CloudPodInfo> pods)`.

- [ ] **Step 1: Write the failing test**

`test/cloud_bake_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';

void main() {
  test('HLS downloads are remuxed into one file without re-encoding', () {
    final args = UpscaleController.cloudRemuxArgs('/d/ep3/index.m3u8', '/d/ep3/upscaled/cloud_input.mkv');
    expect(args.join(' '), contains('-allowed_extensions ALL -protocol_whitelist file,crypto,data -i /d/ep3/index.m3u8'));
    expect(args.join(' '), contains('-c copy'));
    expect(args.last, '/d/ep3/upscaled/cloud_input.mkv');
  });

  test('only live kazumi pods count as leftovers', () {
    CloudPodInfo pod(String name, String status) =>
        CloudPodInfo(id: name, name: name, status: status, costPerHour: 1.09);
    final leftovers = UpscaleController.leftoverPods([
      pod('kazumi-bake-abc123', 'RUNNING'),
      pod('kazumi-bake-def456', 'TERMINATED'),
      pod('comfyui', 'RUNNING'),
      pod('kazumi-bake-ghi789', 'EXITED'),
    ]);
    expect(leftovers.map((p) => p.name), ['kazumi-bake-abc123', 'kazumi-bake-ghi789']);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/cloud_bake_controller_test.dart`

Expected: FAIL (`cloudRemuxArgs` isn't defined).

- [ ] **Step 3: Add the settings keys**

In `settings_keys.dart`, after the `libraryAutoUpload` key:

```dart
  static const runpodApiKey = SettingKey<String>(
    'runpodApiKey',
    '',
    group: SettingGroup.download,
  );
  static const cloudBakeIncludeLocal = SettingKey<bool>(
    'cloudBakeIncludeLocal',
    true,
    group: SettingGroup.download,
  );
```

In the `all` list, after `libraryAutoUpload,`, add `runpodApiKey,` and `cloudBakeIncludeLocal,`.

- [ ] **Step 4: Refactor `_bakeOne` and add the GPU lock**

All of these changes are in `upscale_controller.dart`; hand-format them to match the file.

Add these imports:

```dart
import 'package:flutter/services.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_worker_client.dart';
import 'package:kazumi/services/upscale/cloud/cloud_worker_script.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
```

Add these fields, after `final ObservableSet<String> analyzingSkips ...`:

```dart
  // One local bake at a time: one already saturates the GPU, and both the
  // bake queue and a cloud session's laptop lane feed it.
  Future<void> _gpu = Future.value();

  CloudBakeSession? _cloud;
  final Observable<CloudBakeSessionView?> cloudSession = Observable(null);

  /// Keyed like [bakeProgress]; present while the cloud holds the episode.
  final ObservableMap<String, CloudEpisodePhase> cloudPhases =
      ObservableMap<String, CloudEpisodePhase>();
```

Add these methods, near `_pumpBakeQueue`:

```dart
  Future<T> _onGpu<T>(Future<T> Function() bake) {
    final run = _gpu.then((_) => bake());
    _gpu = run.then((_) {}, onError: (_) {});
    return run;
  }
```

In `_pumpBakeQueue`, replace `await _bakeOne(recordKey, episodeNumber);` with:

```dart
        await _onGpu(() => _bakeOne(recordKey, episodeNumber));
```

Change `_bakeOne` to `Future<LocalBakeOutcome> _bakeOne(String recordKey, int episodeNumber) async`:
- The early return becomes `return LocalBakeOutcome.failed;`.
- In the success path, after the `KazumiLogger().i('... baked ...')` line, replace everything up to the `on UpscaleBakeCancelled` with:

```dart
      await _finishBake(recordKey, episodeNumber, output, targetHeight);
      return LocalBakeOutcome.done;
```

- The `on UpscaleBakeCancelled` block gets `return LocalBakeOutcome.cancelled;` after its `_updateEpisode`.
- The generic `catch` gets `return LocalBakeOutcome.failed;` after its `_updateEpisode`.

Add `_finishBake` after `_bakeOne`. It holds exactly the steps that were removed:

```dart
  Future<void> _finishBake(
    String recordKey,
    int episodeNumber,
    String output,
    int height,
  ) async {
    await _updateEpisode(recordKey, episodeNumber, (e) {
      e.upscaleStatus = UpscaleStatus.done;
      e.upscaledVideoPath = output;
      e.upscaledHeight = height;
    });
    try {
      await analyzeSkips(recordKey);
    } catch (e) {
      KazumiLogger().w('UpscaleController: skip analysis failed', error: e);
    }
    if (GStorage.getSetting(SettingsKeys.libraryAutoUpload) &&
        canUploadToLibrary) {
      enqueueUpload(recordKey, episodeNumber);
    }
    if (GStorage.getSetting(SettingsKeys.upscaleAutoExport) &&
        GStorage.getSetting(SettingsKeys.upscaleExportDirectory).isNotEmpty) {
      final error = await export(recordKey, episodeNumber);
      if (error != null) {
        KazumiLogger().w('UpscaleController: auto export failed: $error');
      }
    }
  }
```

In `enqueueBake`, after `if (episode.preUpscaled) return '该集已是超分版本';`:

```dart
    if (cloudHolds(recordKey, episodeNumber)) return '该集正在云端烘焙';
```

- [ ] **Step 5: Add the cloud members**

Add a new block after `cancelBake`:

```dart
  bool get hasRunpodKey =>
      GStorage.getSetting(SettingsKeys.runpodApiKey).isNotEmpty;

  RunpodApi _runpod() =>
      RunpodApi(GStorage.getSetting(SettingsKeys.runpodApiKey));

  bool cloudHolds(String recordKey, int episodeNumber) {
    final session = _cloud;
    return session != null &&
        session.recordKey == recordKey &&
        session.holds(episodeNumber);
  }

  /// Prices a cloud bake of every episode of [recordKey] that still needs
  /// one. Throws [CloudBakeException] or [RunpodException] with a message
  /// for the user.
  Future<CloudBakeQuote> quoteCloudBake(String recordKey) async {
    if (!canBake) throw const CloudBakeException('仅支持在电脑端烘焙');
    if (_cloud != null) throw const CloudBakeException('已有云端烘焙在进行');
    if (!hasRunpodKey) {
      throw const CloudBakeException('请先在下载设置中填写 Runpod API Key');
    }
    var ffmpeg = _ffmpeg;
    if (ffmpeg == null) {
      final (info, error) = await detectFfmpeg();
      if (info == null) throw CloudBakeException(error ?? '未找到可用的 ffmpeg');
      ffmpeg = info;
    }
    final record = _repository.getRecord(recordKey);
    if (record == null) throw const CloudBakeException('找不到该番剧');
    final episodes = record.episodes.values
        .where((e) =>
            e.status == DownloadStatus.completed &&
            !e.preUpscaled &&
            e.upscaleStatus != UpscaleStatus.done &&
            !_bakeQueue.contains((recordKey, e.episodeNumber)) &&
            _activeKey != progressKey(recordKey, e.episodeNumber))
        .toList()
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    if (episodes.isEmpty) throw const CloudBakeException('没有可烘焙的剧集');

    final int height = GStorage.getSetting(SettingsKeys.upscaleBakeHeight);
    final jobs = <CloudJob>[];
    for (final e in episodes) {
      final us = await UpscaleBaker.probeDurationUs(
          ffmpeg.executable, e.localM3u8Path);
      jobs.add(CloudJob(
        recordKey: recordKey,
        episodeNumber: e.episodeNumber,
        durationSec: us ~/ 1000000,
        outputPath:
            path.join(e.downloadDirectory, 'upscaled', upscaledVideoFileName),
      ));
    }
    final bool includeLocal =
        GStorage.getSetting(SettingsKeys.cloudBakeIncludeLocal);
    final offer = await _runpod().sydneyOffer();
    return CloudBakeQuote(
      recordKey: recordKey,
      jobs: jobs,
      offer: offer,
      includeLocal: includeLocal,
      height: height,
      estimate: CloudBakeEstimate.forDurations(
        [for (final j in jobs) j.durationSec],
        includeLocal: includeLocal,
      ),
    );
  }

  Future<void> startCloudBake(CloudBakeQuote quote) async {
    if (_cloud != null) throw const CloudBakeException('已有云端烘焙在进行');
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) throw const CloudBakeException('未找到可用的 ffmpeg');
    final script =
        packWorkerScript(await rootBundle.loadString(cloudWorkerAsset));
    final shader = await File(await UpscaleBaker.buildCombinedShader(
      _shaderAssetService.shadersDirectory.path,
    )).readAsString();

    final session = CloudBakeSession(
      api: _runpod(),
      connect: (uri, token) => CloudBakeWorkerClient(uri, token),
      recordKey: quote.recordKey,
      jobs: quote.jobs,
      includeLocal: quote.includeLocal,
      workerScript: script,
      capSec: quote.estimate.capSec,
      pricePerHour: quote.offer.pricePerHour,
      shader: shader,
      targetHeight: quote.height,
      prepareInput: (job) => _cloudInput(ffmpeg, job),
      bakeLocally: (job) =>
          _onGpu(() => _bakeOne(job.recordKey, job.episodeNumber)),
      onCloudBaked: (job) => _adoptCloudOutput(job, quote.height),
      onReturned: (job) =>
          _updateEpisode(job.recordKey, job.episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.none;
      }),
      onFailed: (job, error) =>
          _updateEpisode(job.recordKey, job.episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.failed;
        e.errorMessage = error;
      }),
      onPhase: (job, phase) => runInAction(() {
        final key = progressKey(job.recordKey, job.episodeNumber);
        if (phase == null) {
          cloudPhases.remove(key);
        } else {
          cloudPhases[key] = phase;
        }
      }),
      onChanged: (view) => runInAction(() => cloudSession.value = view),
    );
    _cloud = session;
    for (final job in quote.jobs) {
      await _updateEpisode(job.recordKey, job.episodeNumber, (e) {
        e.upscaleStatus = UpscaleStatus.queued;
      });
    }
    KeepAwake.instance.acquire();
    unawaited(() async {
      try {
        await session.run();
      } catch (e) {
        KazumiLogger().e('UpscaleController: cloud bake failed', error: e);
      } finally {
        KeepAwake.instance.release();
        _cloud = null;
        KazumiLogger().i(
            'UpscaleController: ${session.view.summary(DateTime.now())}');
        KazumiDialog.showToast(
          message: session.view.summary(DateTime.now()),
          duration: const Duration(seconds: 6),
        );
        runInAction(() {
          cloudSession.value = null;
          cloudPhases.clear();
        });
      }
    }());
  }

  Future<void> stopCloudBake() async => _cloud?.stop();

  /// The pod needs one file; HLS downloads (playlist plus segments) are
  /// remuxed into one without re-encoding.
  Future<(File, bool)> _cloudInput(FfmpegInfo ffmpeg, CloudJob job) async {
    final episode =
        _repository.getRecord(job.recordKey)?.episodes[job.episodeNumber];
    if (episode == null) throw const CloudBakeException('剧集已被删除');
    final input = episode.localM3u8Path;
    if (!input.toLowerCase().endsWith('.m3u8')) return (File(input), false);
    final output =
        path.join(episode.downloadDirectory, 'upscaled', 'cloud_input.mkv');
    await Directory(path.dirname(output)).create(recursive: true);
    final result =
        await Process.run(ffmpeg.executable, cloudRemuxArgs(input, output));
    if (result.exitCode != 0) {
      final lines = (result.stderr as String).trim().split('\n');
      throw CloudBakeException('整理视频失败: ${lines.last}');
    }
    return (File(output), true);
  }

  @visibleForTesting
  static List<String> cloudRemuxArgs(String input, String output) => [
        '-hide_banner',
        '-y',
        '-loglevel',
        'error',
        '-allowed_extensions',
        'ALL',
        '-protocol_whitelist',
        'file,crypto,data',
        '-i',
        input,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c',
        'copy',
        output,
      ];

  Future<void> _adoptCloudOutput(CloudJob job, int height) async {
    // The marker lets init() adopt the file if the app dies before the
    // record is updated.
    await File(path.join(
      path.dirname(job.outputPath),
      cloudBakeMarkerFileName,
    )).writeAsString(jsonEncode({'height': height, 'source': 'runpod-l40s'}));
    await _finishBake(job.recordKey, job.episodeNumber, job.outputPath, height);
  }

  /// Cloud bake pods still running with no session in this app, e.g. after
  /// the app was killed mid-run.
  Future<List<CloudPodInfo>> leftoverCloudPods() async {
    if (!canBake || !hasRunpodKey || _cloud != null) return const [];
    return leftoverPods(await _runpod().listPods());
  }

  @visibleForTesting
  static List<CloudPodInfo> leftoverPods(List<CloudPodInfo> pods) => [
        for (final pod in pods)
          if (pod.name.startsWith(cloudPodNamePrefix) && !pod.gone) pod,
      ];

  Future<void> deleteCloudPod(String id) => _runpod().deletePod(id);
```

- [ ] **Step 6: Run the tests and the analyzer**

Run:

```
fvm flutter test test/cloud_bake_controller_test.dart test/cloud_bake_adoption_test.dart test/upscale_test.dart
fvm flutter analyze
```

Expected: the tests pass; the analyzer reports `No issues found!`.

If the analyzer flags `_finishAdopted` as duplicating `_finishBake`, leave it. Adoption runs skip analysis per record in one batch at startup, and that behaviour is already shipped.

- [ ] **Step 7: Commit (no `dart format` on these two upstream-adjacent files)**

`upscale_controller.dart` is fork-only, so formatting it is allowed. `settings_keys.dart` is upstream: hand-format it. Then:

```bash
fvm dart format lib/services/upscale/upscale_controller.dart test/cloud_bake_controller_test.dart
git diff --stat
git add lib/services/storage/settings_keys.dart lib/services/upscale/upscale_controller.dart test/cloud_bake_controller_test.dart
git commit -m "feat(upscale): run cloud bakes from the upscale controller"
```

Check that `git diff --stat` shows no whole-file reformat of `upscale_controller.dart`. If `dart format` rewrote unrelated lines, the file was already formatted by the fork, which is fine. If the diff is noisy, revert the formatting and hand-format.

---

### Task 7: UI

**Files:**
- Create: `lib/pages/download/cloud_bake_sheets.dart`
- Modify: `lib/pages/download/download_page.dart` (menu around line 143, body around line 85, `_buildEpisodeTile` around line 170, `_getStatusText` around line 201, `_upscaleActions` around line 336)
- Modify: `lib/pages/settings/download_settings.dart` (state fields around line 40, `initState`, new section after 一起看片库 around line 435)
- Modify: `lib/pages/init_page.dart` (after `_startDefaultPage();` around line 113)
- Test: `test/cloud_bake_sheets_test.dart`

**Interfaces:**
- Consumes: the controller members from Task 6 and the session types from Task 5.
- Produces:
  - `Future<void> showCloudBakeFlow(BuildContext, UpscaleController, DownloadRecord, {required Future<void> Function() bakeAllLocally})`.
  - `class CloudBakeConfirmSheet(quote)`.
  - `class CloudBakeBanner(controller)`.
  - `String cloudStatusText(CloudEpisodePhase)`.
  - `Future<void> checkLeftoverCloudPods(UpscaleController)`.

- [ ] **Step 1: Write the failing widget test**

`test/cloud_bake_sheets_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/download/cloud_bake_sheets.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_estimate.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';

void main() {
  CloudBakeQuote quote({bool includeLocal = true}) => CloudBakeQuote(
        recordKey: 'r',
        jobs: const [],
        offer: const CloudOffer(available: true, pricePerHour: 1.2),
        estimate: const CloudBakeEstimate(
            cloudCount: 2, localCount: 1, cloudSec: 760, finishSec: 760),
        includeLocal: includeLocal,
        height: 1440,
      );

  Future<bool?> pump(WidgetTester tester, CloudBakeQuote q) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: CloudBakeConfirmSheet(quote: q),
        ),
      ),
    ));
    return result;
  }

  testWidgets('the confirm sheet shows the split, time and cost', (tester) async {
    await pump(tester, quote());
    expect(find.text('2 集'), findsOneWidget);
    expect(find.text('本机 1 集'), findsOneWidget);
    expect(find.text('13 分钟'), findsOneWidget);
    expect(find.text('\$0.25'), findsOneWidget);
    expect(find.text('最多 \$0.60'), findsOneWidget);
    expect(find.textContaining('L40S 悉尼 \$1.20/小时'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });

  testWidgets('cloud-only quotes say the laptop sits out', (tester) async {
    await pump(tester, quote(includeLocal: false));
    expect(find.textContaining('本机不参与'), findsOneWidget);
  });

  test('cloud status text per stage', () {
    expect(cloudStatusText(const CloudEpisodePhase(CloudEpisodeStage.uploading, 0.42)), '☁ 上传中 42%');
    expect(cloudStatusText(const CloudEpisodePhase(CloudEpisodeStage.waiting)), '☁ 等待 GPU');
    expect(cloudStatusText(const CloudEpisodePhase(CloudEpisodeStage.baking, 0.5)), '☁ 烘焙中 50%');
    expect(cloudStatusText(const CloudEpisodePhase(CloudEpisodeStage.downloading, 1)), '☁ 下载中 100%');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/cloud_bake_sheets_test.dart`

Expected: FAIL (`cloud_bake_sheets.dart` doesn't exist).

- [ ] **Step 3: Write `cloud_bake_sheets.dart`**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
import 'package:kazumi/services/upscale/cloud/runpod_api.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:url_launcher/url_launcher.dart';

String cloudStatusText(CloudEpisodePhase phase) {
  final percent = '${(phase.progress * 100).toStringAsFixed(0)}%';
  return switch (phase.stage) {
    CloudEpisodeStage.uploading => '☁ 上传中 $percent',
    CloudEpisodeStage.waiting => '☁ 等待 GPU',
    CloudEpisodeStage.baking => '☁ 烘焙中 $percent',
    CloudEpisodeStage.downloading => '☁ 下载中 $percent',
  };
}

String _money(double value) => '\$${value.toStringAsFixed(2)}';

Future<void> showCloudBakeFlow(
  BuildContext context,
  UpscaleController controller,
  DownloadRecord record, {
  required Future<void> Function() bakeAllLocally,
}) async {
  if (!controller.hasRunpodKey) {
    KazumiDialog.showToast(
      message: '请先在下载设置中填写 Runpod API Key',
      showActionButton: true,
      actionLabel: '去设置',
      onActionPressed: () => context.pushNamed('/settings/download/'),
    );
    return;
  }
  KazumiDialog.showToast(message: '正在查询悉尼 GPU…');
  final CloudBakeQuote quote;
  try {
    quote = await controller.quoteCloudBake(record.key);
  } on RunpodException catch (e) {
    if (e.noCapacity) {
      await _offerLocal(bakeAllLocally);
    } else {
      KazumiDialog.showToast(
        message: e.message,
        showActionButton: true,
        actionLabel: '打开 Runpod',
        onActionPressed: () => launchUrl(
          Uri.parse('https://console.runpod.io/user/settings'),
          mode: LaunchMode.externalApplication,
        ),
        duration: const Duration(seconds: 6),
      );
    }
    return;
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
    return;
  }
  if (!quote.offer.available) {
    await _offerLocal(bakeAllLocally);
    return;
  }
  if (quote.estimate.cloudCount == 0) {
    KazumiDialog.showToast(message: '集数太少，本机烘焙更快');
    await bakeAllLocally();
    return;
  }
  if (!context.mounted) return;
  final go = await showAdaptiveBottomSheet<bool>(
    context: context,
    builder: (_) => CloudBakeConfirmSheet(quote: quote),
  );
  if (go != true) return;
  try {
    await controller.startCloudBake(quote);
  } on CloudBakeException catch (e) {
    KazumiDialog.showToast(message: e.message);
  }
}

Future<void> _offerLocal(Future<void> Function() bakeAllLocally) async {
  final local = await KazumiDialog.show<bool>(
    builder: (context) => AlertDialog(
      title: const Text('悉尼暂无可用 GPU'),
      content: const Text('现在租不到悉尼的 L40S。可以先用本机烘焙全部，或稍后再试。'),
      actions: [
        TextButton(
          onPressed: () => KazumiDialog.dismiss(popWith: false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => KazumiDialog.dismiss(popWith: true),
          child: const Text('本机烘焙全部'),
        ),
      ],
    ),
  );
  if (local == true) await bakeAllLocally();
}

class CloudBakeConfirmSheet extends StatelessWidget {
  const CloudBakeConfirmSheet({super.key, required this.quote});

  final CloudBakeQuote quote;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final estimate = quote.estimate;
    final price = quote.offer.pricePerHour;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.cloud_rounded,
                    color: colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('云端烘焙', style: textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _Stat(
                  label: '云端',
                  value: '${estimate.cloudCount} 集',
                  note: estimate.localCount > 0
                      ? '本机 ${estimate.localCount} 集'
                      : null,
                ),
                const SizedBox(width: 12),
                _Stat(
                  label: '预计',
                  value: '${(estimate.finishSec / 60).ceil()} 分钟',
                ),
                const SizedBox(width: 12),
                _Stat(
                  label: '费用',
                  value: _money(estimate.cost(price)),
                  note: '最多 ${_money(estimate.maxCost(price))}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'L40S 悉尼 ${_money(price)}/小时 · 按秒计费，做完自动删除 GPU',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (!quote.includeLocal)
              Text(
                '本机不参与烘焙 (可在下载设置中开启)',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.rocket_launch_rounded),
                    label: const Text('开始'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (note != null)
              Text(
                note!,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown above the download list while a cloud bake runs.
class CloudBakeBanner extends StatefulWidget {
  const CloudBakeBanner({super.key, required this.controller});

  final UpscaleController controller;

  @override
  State<CloudBakeBanner> createState() => _CloudBakeBannerState();
}

class _CloudBakeBannerState extends State<CloudBakeBanner> {
  Timer? _ticker;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    // Elapsed time and cost move every second without a state change.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.cloudSession.value != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _stop() async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('停止云端烘焙？'),
        content: const Text('会立即删除云端 GPU。云端正在处理的剧集回到未烘焙，本机正在烘焙的那一集会继续。'),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('继续烘焙'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('停止'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _stopping = true);
    await widget.controller.stopCloudBake();
    if (mounted) setState(() => _stopping = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Observer(builder: (context) {
      final view = widget.controller.cloudSession.value;
      return AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: view == null
            ? const SizedBox(width: double.infinity)
            : _buildCard(view, colorScheme, textTheme),
      );
    });
  }

  Widget _buildCard(
    CloudBakeSessionView view,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final now = DateTime.now();
    final elapsed = now.difference(view.startedAt);
    final clock =
        '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final title = switch (view.phase) {
      CloudBakePhase.starting => '正在启动 GPU',
      CloudBakePhase.running => '云端烘焙中',
      CloudBakePhase.finishing => '正在收尾',
      CloudBakePhase.done => '已完成',
      CloudBakePhase.stopped => '已停止',
    };
    final busy = view.phase == CloudBakePhase.starting ||
        view.phase == CloudBakePhase.running;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: colorScheme.tertiaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (busy)
                          CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onTertiaryContainer,
                          ),
                        Icon(
                          Icons.cloud_rounded,
                          size: 20,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                        Text(
                          '☁ ${view.cloudDone} · 本机 ${view.localDone} · '
                          '共 ${view.total} 集 · $clock · '
                          '${_money(view.costAt(now))}',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onTertiaryContainer,
                          ),
                        ),
                        if (view.message != null)
                          Text(
                            view.message!,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _stopping || !busy ? null : _stop,
                    child: const Text('停止'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// After a crash or a killed app the pod may still be billing; it deletes
/// itself within about ten minutes, but offer to do it now.
Future<void> checkLeftoverCloudPods(UpscaleController controller) async {
  await Future.delayed(const Duration(seconds: 3));
  final List<CloudPodInfo> pods;
  try {
    pods = await controller.leftoverCloudPods();
  } catch (e) {
    KazumiLogger().w('CloudBake: leftover pod check failed', error: e);
    return;
  }
  for (final pod in pods) {
    final created = pod.createdAt;
    final age = created == null
        ? ''
        : '已运行 ${DateTime.now().difference(created).inMinutes} 分钟，';
    final delete = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('发现仍在运行的云端 GPU'),
        content: Text(
          '${pod.name} $age按 ${_money(pod.costPerHour)}/小时计费。是否删除？',
        ),
        actions: [
          TextButton(
            onPressed: () => KazumiDialog.dismiss(popWith: false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => KazumiDialog.dismiss(popWith: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (delete != true) continue;
    try {
      await controller.deleteCloudPod(pod.id);
      KazumiDialog.showToast(message: '已删除云端 GPU');
    } on RunpodException catch (e) {
      KazumiDialog.showToast(message: e.message);
    }
  }
}
```

If `context.pushNamed` isn't available through `package:kazumi/navigation.dart`, use the same import `init_page.dart` uses for its `navigationContext.pushNamed('/settings/download/')` call.

- [ ] **Step 4: Run the widget test**

Run: `fvm flutter test test/cloud_bake_sheets_test.dart`

Expected: 3 pass. The `pump` helper's unused `result` can go if the analyzer complains.

- [ ] **Step 5: Wire up the download page**

These are hand edits; don't run `dart format` on upstream files.

Add the import:

```dart
import 'package:kazumi/pages/download/cloud_bake_sheets.dart';
```

The body becomes a column with the banner on top:

```dart
      body: Column(
        children: [
          if (upscaleController.canBake)
            CloudBakeBanner(controller: upscaleController),
          Expanded(
            child: Observer(builder: (context) {
              // ...the existing body Observer, unchanged...
            }),
          ),
        ],
      ),
```

In `extraMenuItems`, after `全部烘焙超分`:

```dart
          if (upscaleController.canBake)
            KazumiMenuItem(
              label: '☁ 云端烘焙全部',
              onPressed: () => showCloudBakeFlow(
                context,
                upscaleController,
                record,
                bakeAllLocally: () => _bakeAll(record),
              ),
            ),
```

In `_buildEpisodeTile`:
- After `final uploadProgress = ...;`, add `final cloudPhase = upscaleController.cloudPhases[key];`.
- Pass `cloudPhase: cloudPhase,` to `_getStatusText`.
- Change `taskProgress:` to:

```dart
        taskProgress: uploadProgress ??
            exportProgress ??
            cloudPhase?.progress ??
            bakeProgress ??
            (episode.upscaleStatus == UpscaleStatus.queued ? 0 : null),
```

In `_getStatusText`, add the parameter `CloudEpisodePhase? cloudPhase,` (named, with the others). In the `completed` case, just before `switch (episode.upscaleStatus)`, add:

```dart
        if (cloudPhase != null) return '$base · ${cloudStatusText(cloudPhase)}';
```

Add the import for `CloudEpisodePhase`:

```dart
import 'package:kazumi/services/upscale/cloud/cloud_bake_session.dart';
```

In `_upscaleActions`, after the `canBake` guard:

```dart
    // Cloud-held episodes are cancelled with the banner's stop button.
    if (episode.upscaleStatus == UpscaleStatus.queued &&
        upscaleController.cloudHolds(record.key, episode.episodeNumber)) {
      return const [];
    }
```

- [ ] **Step 6: Add the settings section**

In `download_settings.dart`:
- Add the import `package:url_launcher/url_launcher.dart`.
- Add the field `late bool cloudIncludeLocal;`.
- In `initState`, add `cloudIncludeLocal = GStorage.getSetting(SettingsKeys.cloudBakeIncludeLocal);`.
- Append this section to the `_upscaleSections` list, after the 一起看片库 section:

```dart
      SettingsSection(
        title: Text('云端烘焙 (Runpod)'),
        tiles: [
          SettingsTile(
            leading: Icons.key_rounded,
            title: Text('Runpod API Key'),
            description: Text(
                GStorage.getSetting(SettingsKeys.runpodApiKey).isEmpty
                    ? '未设置 · 在 Runpod 控制台 Settings → API Keys 创建，权限选读写'
                    : '已设置'),
            onPressed: (_) => _editLibrarySetting(
              SettingsKeys.runpodApiKey,
              title: 'Runpod API Key',
              hint: 'rpa_...',
            ),
          ),
          SettingsTile.switchTile(
            leading: Icons.computer_rounded,
            title: Text('同时用本机烘焙'),
            description: Text('云端从第一集往后烘焙，本机从最后一集往前，一起做完'),
            initialValue: cloudIncludeLocal,
            onToggle: (value) {
              setState(() => cloudIncludeLocal = value ?? !cloudIncludeLocal);
              GStorage.putSetting<bool>(
                  SettingsKeys.cloudBakeIncludeLocal, cloudIncludeLocal);
            },
          ),
          SettingsTile(
            leading: Icons.open_in_new_rounded,
            title: Text('打开 Runpod 控制台'),
            description: Text('查看余额、充值，或确认 GPU 已删除'),
            onPressed: (_) => launchUrl(
              Uri.parse('https://console.runpod.io/pods'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
```

- [ ] **Step 7: Add the leftover check at start-up**

In `init_page.dart`, add the import `package:kazumi/pages/download/cloud_bake_sheets.dart`. After `_startDefaultPage();` in `_initializeApp`, add:

```dart
    unawaited(checkLeftoverCloudPods(widget.upscaleController));
```

- [ ] **Step 8: Analyze and run the whole suite**

Run:

```
fvm flutter analyze
fvm flutter test
python -m unittest discover -s test/cloud_worker
```

Expected: `No issues found!`, all Dart tests pass, and the Python tests are `OK`.

- [ ] **Step 9: Format the new files and commit**

```bash
fvm dart format lib/pages/download/cloud_bake_sheets.dart test/cloud_bake_sheets_test.dart
git add lib/pages/download/cloud_bake_sheets.dart test/cloud_bake_sheets_test.dart lib/pages/download/download_page.dart lib/pages/settings/download_settings.dart lib/pages/init_page.dart
git commit -m "feat(download): cloud bake button, banner and Runpod settings"
```

---

### Task 8: Live run and ship

This task costs about $0.30–0.60 of Runpod credit. The owner does steps 2–3 and 5–7; the agent verifies with the Runpod MCP (`list-pods`, `get-pod`).

- [ ] **Step 1: Build the Windows app and install it**

```
fvm flutter build windows --release
```

Ask the owner to close Kazumi. Then copy `build/windows/x64/runner/Release/*` over `D:\Tools\Kazumi` (overwrite only; never mirror or delete, because that folder holds `Downloads` and `Upscale`).

- [ ] **Step 2: Owner adds the API key**

Steps for the owner:
1. Go to Runpod console → Settings → API Keys → Create API Key.
2. Choose read/write permission and copy the `rpa_...` key.
3. In Kazumi, go to 设置 → 下载设置 → 云端烘焙 (Runpod) → Runpod API Key, and paste it.

The key never leaves the PC's Hive store.

- [ ] **Step 3: Owner runs a small show**

Pick a downloaded show with at least 4 unbaked episodes. Use ⋯ → ☁ 云端烘焙全部. The confirm sheet should show the cloud/local split and a cost; press 开始.

Expect, in order:
- The banner reads 正在启动 GPU for about 2–4 min.
- Then 云端烘焙中.
- Episode lines go through ☁ 上传中 → ☁ 等待 GPU/烘焙中 → ☁ 下载中, and end at 已烘焙超分.
- The last episode on the laptop shows 正在烘焙超分.
- The run ends with a toast like 云端烘焙完成 · N 集 · M 分钟 · $x.

The agent then:
- Watches with MCP `list-pods`. A `kazumi-bake-xxxxxx` pod appears and is gone within about 1 min of the banner leaving 云端烘焙中.
- Plays one cloud episode: it should be 2560×1440 and play on the PC; the iPad can pull it over Wi-Fi.

- [ ] **Step 4: Check the worker's self-delete**

On the same or another show, while the banner shows 云端烘焙中, the owner ends Kazumi in Task Manager.

The agent polls `list-pods` every 2 min. The pod must disappear within about 11 min (600 s idle plus a 30 s check). If it's still there at 15 min:
1. Delete it with MCP `delete-pod` and record it.
2. Read the pod logs (MCP `stream-pod-logs`) for the `terminate failed:` line.
3. Fix `terminate_pod` before shipping.

Reopen Kazumi within that window: the 发现仍在运行的云端 GPU dialog should appear; 删除 removes it.

- [ ] **Step 5: Check stop**

Start ☁ again on a show and press 停止 after the first upload finishes.

Expect: the pod is gone from `list-pods` within about 1 min. Episodes the cloud held go back to the ✨ (未烘焙) state; a laptop bake already running finishes.

- [ ] **Step 6: Compile check, merge, upstream**

```bash
git fetch upstream && git merge upstream/main
git push -u origin feat/cloud-bake
gh workflow run pr.yaml -R KaiC5504/Kazumi --ref feat/cloud-bake -f run_ios=true
gh run list -R KaiC5504/Kazumi --branch feat/cloud-bake --limit 1
gh run watch <id> -R KaiC5504/Kazumi --exit-status   # run in the background
```

When it's green:

```bash
git checkout main && git merge --ff-only feat/cloud-bake && git push
git rev-list --count main..upstream/main   # must be 0
```

This feature is desktop-only; the iPad gets nothing new from it. Ask the owner whether a TestFlight build is wanted before spending Codemagic minutes on it. If yes: `python scripts/codemagic.py status`, then `start main`, then `watch`.

- [ ] **Step 7: Update the memory**

Update `kazumi-bake-throughput.md` and its `MEMORY.md` line:
- The in-app cloud bake exists.
- Self-delete is by GraphQL `podTerminate` with the pod key.
- Add the measured cost and time from step 3.
