#!/usr/bin/env python3
"""
Autenticazione e ricerca DigiKey — flusso ufficiale OAuth 2.0 (3-legged).

Documentazione: https://developer.digikey.com/documentation

Uso:
  # 1. Prima autenticazione (apre URL, incolli il redirect)
  python3 digikey_auth.py

  # 2. Ricerca per MPN
  python3 digikey_auth.py --search INA219AIDR

  # 3. Solo rinnovo token
  python3 digikey_auth.py --refresh

Requisiti:
  pip3 install requests pyyaml
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
from pathlib import Path

import requests
import yaml

BASE_DIR = Path("/Users/michelebigi/LCSC")
CONFIG_PATH = BASE_DIR / "digikey_config.yml"
TOKEN_CACHE = BASE_DIR / "digikey_token_cache.json"

AUTH_URL = "https://api.digikey.com/v1/oauth2/authorize"
TOKEN_URL = "https://api.digikey.com/v1/oauth2/token"
SEARCH_URL = "https://api.digikey.com/products/v4/search/keyword"


def load_config() -> dict:
    with CONFIG_PATH.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def save_tokens(data: dict) -> None:
    data["expires_at"] = time.time() + int(data.get("expires_in", 0))
    TOKEN_CACHE.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(f"Token salvato in {TOKEN_CACHE}")


def load_tokens() -> dict | None:
    if not TOKEN_CACHE.exists():
        return None
    try:
        return json.loads(TOKEN_CACHE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def build_auth_url(client_id: str, redirect_uri: str) -> str:
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
    }
    return AUTH_URL + "?" + urllib.parse.urlencode(params)


def exchange_code(code: str, config: dict) -> dict:
    data = {
        "code": code,
        "client_id": config["client_id"],
        "client_secret": config["client_secret"],
        "redirect_uri": config["callback_url"],
        "grant_type": "authorization_code",
    }
    response = requests.post(TOKEN_URL, data=data, timeout=30)
    if response.status_code != 200:
        raise RuntimeError(f"Scambio code fallito ({response.status_code}): {response.text}")
    return response.json()


def refresh_tokens(refresh_token: str, config: dict) -> dict:
    data = {
        "refresh_token": refresh_token,
        "client_id": config["client_id"],
        "client_secret": config["client_secret"],
        "grant_type": "refresh_token",
    }
    response = requests.post(TOKEN_URL, data=data, timeout=30)
    if response.status_code != 200:
        raise RuntimeError(f"Refresh fallito ({response.status_code}): {response.text}")
    return response.json()


def get_access_token(config: dict, force_auth: bool = False) -> str:
    tokens = None if force_auth else load_tokens()

    if tokens and time.time() < tokens.get("expires_at", 0) - 60:
        return tokens["access_token"]

    if tokens and tokens.get("refresh_token"):
        print("Rinnovo token con refresh_token…")
        new_tokens = refresh_tokens(tokens["refresh_token"], config)
        if "refresh_token" not in new_tokens and tokens.get("refresh_token"):
            new_tokens["refresh_token"] = tokens["refresh_token"]
        save_tokens(new_tokens)
        return new_tokens["access_token"]

    # Autenticazione 3-legged
    redirect_uri = config["callback_url"]
    auth_url = build_auth_url(config["client_id"], redirect_uri)

    print("\n=== AUTENTICAZIONE DIGIKEY (una tantum) ===\n")
    print("1. Apri questo URL nel browser e fai login su DigiKey:")
    print(auth_url)
    print("\n2. Dopo il consenso verrai reindirizzato (la pagina può dare errore — è normale).")
    print(f"3. Copia l'INTERO URL dalla barra indirizzi (deve contenere ?code=…)")
    print(f"   Il redirect_uri registrato deve essere ESATTAMENTE: {redirect_uri}\n")

    returned_url = input("Incolla qui l'URL di redirect: ").strip()
    if "code=" not in returned_url:
        raise ValueError("URL non valido: manca ?code=")

    code = urllib.parse.parse_qs(urllib.parse.urlparse(returned_url).query)["code"][0]
    tokens = exchange_code(code, config)
    save_tokens(tokens)
    return tokens["access_token"]


def search_mpn(mpn: str, config: dict, access_token: str) -> dict:
    headers = {
        "Authorization": f"Bearer {access_token}",
        "X-DIGIKEY-Client-Id": config["client_id"],
        "X-DIGIKEY-Locale-Site": config.get("market", "IT"),
        "X-DIGIKEY-Locale-Language": config.get("language", "it"),
        "X-DIGIKEY-Locale-Currency": config.get("currency", "EUR"),
        "Content-Type": "application/json",
    }
    body = {"Keywords": mpn, "RecordCount": 3}
    response = requests.post(SEARCH_URL, headers=headers, json=body, timeout=30)
    if response.status_code != 200:
        raise RuntimeError(f"Ricerca fallita ({response.status_code}): {response.text}")
    return response.json()


def main() -> None:
    parser = argparse.ArgumentParser(description="DigiKey OAuth + Keyword Search")
    parser.add_argument("--search", metavar="MPN", help="Cerca un MPN su DigiKey")
    parser.add_argument("--refresh", action="store_true", help="Forza rinnovo token")
    parser.add_argument("--auth", action="store_true", help="Forza nuova autenticazione browser")
    args = parser.parse_args()

    if not CONFIG_PATH.exists():
        raise SystemExit(f"Config non trovato: {CONFIG_PATH}")

    config = load_config()
    token = get_access_token(config, force_auth=args.auth or args.refresh)

    if args.search:
        print(f"\nRicerca DigiKey: {args.search}")
        result = search_mpn(args.search, config, token)
        products = result.get("Products") or result.get("products") or []
        print(f"Trovati {len(products)} risultati\n")
        print(json.dumps(result, indent=2, ensure_ascii=False)[:4000])
    else:
        print("\nToken OK. Prova: python3 digikey_auth.py --search INA219AIDR")


if __name__ == "__main__":
    main()
