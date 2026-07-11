from pydantic import BaseModel, Field


class ComponentIn(BaseModel):
    lcscCode: str = Field(max_length=32)
    mpn: str = ""
    name: str = ""
    description: str = ""
    footprint: str = ""
    quantity: int = 0
    category: str = ""
    value: str = ""
    brand: str = ""
    datasheetURL: str | None = None
    imageURLs: list[str] = []
    price: float | None = None
    currency: str | None = None
    supplierStock: int | None = None
    dataSource: str = "manual"
    parameters: dict[str, str] = {}
    notes: str = ""
    minQuantity: int = 0
    tags: list[str] = []


class ComponentOut(ComponentIn):
    updatedAt: str | None = None


class SyncPushRequest(BaseModel):
    components: list[ComponentIn]


class SyncPushResponse(BaseModel):
    upserted: int


class HealthResponse(BaseModel):
    status: str
    components: int


class ProjectItemIn(BaseModel):
    designator: str = ""
    lcscCode: str = ""
    requiredQuantity: int = 1
    notes: str = ""


class ProjectIn(BaseModel):
    name: str = Field(max_length=128)
    description: str = ""
    updatedAt: str | None = None
    items: list[ProjectItemIn] = []


class ProjectOut(ProjectIn):
    pass


class ProjectSyncPushRequest(BaseModel):
    projects: list[ProjectIn]


class ProjectSyncPushResponse(BaseModel):
    upserted: int
