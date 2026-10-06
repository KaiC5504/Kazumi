# Cloud bake: rent a Sydney GPU from inside Kazumi

Date: 2026-10-06. Status: approved in conversation, awaiting written-spec review.

## Goal

Baking a season of 质量档 (quality-tier) episodes on the laptop RTX 4070 takes
about 9 minutes per 24-minute episode, so a 24-episode season needs about 3.6
hours. The goal is to press one button on a show and have Kazumi rent a GPU in
Runpod's Sydney data center. The cloud GPU and the laptop then share the
season, and the pod is torn down afterwards. The owner should not need to touch
a terminal or the Runpod console.

**Success means:**
- A 24-episode season finishes in about 1.1 hours (cloud plus laptop) for
  about US$1.40.
- The baked files are identical in format to local bakes: 1440p, HEVC Main10,
  NVENC p5 cq22.
- No pod can stay billing for long after the app dies.

## Measured facts this design rests on

All of these were measured on 2026-10-06 with a manual run of the same
pipeline on episodes 3–27 of `95225_aafun`.

**Laptop:**
- A 90 s clip takes 33.6 s, about 2.7× realtime.
- The GPU is saturated: running two bakes at once gives no gain.

**Runpod Secure L40S in `OC-AU-1` (Sydney), US$1.09/hr:**
- Latency from home is 16 ms.
- NVENC works.
- The default Vulkan ICD (GLX) fails headless. Fix: an ICD JSON that points
  at `libEGL_nvidia.so.0`, plus `VK_ICD_FILENAMES`.
- Use the BtbN `n8.x` ffmpeg release build. BtbN master needs driver 610+;
  the host had 580.
- Two concurrent bakes keep the GPU at about 93%.
- A 26-minute episode took 411 s while paired, so overall throughput is
  about 3.4 min per 24-minute episode (about 7.7× realtime).

**Network:**
- Home upload is about 47 Mbps.
- One scp stream to Sydney gets 4 MB/s; two streams get 5.5 MB/s.
- Long-distance single streams are latency-bound: 0.4–0.6 MB/s to Singapore
  or the US.
- Downloads from the pod ran at about 35 MB/s.

**Runpod platform:**
- Every pod gets a pod-scoped `RUNPOD_API_KEY`, plus `RUNPOD_POD_ID`, and has
  `runpodctl` installed.
- Creating a pod with `NVIDIA_DRIVER_CAPABILITIES=all` in env works for a
  Secure pod. The Community host returned HTTP 500 once and also lacked the
  graphics libraries.

**US RTX 4090 (rejected as a fallback):**
- Only 1.7× the laptop.
- NVENC was blocked on that host.
- Uploads were 0.6 MB/s.

## Decisions (from the owner)

1. **Trigger:** a "☁ 云端烘焙全部" (cloud bake all) item in each show's ⋯ menu
   on the download page. It covers every completed, not-yet-upscaled episode,
   and a confirm sheet shows the estimated time and cost.
2. **No Sydney stock:** offer a laptop-only bake. Never rent outside Sydney.
3. **Safety:** the pod self-destructs after 10 minutes without contact from
   the PC, or at a hard cap of (estimate × 1.5, minimum 30 min). On app
   start, a leftover-pod check runs.
4. **Transport:** an HTTP worker on the pod that the app talks to directly
   over the pod's public TCP port. The connection is unencrypted and guarded
   by a per-run random token.

## Non-goals

- Pods fetching episode sources themselves.
- More than one pod per run.
- GPUs or regions other than an L40S in OC-AU-1.
- TLS.
- Mobile clients. Cloud bake follows `canBake`, so it is desktop only.

## User experience

**Settings → 下载 (Download) gets a new section, "云端烘焙 (Runpod)":**
- **API key.** The tile shows only 已设置/未设置 (set/not set) and is edited
  with the existing `_editLibrarySetting`-style dialog. It is stored in Hive
  like `libraryAdminKey`.
- **"同时用本机烘焙" (also bake on this PC).** Default on. When off, the cloud
  does every episode.
- A short line linking to the Runpod API key page.

**Starting a run (download page, ⋯ menu → 云端烘焙全部):**
1. Pick the episodes. Use the same filter as `_bakeAll`: completed, not
   `preUpscaled`, not `done`, not already queued or baking.
2. Check the API key, then check L40S stock in OC-AU-1.
   - If there's no stock, show 悉尼暂无可用 GPU (no GPU available in
     Sydney), with actions [本机烘焙全部 (bake all on this PC)] and [取消
     (cancel)].
