from typing import Literal

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


# --- KiCad fetch queue -------------------------------------------------------

KiCadCategory = Literal[
    "analog", "audio", "display", "fpga_cpld", "interface", "logic",
    "mechanical", "memory", "microcontrollers", "other", "power", "rf",
]


class FetchItemIn(BaseModel):
    mpn: str = Field(min_length=1, max_length=128)
    lcsc: str | None = Field(default=None, pattern=r"^C\d{1,12}$")
    ref: str = Field(default="", max_length=64)
    funzione: str = Field(default="", max_length=256)
    nome: str | None = Field(default=None, max_length=128, pattern=r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
    categoria: KiCadCategory | None = None


class FetchJobIn(BaseModel):
    items: list[FetchItemIn] = Field(min_length=1, max_length=100)
    update: bool = False


class FetchJobOut(BaseModel):
    id: str
    status: str
    createdAt: str | None = None
    updatedAt: str | None = None
    request: dict = {}
    result: dict = {}
    error: str = ""


class FetchJobComplete(BaseModel):
    status: Literal["done", "partial", "failed"]
    result: dict = {}
    error: str = Field(default="", max_length=4000)
