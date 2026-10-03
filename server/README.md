# kazumi-library

A small FastAPI service that runs on the Singapore VPS behind Caddy at
`https://kazumi.kaic5504.com`. It does three jobs:

- holds pre-upscaled episodes the PC uploads, and serves them to the Kazumi app with
  HTTP Range support
- runs the "watch together" lobby: who is online, and which episode was picked
- serves the invite page at `/join#k=<view key>`, which opens the app through
  `kazumi-library://join?...`

Playback sync is a separate Syncplay server. This service only hands out its address.
There is no database. Everything lives as files under `KAZUMI_LIBRARY_DATA`.

## Run the tests

```sh
cd server
uv sync
uv run pytest
```

To run it locally:

```sh
KAZUMI_VIEW_KEY=local-view-key-000000000000 KAZUMI_ADMIN_KEY=local-admin-key-00000000000 \
  uv run uvicorn kazumi_library.app:app --port 8770
```

Then open `http://127.0.0.1:8770/join#k=local-view-key-000000000000`.

## Environment

| Variable | Meaning |
| --- | --- |
| `KAZUMI_LIBRARY_DATA` | Data directory. Defaults to `./data`. Use `/srv/kazumi-library` on the VPS. |
| `KAZUMI_VIEW_KEY` | Key for watching, the lobby and the invite link. Must be at least 24 characters. |
| `KAZUMI_ADMIN_KEY` | Key for uploading and deleting. Must be at least 24 characters and different from the view key. |
| `KAZUMI_SYNCPLAY_ENDPOINT` | Syncplay `host:port` returned by `/api/config`, e.g. `kazumi.kaic5504.com:8999`. |
| `KAZUMI_SYNCPLAY_ROOM` | Syncplay room name returned by `/api/config`. |
| `KAZUMI_SYNCPLAY_TLS` | `1` once the Syncplay server runs with `--tls`; tells clients to request TLS. |

If either key is missing or too short, the service refuses to start. Generate keys with
`python3 -c "import secrets; print(secrets.token_urlsafe(32))"`. Keys belong only in
`/etc/kazumi-library.env`. Never commit them.

## Deploy (Ubuntu 24.04)

1. Create the user and directories:

   ```sh
   sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin kazumi-library
   sudo mkdir -p /opt/kazumi-library /srv/kazumi-library
   sudo chown kazumi-library:kazumi-library /srv/kazumi-library
   sudo chmod 750 /srv/kazumi-library
   ```

2. Copy this directory to `/opt/kazumi-library`, leaving out `.venv/` and `data/`. Then
   build the venv against the **system** Python:

   ```sh
   cd /opt/kazumi-library
   sudo UV_PYTHON_DOWNLOADS=never uv sync --frozen --no-dev --python /usr/bin/python3.12
   ```

   Don't let uv use one of its own Python builds here. Those live under a home directory,
   and `ProtectHome=yes` hides home directories from the service, so the venv's interpreter
   symlink would break.

3. Copy `deploy/kazumi-library.env.example` to `/etc/kazumi-library.env` and fill in the
   keys. Then set its permissions:

   ```sh
   sudo chown root:kazumi-library /etc/kazumi-library.env
   sudo chmod 640 /etc/kazumi-library.env
   ```

4. Install and start the service:

   ```sh
   sudo cp deploy/kazumi-library.service /etc/systemd/system/
   sudo systemd-analyze verify /etc/systemd/system/kazumi-library.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now kazumi-library
   curl http://127.0.0.1:8770/healthz   # ok
   ```

5. Add `deploy/Caddyfile.snippet` to `/etc/caddy/Caddyfile`, then validate and reload:

   ```sh
   sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   sudo systemctl reload caddy
   ```

   Before this step, the DNS A record for `kazumi.kaic5504.com` must point at the VPS.

6. Check the public endpoint:

   ```sh
   curl https://kazumi.kaic5504.com/healthz
   curl -H "X-Kazumi-Token: $VIEW_KEY" https://kazumi.kaic5504.com/api/config
   ```

The invite link to send is `https://kazumi.kaic5504.com/join#k=<view key>`. The key sits
in the fragment, so it never reaches Caddy or this service.

## API summary

All `/api/*` and `/episodes/*` routes need the `X-Kazumi-Token` header or `?token=`.

| | Route | Key |
| --- | --- | --- |
| GET | `/healthz`, `/join` | none |
| POST | `/api/redeem` (invite code to view key; 5 tries/min per client) | none |
| POST | `/api/invites` (new 8-character code, valid 7 days) | admin |
| GET | `/api/config`, `/api/episodes`, `/api/room` | view |
| GET/HEAD | `/episodes/{id}/video.mp4`, `/episodes/{id}/danmaku.json` | view |
| POST | `/api/episodes/{id}/watched`, `/api/room/heartbeat`, `/api/room/select` | view |
| GET/PUT | `/api/upload/{id}/{video.mp4,danmaku.json}` (`PUT ?offset=N`) | admin |
| POST | `/api/upload/{id}/commit` | admin |
| DELETE | `/api/episodes/{id}` | admin |

Episodes are removed in three cases:

- every member seen in the last 30 days has marked the episode watched
- 30 days have passed since its first watch
- an admin deletes it

Partial uploads are removed after 7 days without new bytes. The cleanup check runs hourly.
