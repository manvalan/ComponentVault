from datetime import datetime

from sqlalchemy import DateTime, Float, ForeignKey, Integer, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class ComponentRow(Base):
    __tablename__ = "components"

    lcsc_code: Mapped[str] = mapped_column(String(32), primary_key=True)
    mpn: Mapped[str] = mapped_column(String(128), default="")
    name: Mapped[str] = mapped_column(String(256), default="")
    description: Mapped[str] = mapped_column(Text, default="")
    footprint: Mapped[str] = mapped_column(String(64), default="")
    quantity: Mapped[int] = mapped_column(Integer, default=0)
    category: Mapped[str] = mapped_column(String(256), default="")
    value: Mapped[str] = mapped_column(String(64), default="")
    brand: Mapped[str] = mapped_column(String(128), default="")
    datasheet_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    image_urls: Mapped[list] = mapped_column(JSONB, default=list)
    price: Mapped[float | None] = mapped_column(Float, nullable=True)
    currency: Mapped[str | None] = mapped_column(String(8), nullable=True)
    supplier_stock: Mapped[int | None] = mapped_column(Integer, nullable=True)
    data_source: Mapped[str] = mapped_column(String(16), default="manual")
    parameters: Mapped[dict] = mapped_column(JSONB, default=dict)
    notes: Mapped[str] = mapped_column(Text, default="")
    min_quantity: Mapped[int] = mapped_column(Integer, default=0)
    tags: Mapped[list] = mapped_column(JSONB, default=list)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )


class ProjectRow(Base):
    __tablename__ = "projects"

    name: Mapped[str] = mapped_column(String(128), primary_key=True)
    project_description: Mapped[str] = mapped_column(Text, default="")
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )
    items: Mapped[list["ProjectItemRow"]] = relationship(
        back_populates="project",
        cascade="all, delete-orphan",
    )


class ProjectItemRow(Base):
    __tablename__ = "project_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    project_name: Mapped[str] = mapped_column(ForeignKey("projects.name", ondelete="CASCADE"))
    designator: Mapped[str] = mapped_column(String(128), default="")
    lcsc_code: Mapped[str] = mapped_column(String(32), default="")
    required_quantity: Mapped[int] = mapped_column(Integer, default=1)
    notes: Mapped[str] = mapped_column(Text, default="")
    project: Mapped[ProjectRow] = relationship(back_populates="items")