3. Show the confirm sheet, for example: "☁ 18 集 + 本机 7 集 · 约 70 分钟 ·
   约 $1.40 (最多 $2.10) · L40S 悉尼 $1.09/小时". That means 18 episodes on the
   cloud plus 7 on the PC, about 70 minutes, about $1.40 (at most $2.10), on a
   Sydney L40S at $1.09/hour. Buttons: [开始 (start)] [取消 (cancel)].
4. Press 开始 to create the pod.

**While it runs:**
- **Banner** at the top of the download page, shown only while a session
  exists. It shows the phase (正在启动 GPU / 云端烘焙中 / 正在收尾, i.e.
  starting the GPU, baking in the cloud, wrapping up), the counts done (☁ x/y,
  本机 a/b), elapsed time, cost so far, and a **停止 (stop)** button.
- **Episode status text:**
  - Cloud episodes show ☁ 上传中 N% (uploading), ☁ 等待 GPU (waiting for
    GPU), ☁ 烘焙中 N% (baking), or ☁ 下载中 N% (downloading).
  - Local episodes keep the existing 正在烘焙超分 N% (baking upscale) text.
  - Progress uses the existing `taskProgress` bar.

**When it ends:**
- When every episode is done or failed, the app deletes the pod and shows a
  toast like "云端烘焙完成 · 25 集 · 68 分钟 · $1.31" (cloud bake done, 25
  episodes, 68 minutes, $1.31).
- 停止 deletes the pod immediately. Episodes still in the cloud go back to
  未烘焙 (not baked). A local bake that is already running keeps going.

**On app start:**
- If a recorded session pod, or any pod named `kazumi-bake-*`, still exists,
  show a dialog: "发现仍在运行的云端 GPU，是否删除？" (a cloud GPU is still
  running, delete it?), with the running cost and [删除 (delete)] / [保留
  (keep)].

## Architecture

### 1. Pod worker: `assets/cloud/kazumi_bake_worker.py`

A stdlib-only Python 3 script, bundled as a Flutter asset and sent at pod
creation.

**Boot:**
- Download the BtbN `ffmpeg-n8.*-latest-linux64-gpl` build. Discover the URL
  from the latest-release asset list.
- Write the EGL ICD JSON and set `VK_ICD_FILENAMES`.
- Probe the encoder. Use `hevc_nvenc` (`-preset p5 -rc vbr -cq 22 -b:v 0`,
  `format=p010le`) if a 2 s libplacebo+NVENC test passes. Otherwise use
  `hevc_vulkan` (`-rc_mode cqp -qp 19 -tune hq`, `format=p010`). If neither
  works, set state `broken`.
- Then listen on `0.0.0.0:8080` (pod port `8080/tcp`).

**Security:**
- Every request must carry the header `X-Kazumi-Token: <token>`. The token
  is a 32-byte random value, base64url, from the pod env `KAZUMI_TOKEN`.
- Any other request gets 403.
- Every authenticated request refreshes the heartbeat.

**Endpoints:**

