from __future__ import annotations

import asyncio
import hmac
import logging
import os
from collections import defaultdict
from contextlib import AsyncExitStack, asynccontextmanager, suppress
from pathlib import Path
from typing import Annotated, Any, Literal
from uuid import uuid4

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi import Path as PathParam
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, Response
from pydantic import BaseModel, StringConstraints
from starlette.requests import ClientDisconnect

from .config import Settings
from .library import (
    EPISODE_ID_PATTERN,
    UPLOAD_FILES,
    EpisodeNotFound,
    Library,
    SizeMismatch,
    file_size,
    is_valid_episode_id,
)
from .invites import Invites, RateLimiter
from .room import Room

log = logging.getLogger(__name__)

MEDIA_TYPES = {"video.mp4": "video/mp4", "danmaku.json": "application/json"}
MANIFEST_FIELDS: dict[str, type] = {"sizeBytes": int, "bangumiId": int, "episodeNumber": int, "pluginName": str}
JOIN_PAGE = (Path(__file__).parent / "join.html").read_text(encoding="utf-8")
JOIN_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
    "img-src data:; base-uri 'none'; form-action 'none'",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Cache-Control": "no-cache",
}

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)]
DeviceId = Annotated[str, StringConstraints(min_length=1, max_length=200)]
EpisodeIdField = Annotated[str, StringConstraints(pattern=EPISODE_ID_PATTERN)]


class WatchedBody(BaseModel):
    name: Name


class HeartbeatBody(BaseModel):
    deviceId: DeviceId
    name: Name
    state: Literal["lobby", "watching", "idle"]
    episodeId: EpisodeIdField | None = None


class RedeemBody(BaseModel):
    code: Annotated[str, StringConstraints(max_length=32)]


class LeaveBody(BaseModel):
    deviceId: DeviceId


class SelectBody(BaseModel):
    deviceId: DeviceId
    name: Name
    episodeId: EpisodeIdField


class _Unauthorized(Exception):
    pass


class _MediaFile(FileResponse):
    chunk_size = 1024 * 1024


def _episode_id(episode_id: str) -> str:
    if not is_valid_episode_id(episode_id):
        raise HTTPException(404)
    return episode_id


def _file_name(name: str) -> str:
    if name not in UPLOAD_FILES:
        raise HTTPException(404)
    return name


EpisodeId = Annotated[str, Depends(_episode_id)]
FileName = Annotated[str, Depends(_file_name)]


def _token_matches(request: Request, *keys: str) -> bool:
    # Media players can't always set headers, so the query parameter is accepted too.
    presented = [request.headers.get("x-kazumi-token"), request.query_params.get("token")]
    matched = False
    for token in filter(None, presented):
        for key in keys:
            matched |= hmac.compare_digest(token.encode(), key.encode())
    return matched


def _manifest_problem(manifest: Any) -> str | None:
    if not isinstance(manifest, dict):
        return "manifest must be a JSON object"
    for key, kind in MANIFEST_FIELDS.items():
        # type() rather than isinstance(): JSON true must not pass as an int.
        if type(manifest.get(key)) is not kind:
            return f"{key} must be {'an int' if kind is int else 'a string'}"
    if manifest["sizeBytes"] <= 0:
        return "sizeBytes must be positive"
    return None


async def _housekeeping_loop(library: Library, interval: float) -> None:
    while True:
        try:
            await asyncio.to_thread(library.housekeep)
        except Exception:
            log.exception("housekeeping failed")
        await asyncio.sleep(interval)


