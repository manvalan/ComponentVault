"""KiCad fetch queue.

Apps (macOS/iPad/iOS, future Android) ask for components to be added to
the MIKILAB KiCad library; the worker on the Mac -- the only machine
holding the SnapEDA/UltraLibrarian credentials -- claims the job, runs
scripts/fetch_components.py and uploads one KiCad zip (+ 3D render) per
component. The vendor credentials never reach the server or the apps.

  app    (API_KEY)         POST /fetch/jobs                       create
                           GET  /fetch/jobs[/{id}]                status
                           GET  /fetch/jobs/{id}/files/{name}     KiCad zip / render
  worker (WORKER_API_KEY)  POST /fetch/worker/claim               next queued job (204 if none)
                           PUT  /fetch/worker/jobs/{id}/files/{name}
                           POST /fetch/worker/jobs/{id}/complete

Library index (scripts/library_index.py), so the apps know -- also offline,
from their cached copy -- which BOM components are already in the library:
  worker                   PUT  /library/index
  app                      GET  /library/index                    ETag / If-None-Match
"""

import hashlib
import json
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from config import require_api_key, require_worker_key, settings
from database import get_db
from models import FetchJobRow
from schemas import FetchJobComplete, FetchJobIn, FetchJobOut

router = APIRouter(prefix="/fetch")
library_router = APIRouter(prefix="/library")

# A job whose worker died is handed out again after this long.
STALE_AFTER = timedelta(hours=2)
_FILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,150}\.(zip|png)$")
_MEDIA_TYPES = {"zip": "application/zip", "png": "image/png"}


def job_to_out(row: FetchJobRow) -> FetchJobOut:
    return FetchJobOut(
        id=row.id,
        status=row.status,
        createdAt=row.created_at.isoformat() if row.created_at else None,
        updatedAt=row.updated_at.isoformat() if row.updated_at else None,
        request=row.request or {},
        result=row.result or {},
        error=row.error or "",
    )


def get_job(db: Session, job_id: str) -> FetchJobRow:
    try:
        uuid.UUID(job_id)
    except ValueError:
        raise HTTPException(status_code=404, detail="Richiesta non trovata")
    row = db.get(FetchJobRow, job_id)
    if not row:
        raise HTTPException(status_code=404, detail="Richiesta non trovata")
    return row


async def read_limited_body(request: Request) -> bytes:
    limit = settings.fetch_max_upload_mb * 1024 * 1024
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > limit:
            raise HTTPException(status_code=413, detail="File troppo grande")
    return bytes(body)


def job_file(job_id: str, name: str) -> Path:
    if not _FILE_NAME_RE.match(name):
        raise HTTPException(status_code=400, detail="Nome file non valido")
    base = Path(settings.fetch_files_dir).resolve()
    path = (base / job_id / name).resolve()
    if base not in path.parents:
        raise HTTPException(status_code=400, detail="Nome file non valido")
    return path


# ------------------------------------------------------------------ app side


@router.post("/jobs", response_model=FetchJobOut, status_code=201)
def create_job(
    payload: FetchJobIn,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> FetchJobOut:
    row = FetchJobRow(id=str(uuid.uuid4()), status="queued", request=payload.model_dump(), result={})
    db.add(row)
    db.commit()
    db.refresh(row)
    return job_to_out(row)


@router.get("/jobs", response_model=list[FetchJobOut])
def list_jobs(
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> list[FetchJobOut]:
    rows = db.scalars(select(FetchJobRow).order_by(FetchJobRow.created_at.desc()).limit(limit)).all()
    return [job_to_out(r) for r in rows]


@router.get("/jobs/{job_id}", response_model=FetchJobOut)
def read_job(
    job_id: str,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> FetchJobOut:
    return job_to_out(get_job(db, job_id))


@router.get("/jobs/{job_id}/files/{name}")
def download_file(
    job_id: str,
    name: str,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> FileResponse:
    get_job(db, job_id)
    path = job_file(job_id, name)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File non trovato")
    return FileResponse(path, media_type=_MEDIA_TYPES[path.suffix[1:]], filename=name)


# --------------------------------------------------------------- worker side


@router.post("/worker/claim", response_model=FetchJobOut)
def claim_job(
    db: Session = Depends(get_db),
    _: None = Depends(require_worker_key),
):
    now = datetime.now(timezone.utc)
    db.execute(
        update(FetchJobRow)
        .where(FetchJobRow.status == "running", FetchJobRow.claimed_at < now - STALE_AFTER)
        .values(status="queued", claimed_at=None)
    )
    row = db.scalars(
        select(FetchJobRow)
        .where(FetchJobRow.status == "queued")
        .order_by(FetchJobRow.created_at)
        .limit(1)
        .with_for_update(skip_locked=True)
    ).first()
    if row is None:
        db.commit()
        return Response(status_code=204)
    row.status = "running"
    row.claimed_at = now
    db.commit()
    db.refresh(row)
    return job_to_out(row)


@router.put("/worker/jobs/{job_id}/files/{name}", status_code=201)
async def upload_file(
    job_id: str,
    name: str,
    request: Request,
    db: Session = Depends(get_db),
    _: None = Depends(require_worker_key),
) -> dict:
    row = get_job(db, job_id)
    if row.status != "running":
        raise HTTPException(status_code=409, detail="La richiesta non è in esecuzione")
    path = job_file(job_id, name)
    body = await read_limited_body(request)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_bytes(body)
    tmp.replace(path)
    return {"name": name, "bytes": len(body)}


@router.post("/worker/jobs/{job_id}/complete", response_model=FetchJobOut)
def complete_job(
    job_id: str,
    payload: FetchJobComplete,
    db: Session = Depends(get_db),
    _: None = Depends(require_worker_key),
) -> FetchJobOut:
    row = get_job(db, job_id)
    if row.status != "running":
        raise HTTPException(status_code=409, detail="La richiesta non è in esecuzione")
    row.status = payload.status
    row.result = payload.result
    row.error = payload.error
    db.commit()
    db.refresh(row)
    return job_to_out(row)


# ------------------------------------------------------------- library index


def library_index_path() -> Path:
    return Path(settings.fetch_files_dir) / "library_index.json"


@library_router.put("/index")
async def put_library_index(
    request: Request,
    _: None = Depends(require_worker_key),
) -> dict:
    body = await read_limited_body(request)
    try:
        data = json.loads(body)
    except ValueError:
        raise HTTPException(status_code=400, detail="JSON non valido")
    if not isinstance(data, dict) or not isinstance(data.get("components"), list):
        raise HTTPException(status_code=400, detail="Atteso un oggetto con 'components'")
    path = library_index_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".part")
    tmp.write_bytes(body)
    tmp.replace(path)
    return {"components": len(data["components"]), "etag": hashlib.sha256(body).hexdigest()[:32]}


@library_router.get("/index")
def get_library_index(
    if_none_match: str | None = Header(default=None),
    _: None = Depends(require_api_key),
) -> Response:
    path = library_index_path()
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Indice libreria non ancora pubblicato dal worker")
    body = path.read_bytes()
    etag = '"' + hashlib.sha256(body).hexdigest()[:32] + '"'
    if if_none_match and if_none_match.strip() == etag:
        return Response(status_code=304, headers={"ETag": etag})
    return Response(content=body, media_type="application/json", headers={"ETag": etag})