| Method | Path | Purpose |
|---|---|---|
| GET | `/status` | `{state: booting/ready/broken, encoder, slots, uptimeSec, capSec, episodes: {id: {state, progress, outBytes, error}}}`. Episode states: `receiving, queued, baking, done, failed`. |
| PUT | `/shader` | Combined Anime4K GLSL (the same file `UpscaleBaker.buildCombinedShader` makes). |
| GET | `/in/{id}/parts` | `{index: bytes}` already received, for resuming. |
| PUT | `/in/{id}/parts/{index}` | One part (8 MiB, the last one shorter). |
| POST | `/in/{id}/commit` | `{size, durationSec, height}`. Assembles the parts, checks the size, and queues the episode. |
| GET | `/out/{id}` | The finished mp4. Supports `Range` (and `HEAD` for the size). |
| DELETE | `/out/{id}` | Drops the output and input after the PC has verified it. |
| POST | `/shutdown` | The PC is done. The worker deletes its own pod (backup to the app's API delete). |

**Bake:**
- Two slots. They take queued episodes in commit order.
- Each slot runs the same ffmpeg filter and encoder arguments as
  `UpscaleBaker._run`: `libplacebo` to the target height with
  `custom_shader_path`, `-profile:v main10 -tag:v hvc1 -c:a copy -movflags
  +faststart`, and `-progress pipe:1` for the progress percentage.
- If ffmpeg fails, retry once with `-c:a aac -b:a 192k`, which mirrors the
  local audio retry. If that fails too, the episode is `failed`.

**Self-destruct:** a watchdog thread runs
`runpodctl remove pod $RUNPOD_POD_ID` when either:
- no authenticated request has arrived for 600 s, or
- uptime exceeds `KAZUMI_CAP_SEC`.

The watchdog must not fire while the worker is still `booting` and has not
yet received any request; the 10 minutes count from boot completion. It
retries every 30 s until it succeeds.

**Delivery to the pod:**
- Pod `env.KAZUMI_WORKER` carries the script, gzip + base64.
- The pod command is
  `bash -c 'echo "$KAZUMI_WORKER" | base64 -d | gunzip > /w.py && exec python3 /w.py'`.
- If Runpod's env size limit rejects that, a tiny inline bootstrap accepts
  the script as its first authenticated `PUT /worker` instead (verified in
  planning).

### 2. `RunpodApi`: `lib/services/upscale/cloud/runpod_api.dart`

A thin client over Runpod's REST API, with a bearer token taken from settings.
The exact base URL and version are pinned in planning against the live OpenAPI
spec. It uses `dart:io HttpClient`, like `LibraryApi`.

**Calls:**
- `l40sSydneyAvailable()`: returns an availability flag plus the current
  hourly price.
- `createPod(...)` with:
  - name `kazumi-bake-<6 random chars>`
  - cloud `SECURE`, `dataCenterIds: [OC-AU-1]`, GPU `NVIDIA L40S` × 1
  - image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404` (the one
    verified)
  - disk 50 GB, ports `["8080/tcp"]`
  - env: `NVIDIA_DRIVER_CAPABILITIES=all`, `KAZUMI_TOKEN`, `KAZUMI_CAP_SEC`,
    `KAZUMI_WORKER`
  - the start command above
- `getPod(id)`: status, public IP, and the mapped port for 8080.
- `deletePod(id)`.
- `listPods()`: for the leftover check.

It maps HTTP 401 to "API key invalid". It maps an insufficient-balance error
to "Runpod 余额不足" (Runpod balance too low).

### 3. `CloudBakeWorkerClient`: `lib/services/upscale/cloud/cloud_bake_worker_client.dart`

Typed calls to the worker endpoints above.
- **Uploads** reuse `runParts` from `parted_transfer.dart`: 8 MiB parts, 8
  connections, 8 attempts, with `GET /in/{id}/parts` for resume. This is the
  same pattern as `UpscaleController.uploadInParts`.
- **Downloads** reuse `downloadInParts`, with a parts log beside the target
  file.

### 4. `CloudBakeSession`: `lib/services/upscale/cloud/cloud_bake_session.dart`

One run, owned by `UpscaleController`. It is a plain Dart class with injected
`RunpodApi`, worker-client factory, local-bake callback, clock and finish
callback, so it can be unit tested without a pod.

**Lifecycle:**
1. `starting`: create the pod, then poll `getPod` every 5 s until the 8080
   port is mapped and `/status` says `ready`. Give up after 5 min: delete the
   pod and hand every episode to the laptop. Then upload the shader.
2. `running`.
3. `finishing`.
4. `done`, `stopped` or `failed`.

The pod id and token are persisted in settings
(`cloudBakeActivePod`) so the startup check can find the pod.

**Scheduling** (one ordered list of the show's episodes):
- **Cloud lane** takes from the front. It keeps at most 2 episodes uploaded
  and waiting on the pod beyond the 2 baking (so at most 4 handed over at
  once). Uploads run one episode at a time, each over 8 parallel parts.
- **Local lane** (when 同时用本机烘焙 is on) takes from the back, one at a
  time, through the existing local bake path.
- Each lane takes the next episode when it frees up, until the list is
  empty. Neither lane takes an episode the other holds.

**Polling and download:**
- Poll `/status` every 5 s. This is also the heartbeat.
- When an episode is `done`:
  1. Download it to `upscaled/video.mp4.part`.
  2. Check that the size matches `outBytes`.
  3. Rename it to `video.mp4`.
  4. `DELETE /out/{id}`.
  5. Call the shared finish path (§5).
- At most 2 downloads run at once.

**Failure moves:**
- An upload fails after retries: the episode goes back to the list for the
  local lane.
- A pod-side `failed`: the episode goes to the local lane. If the local
  lane is off or also fails, the status becomes `failed` with the error.
- The pod becomes unreachable (no successful `/status` for 10 min): treat
  the pod as gone. Its unfinished episodes go to the local lane, and the
  app sends a best-effort `deletePod`.
- The app keeps retrying `/status` during the outage. The laptop lane keeps
  working throughout.

**Ending:**
- When the list is empty and no episode is held by either lane, call
  `POST /shutdown` then `deletePod`.
- Verify the pod is gone with `getPod`. Retry the delete for up to 2 min.
- Clear `cloudBakeActivePod`.

**Stop:** delete the pod immediately (the same verify loop). Cloud-held
episodes return to `none`. The local lane finishes its current episode and
takes no more.

**Cost:** elapsed wall-clock × the hourly price returned at creation. It is
shown live and in the final toast.

**Estimate** (for the confirm sheet and `KAZUMI_CAP_SEC`):
- Durations come from `probeDurationUs`.
- Cloud throughput: 7.7× realtime with 2 slots. Laptop: 2.7× realtime.
  Startup: 5 min.
- Simulate both lanes over the ordered list to get the finish time and the
  cloud share.
- The cap is `max(1800, 1.5 × estimatedCloudSeconds)`.
- The constants live in one place, so they can be retuned from logs.

### 5. `UpscaleController` changes

Pull the post-bake steps out of `_bakeOne` into `_finishBake(recordKey, ep,
outputPath, height)`. Those steps are: mark `done`, set the path and height,
`analyzeSkips`, auto-upload, auto-export. Local bakes, cloud downloads and
`_adoptCloudBake` all call it.

**New members:**
- `startCloudBake(recordKey)`, which returns an error string or null.
- `stopCloudBake()`.
- `Observable<CloudBakeSessionView?> cloudSession`, with the phase, counts,
  elapsed time and cost.
- `ObservableMap<String, CloudEpisodePhase> cloudPhases`, keyed by
  `progressKey`, with the phase and progress.
- `checkLeftoverPods()`, called from `init()` when `canBake` and an API key
  is set.

**Hive status:**
- Cloud episodes use the existing `UpscaleStatus.queued` / `baking`, so an
  interrupted run resets to `none` on the next `init()`. That logic already
  exists.
- There is no Hive schema change.

The local lane calls a variant of `_bakeOne` that bypasses `_bakeQueue`. Only
one local bake runs at a time: the local lane waits while the normal queue is
busy, and vice versa.

Keep-awake is held for the whole session.

### 6. UI changes

- **`download_page.dart`:**
  - A menu item next to 全部烘焙超分 (bake all).
  - The banner widget above the record list.
  - `_getStatusText` reads `cloudPhases` first.
- **`download_settings.dart`:** the 云端烘焙 section.
- **New `lib/pages/download/cloud_bake_sheets.dart`:** the stock-unavailable
  dialog, the confirm sheet, and the leftover-pod dialog.

### Settings keys (all `SettingGroup.download`)

- `runpodApiKey` (String, `''`).
- `cloudBakeIncludeLocal` (bool, `true`).
- `cloudBakeActivePod` (String JSON `{podId, token, startedAt, price}`,
  `''`).

## Error handling summary

| Situation | Behaviour |
|---|---|
| No API key | The menu item opens settings with a hint |
| Key invalid / no balance | Message before anything is rented, with an "打开 Runpod" (open Runpod) action |
| No L40S stock in Sydney | Offer laptop-only, rent nothing |
| Pod not ready in 5 min | Delete it, laptop takes everything |
| Upload part fails | Retry ×8 per part; then the episode goes to the laptop |
| Bake fails on pod | Retry with AAC audio; then the laptop; then `failed` |
| Download interrupted | Resume from the parts log |
| Network outage | Keep retrying 10 min, laptop continues; then treat the pod as gone |
| App killed / PC asleep / power off | Pod self-destructs ≤10 min after last contact; startup check offers to delete leftovers |
| Runaway | Hard cap `KAZUMI_CAP_SEC`, shown as "最多 $X" (at most $X) before start |

An episode is marked done only after the full file is downloaded and its size
matches.

## Testing

**Dart unit tests:**
- `CloudBakeSession` scheduling:
  - front and back lanes
  - work stealing
  - failure hand-over to the laptop
  - stop
  - pod lost
- The estimate maths.
- `RunpodApi` request shapes and error mapping against a fake `HttpServer`.
- `CloudBakeWorkerClient` against a fake worker. This covers resume from
  partial parts, and a size mismatch causing a re-download.

**Python tests** (`assets/cloud/test_kazumi_bake_worker.py`, run with the
stdlib `unittest`, with ffmpeg and runpodctl stubbed through env overrides):
- part assembly and size check
- token rejection
- the status state machine
- the watchdog firing on idle and on cap, but not during boot

**One real end-to-end run** (about $0.15): 3 short episodes. Check:
- the outputs play
- the pod deletes itself at the end
- 停止 (stop) partway through deletes it
- killing the app makes the pod self-destruct within about 10 minutes

**Owner check on the PC:** press ☁ on a show, watch the banner and ☁
progress, then confirm the pod is gone in the Runpod console.

## Open items to verify in planning (cheap, before coding)

1. A pod's scoped `RUNPOD_API_KEY` can delete its own pod via `runpodctl`.
   If not, drop worker self-destruct and rely on the app delete, the cap via
   app, and the startup check. Tell the owner.
2. Runpod's env size limit allows the gzip+base64 worker. If not, use the
   bootstrap fallback.
3. The exact REST endpoints and fields for stock and price in OC-AU-1, pod
   create, and the port mapping.