def create_app(settings: Settings) -> FastAPI:
    settings.validate()
    library = Library(settings.data_dir, settings.clock)
    room = Room(settings.clock)
    invites = Invites(settings.data_dir / "invites.json", settings.clock)
    redeem_limit = RateLimiter(settings.clock)
    upload_locks: defaultdict[tuple[str, str], asyncio.Lock] = defaultdict(asyncio.Lock)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        library.ensure_dirs()
        task = None
        if settings.housekeeping_interval is not None:
            task = asyncio.create_task(_housekeeping_loop(library, settings.housekeeping_interval))
        try:
            yield
        finally:
            if task is not None:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task

    app = FastAPI(title="Kazumi library", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.library = library
    app.state.room = room

    @app.exception_handler(_Unauthorized)
    async def unauthorized(request: Request, exc: _Unauthorized) -> Response:
        return Response(status_code=401)

    def require_view(request: Request) -> None:
        if not _token_matches(request, settings.view_key, settings.admin_key):
            raise _Unauthorized

    def require_admin(request: Request) -> None:
        if not _token_matches(request, settings.admin_key):
            raise _Unauthorized

    view = [Depends(require_view)]
    admin = [Depends(require_admin)]

    @app.get("/healthz", response_class=PlainTextResponse)
    def healthz() -> str:
        return "ok"

    @app.get("/join", response_class=HTMLResponse)
    def join() -> HTMLResponse:
        return HTMLResponse(JOIN_PAGE, headers=JOIN_HEADERS)

    @app.get("/api/config", dependencies=view)
    def config() -> dict[str, Any]:
        return {
            "syncplay": settings.syncplay_endpoint,
            "syncplayTls": settings.syncplay_tls,
            "room": settings.syncplay_room,
            "mirrors": list(settings.download_mirrors),
        }

    @app.post("/api/invites", dependencies=admin)
    def create_invite() -> dict[str, str]:
        return invites.create()

    @app.post("/api/redeem")
    def redeem(body: RedeemBody, request: Request) -> dict[str, str]:
        client = request.client.host if request.client else "unknown"
        if not redeem_limit.allow(client):
            raise HTTPException(status_code=429)
        if not invites.is_valid(body.code):
            raise HTTPException(status_code=404)
        return {"key": settings.view_key}

    @app.get("/api/episodes", dependencies=view)
    def list_episodes() -> dict[str, Any]:
        return {"episodes": library.list_episodes()}

    @app.api_route("/episodes/{episode_id}/{name}", methods=["GET", "HEAD"], dependencies=view)
    def episode_file(episode_id: EpisodeId, name: FileName) -> Response:
        path = library.episode_file(episode_id, name)
        try:
            stat = path.stat()
        except FileNotFoundError:
            raise HTTPException(404) from None
        return _MediaFile(path, media_type=MEDIA_TYPES[name], stat_result=stat)

    @app.post("/api/episodes/{episode_id}/watched", dependencies=view)
    def watched(episode_id: EpisodeId, body: WatchedBody) -> dict[str, bool]:
        try:
            return {"deleted": library.mark_watched(episode_id, body.name)}
        except EpisodeNotFound:
            raise HTTPException(404) from None

    @app.delete("/api/episodes/{episode_id}", dependencies=admin)
    def delete_episode(episode_id: EpisodeId) -> dict[str, bool]:
        if not library.delete_episode(episode_id):
            raise HTTPException(404)
        return {"deleted": True}

    @app.post("/api/room/heartbeat", dependencies=view)
    def heartbeat(body: HeartbeatBody) -> dict[str, Any]:
        # Builds before /api/room/leave sent an "idle" beat on the way out.
        if body.state == "idle":
            return room.leave(body.deviceId)
        state = room.heartbeat(body.deviceId, body.name, body.state, body.episodeId)
        library.touch_member(body.name)
        return state

    @app.post("/api/room/leave", dependencies=view)
    def leave(body: LeaveBody) -> dict[str, Any]:
        return room.leave(body.deviceId)

    @app.get("/api/room", dependencies=view)
    def get_room() -> dict[str, Any]:
        return room.snapshot()

    @app.post("/api/room/select", dependencies=view)
    def select(body: SelectBody) -> dict[str, Any]:
        state = room.select(body.deviceId, body.name, body.episodeId)
        library.touch_member(body.name)
        return state

    @app.get("/api/upload/{episode_id}/{name}", dependencies=admin)
    def upload_size(episode_id: EpisodeId, name: FileName) -> dict[str, int]:
        return {"size": file_size(library.upload_file(episode_id, name))}

    @app.put("/api/upload/{episode_id}/{name}", dependencies=admin)
    async def upload_chunk(
        request: Request, episode_id: EpisodeId, name: FileName, offset: Annotated[int, Query(ge=0)]
    ) -> Response:
        path = library.upload_file(episode_id, name)
        # A retry can arrive before the server notices the previous connection died;
        # waiting here keeps the two from interleaving appends.
        async with upload_locks[(episode_id, name)]:
            current = file_size(path)
            if offset != current:
                return JSONResponse({"size": current}, status_code=409)
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "ab") as f:
                try:
                    async for chunk in request.stream():
                        f.write(chunk)
                        f.flush()
                except ClientDisconnect:
                    log.info("upload of %s/%s interrupted at %d bytes", episode_id, name, f.tell())
            return JSONResponse({"size": file_size(path)})

    @app.get("/api/upload/{episode_id}/{name}/parts", dependencies=admin)
    def upload_parts(episode_id: EpisodeId, name: FileName) -> dict[str, dict[str, int]]:
        parts = library.upload_parts(episode_id, name)
        return {"parts": {str(index): size for index, size in sorted(parts.items())}}

    # Parts let the uploader run several connections at once; one long-haul TCP stream
    # from a home connection is far slower than the link itself.
    @app.put("/api/upload/{episode_id}/{name}/parts/{index}", dependencies=admin)
    async def upload_part(
        request: Request, episode_id: EpisodeId, name: FileName, index: Annotated[int, PathParam(ge=0, le=100_000)]
    ) -> Response:
        parts = library.parts_dir(episode_id, name)
        parts.mkdir(parents=True, exist_ok=True)
        tmp = parts / f"{index}.{uuid4().hex}.tmp"
        declared = request.headers.get("content-length", "")
        try:
            with open(tmp, "wb") as f:
                try:
                    async for chunk in request.stream():
                        f.write(chunk)
                except ClientDisconnect:
                    log.info("part %d of %s/%s interrupted at %d bytes", index, episode_id, name, f.tell())
                    return Response(status_code=400)
                size = f.tell()
            if declared.isdecimal() and int(declared) != size:
                return JSONResponse({"size": size}, status_code=400)
            os.replace(tmp, parts / str(index))
        finally:
            tmp.unlink(missing_ok=True)
        return JSONResponse({"size": size})

    @app.post("/api/upload/{episode_id}/commit", dependencies=admin)
    async def commit(request: Request, episode_id: EpisodeId) -> Response:
        try:
            manifest = await request.json()
        except ValueError:
            return JSONResponse({"detail": "body must be JSON"}, status_code=422)
        problem = _manifest_problem(manifest)
        if problem:
            return JSONResponse({"detail": problem}, status_code=422)
        async with AsyncExitStack() as stack:
            for name in UPLOAD_FILES:
                await stack.enter_async_context(upload_locks[(episode_id, name)])
            try:
                entry = await run_in_threadpool(library.commit, episode_id, manifest)
            except SizeMismatch as exc:
                return JSONResponse({"size": exc.size}, status_code=409)
        return JSONResponse(entry)

    return app


app = create_app(Settings.from_env())
