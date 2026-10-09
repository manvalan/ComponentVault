import secrets

from fastapi import Header, HTTPException, status
from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Credentials belong in Server/.env only — never embed user:password in source.
    database_url: str = ""
    api_key: str = ""
    cors_origins: str = "*"
    # KiCad fetch queue: the worker (Mac with the MIKILAB library and the
    # SnapEDA/UltraLibrarian credentials) uses its own key, so an app key
    # can never claim jobs or upload files. Empty = worker endpoints off.
    worker_api_key: str = ""
    fetch_files_dir: str = "/data/fetch_files"
    fetch_max_upload_mb: int = 60

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    @model_validator(mode="after")
    def require_secrets_from_env(self) -> "Settings":
        if not self.database_url.strip():
            raise ValueError("DATABASE_URL mancante: copia Server/.env.example in .env")
        if not self.api_key.strip():
            raise ValueError("API_KEY mancante: genera una chiave in Server/.env")
        if self.worker_api_key.strip() and secrets.compare_digest(self.worker_api_key, self.api_key):
            raise ValueError("WORKER_API_KEY deve essere diversa da API_KEY")
        return self

    @property
    def cors_origin_list(self) -> list[str]:
        if self.cors_origins.strip() == "*":
            return ["*"]
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


settings = Settings()


def extract_api_key(
    x_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> str | None:
    if x_api_key:
        return x_api_key.strip()
    if authorization and authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return None


def require_api_key(
    x_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    token = extract_api_key(x_api_key, authorization)
    if not token or not secrets.compare_digest(token, settings.api_key):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="API key non valida",
        )


def require_worker_key(
    x_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    if not settings.worker_api_key.strip():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Worker KiCad non configurato (WORKER_API_KEY)",
        )
    token = extract_api_key(x_api_key, authorization)
    if not token or not secrets.compare_digest(token, settings.worker_api_key):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Worker key non valida",
        )
