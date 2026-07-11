import secrets

from fastapi import Header, HTTPException, status
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    database_url: str = "postgresql+psycopg://cvault:cvault@localhost:5432/componentvault"
    api_key: str = "dev-key-change-me"
    cors_origins: str = "*"

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

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
