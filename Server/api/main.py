from datetime import datetime, timezone
import secrets

from fastapi import Depends, FastAPI, Header
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import func, select
from sqlalchemy.orm import Session, joinedload

from config import extract_api_key, require_api_key, settings
from database import get_db, init_db
from models import ComponentRow, ProjectItemRow, ProjectRow
from schemas import (
    ComponentIn,
    ComponentOut,
    HealthResponse,
    ProjectIn,
    ProjectItemIn,
    ProjectOut,
    ProjectSyncPushRequest,
    ProjectSyncPushResponse,
    SyncPushRequest,
    SyncPushResponse,
)

app = FastAPI(title="ComponentVault API", version="0.4.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def on_startup() -> None:
    init_db()


def row_to_out(row: ComponentRow) -> ComponentOut:
    return ComponentOut(
        lcscCode=row.lcsc_code,
        mpn=row.mpn,
        name=row.name,
        description=row.description,
        footprint=row.footprint,
        quantity=row.quantity,
        category=row.category,
        value=row.value,
        brand=row.brand,
        datasheetURL=row.datasheet_url,
        imageURLs=row.image_urls or [],
        price=row.price,
        currency=row.currency,
        supplierStock=row.supplier_stock,
        dataSource=row.data_source,
        parameters=row.parameters or {},
        notes=row.notes,
        minQuantity=row.min_quantity,
        tags=row.tags or [],
        updatedAt=row.updated_at.isoformat() if row.updated_at else None,
    )


def apply_in(row: ComponentRow, data: ComponentIn) -> None:
    row.mpn = data.mpn
    row.name = data.name
    row.description = data.description
    row.footprint = data.footprint
    row.quantity = data.quantity
    row.category = data.category
    row.value = data.value
    row.brand = data.brand
    row.datasheet_url = data.datasheetURL
    row.image_urls = data.imageURLs
    row.price = data.price
    row.currency = data.currency
    row.supplier_stock = data.supplierStock
    row.data_source = data.dataSource
    row.parameters = data.parameters
    row.notes = data.notes
    row.min_quantity = data.minQuantity
    row.tags = data.tags
    row.updated_at = datetime.now(timezone.utc)


@app.get("/health", response_model=HealthResponse)
def health(
    db: Session = Depends(get_db),
    x_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> HealthResponse:
    token = extract_api_key(x_api_key, authorization)
    if not token or not secrets.compare_digest(token, settings.api_key):
        return HealthResponse(status="ok", components=-1)
    count = db.scalar(select(func.count()).select_from(ComponentRow)) or 0
    return HealthResponse(status="ok", components=count)


@app.get("/components", response_model=list[ComponentOut])
def list_components(
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> list[ComponentOut]:
    rows = db.scalars(select(ComponentRow).order_by(ComponentRow.lcsc_code)).all()
    return [row_to_out(r) for r in rows]


@app.get("/components/{lcsc_code}", response_model=ComponentOut)
def get_component(
    lcsc_code: str,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> ComponentOut:
    row = db.get(ComponentRow, lcsc_code.upper())
    if not row:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="Componente non trovato")
    return row_to_out(row)


@app.put("/components/{lcsc_code}", response_model=ComponentOut)
def upsert_component(
    lcsc_code: str,
    payload: ComponentIn,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> ComponentOut:
    code = lcsc_code.upper()
    row = db.get(ComponentRow, code)
    if not row:
        row = ComponentRow(lcsc_code=code)
        db.add(row)
    payload.lcscCode = code
    apply_in(row, payload)
    db.commit()
    db.refresh(row)
    return row_to_out(row)


@app.post("/sync/push", response_model=SyncPushResponse)
def sync_push(
    payload: SyncPushRequest,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> SyncPushResponse:
    upserted = 0
    for item in payload.components:
        code = item.lcscCode.upper()
        row = db.get(ComponentRow, code)
        if not row:
            row = ComponentRow(lcsc_code=code)
            db.add(row)
        item.lcscCode = code
        apply_in(row, item)
        upserted += 1
    db.commit()
    return SyncPushResponse(upserted=upserted)


def project_row_to_out(row: ProjectRow) -> ProjectOut:
    return ProjectOut(
        name=row.name,
        description=row.project_description,
        updatedAt=row.updated_at.isoformat() if row.updated_at else None,
        items=[
            ProjectItemIn(
                designator=item.designator,
                lcscCode=item.lcsc_code,
                requiredQuantity=item.required_quantity,
                notes=item.notes,
            )
            for item in row.items
        ],
    )


def apply_project_in(row: ProjectRow, data: ProjectIn) -> None:
    row.project_description = data.description
    row.updated_at = datetime.now(timezone.utc)
    row.items.clear()
    for item in data.items:
        row.items.append(
            ProjectItemRow(
                project_name=row.name,
                designator=item.designator,
                lcsc_code=item.lcscCode.upper(),
                required_quantity=item.requiredQuantity,
                notes=item.notes,
            )
        )


@app.get("/projects", response_model=list[ProjectOut])
def list_projects(
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> list[ProjectOut]:
    rows = db.scalars(
        select(ProjectRow).options(joinedload(ProjectRow.items)).order_by(ProjectRow.name)
    ).unique().all()
    return [project_row_to_out(r) for r in rows]


@app.post("/sync/projects/push", response_model=ProjectSyncPushResponse)
def sync_projects_push(
    payload: ProjectSyncPushRequest,
    db: Session = Depends(get_db),
    _: None = Depends(require_api_key),
) -> ProjectSyncPushResponse:
    upserted = 0
    for item in payload.projects:
        row = db.get(ProjectRow, item.name)
        if not row:
            row = ProjectRow(name=item.name)
            db.add(row)
        apply_project_in(row, item)
        upserted += 1
    db.commit()
    return ProjectSyncPushResponse(upserted=upserted)
