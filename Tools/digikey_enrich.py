#!/usr/bin/env python3
"""
Arricchisce l'inventario con dati DigiKey (Product Information V4).

Uso:
  python3 digikey_enrich.py --csv "/Users/michelebigi/LCSC/Componenti Elettronici.csv"
  python3 digikey_enrich.py --csv inventario.csv --json-dir digikey_json_data
  python3 digikey_enrich.py --search INA219AIDR

Output:
  - digikey_json_data/{LCSC}.json  (formato ComponentRecord, dataSource=digikey)

Requisiti:
  pip3 install requests pyyaml
  Token in /Users/michelebigi/LCSC/digikey_token_cache.json (app o digikey_auth.py)
"""

from __future__ import annotations

import argparse
import csv
import json
import time
from pathlib import Path

import requests
import yaml

BASE_DIR = Path("/Users/michelebigi/LCSC")
CONFIG_PATH = BASE_DIR / "digikey_config.yml"
TOKEN_CACHE = BASE_DIR / "digikey_token_cache.json"
DEFAULT_JSON_DIR = BASE_DIR / "digikey_json_data"

AUTH_URL = "https://api.digikey.com/v1/oauth2/authorize"
TOKEN_URL = "https://api.digikey.com/v1/oauth2/token"
SEARCH_URL = "https://api.digikey.com/products/v4/search/keyword"
SANDBOX_TOKEN_URL = "https://sandbox-api.digikey.com/v1/oauth2/token"
SANDBOX_SEARCH_URL = "https://sandbox-api.digikey.com/products/v4/search/keyword"


def load_config() -> dict:
    with CONFIG_PATH.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def api_urls(config: dict) -> tuple[str, str]:
    if str(config.get("environment", "production")).lower() == "sandbox":
        return SANDBOX_TOKEN_URL, SANDBOX_SEARCH_URL
    return TOKEN_URL, SEARCH_URL


def load_tokens() -> dict | None:
    if not TOKEN_CACHE.exists():
        return None
    return json.loads(TOKEN_CACHE.read_text(encoding="utf-8"))


def refresh_tokens(refresh_token: str, config: dict, token_url: str) -> dict:
    data = {
        "refresh_token": refresh_token,
        "client_id": config["client_id"],
        "client_secret": config["client_secret"],
        "grant_type": "refresh_token",
    }
    response = requests.post(token_url, data=data, timeout=30)
    response.raise_for_status()
    payload = response.json()
    payload["expires_at"] = time.time() + int(payload.get("expires_in", 0))
    TOKEN_CACHE.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return payload


def access_token(config: dict) -> str:
    token_url, _ = api_urls(config)
    tokens = load_tokens()
    if not tokens:
        raise SystemExit("Token assente. Usa l'app (Impostazioni → DigiKey) o digikey_auth.py")

    if time.time() < tokens.get("expires_at", 0) - 60:
        return tokens["access_token"]

    if tokens.get("refresh_token"):
        tokens = refresh_tokens(tokens["refresh_token"], config, token_url)
        return tokens["access_token"]

    raise SystemExit("Token scaduto. Ripeti il login da Impostazioni → DigiKey.")


def infer_value(parameters: dict[str, str]) -> str:
    for key in ("Resistance", "Capacitance", "Inductance", "Voltage - Rated"):
        value = parameters.get(key)
        if value:
            return value
    return "N/A"


def parse_product(product: dict, *, lcsc_code: str, mpn: str, currency: str) -> dict:
    parameters = {
        p.get("ParameterText", ""): p.get("ValueText", "")
        for p in product.get("Parameters") or []
        if p.get("ParameterText")
    }
    description = (product.get("Description") or {}).get("ProductDescription", "")
    manufacturer = (product.get("Manufacturer") or {}).get("Name", "")
    category = (product.get("Category") or {}).get("Name", "")

    return {
        "lcscCode": lcsc_code,
        "mpn": product.get("ManufacturerProductNumber") or mpn,
        "name": product.get("ManufacturerProductNumber") or mpn,
        "description": description,
        "footprint": parameters.get("Package / Case") or parameters.get("Package") or "",
        "category": category,
        "value": infer_value(parameters),
        "brand": manufacturer,
        "datasheetURL": product.get("DatasheetUrl"),
        "imageURLs": [product["PhotoUrl"]] if product.get("PhotoUrl") else [],
        "price": product.get("UnitPrice"),
        "currency": currency,
        "supplierStock": product.get("QuantityAvailable"),
        "dataSource": "digikey",
        "parameters": parameters,
        "digikeyPartNumber": product.get("DigiKeyPartNumber"),
        "supplierProductURL": product.get("ProductUrl"),
    }


def search_mpn(mpn: str, config: dict, token: str, record_count: int = 3) -> list[dict]:
    _, search_url = api_urls(config)
    headers = {
        "Authorization": f"Bearer {token}",
        "X-DIGIKEY-Client-Id": config["client_id"],
        "X-DIGIKEY-Locale-Site": config.get("market", "IT"),
        "X-DIGIKEY-Locale-Language": config.get("language", "it"),
        "X-DIGIKEY-Locale-Currency": config.get("currency", "EUR"),
        "Content-Type": "application/json",
    }
    body = {"Keywords": mpn, "RecordCount": record_count}
    response = requests.post(search_url, headers=headers, json=body, timeout=30)
    if response.status_code != 200:
        raise RuntimeError(f"Ricerca fallita ({response.status_code}): {response.text}")
    data = response.json()
    return data.get("Products") or []


def load_inventory(csv_path: Path) -> list[dict]:
    with csv_path.open(encoding="utf-8") as f:
        reader = csv.reader(f, delimiter=";")
        rows = list(reader)
    if not rows:
        return []

    header = [c.strip().lower() for c in rows[0]]
    lcsc_idx = next((i for i, h in enumerate(header) if "lcsc" in h or "codice" in h), 0)
    mpn_idx = next((i for i, h in enumerate(header) if "mpn" in h), 1)

    items = []
    for row in rows[1:]:
        if len(row) <= max(lcsc_idx, mpn_idx):
            continue
        lcsc = row[lcsc_idx].strip()
        mpn = row[mpn_idx].strip()
        if lcsc and mpn:
            items.append({"lcscCode": lcsc, "mpn": mpn})
    return items


def enrich_inventory(
    items: list[dict],
    config: dict,
    json_dir: Path,
    delay_s: float,
    *,
    force: bool = False,
) -> tuple[int, int, int]:
    token = access_token(config)
    currency = config.get("currency", "EUR")
    json_dir.mkdir(parents=True, exist_ok=True)

    ok = 0
    skipped = 0
    errors = 0

    for item in items:
        lcsc = item["lcscCode"]
        mpn = item["mpn"]
        out_path = json_dir / f"{lcsc}.json"

        if out_path.exists() and not force:
            skipped += 1
            continue

        try:
            products = search_mpn(mpn, config, token)
            if not products:
                errors += 1
                print(f"  ✗ {lcsc} {mpn}: nessun risultato")
                continue

            exact = [
                p for p in products
                if (p.get("ManufacturerProductNumber") or "").upper() == mpn.upper()
            ]
            product = exact[0] if len(exact) == 1 else products[0]
            record = parse_product(product, lcsc_code=lcsc, mpn=mpn, currency=currency)
            out_path.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")
            ok += 1
            print(f"  ✓ {lcsc} → {record.get('digikeyPartNumber', mpn)}")
            time.sleep(delay_s)
        except Exception as exc:
            errors += 1
            print(f"  ✗ {lcsc} {mpn}: {exc}")

    return ok, skipped, errors


def main() -> None:
    parser = argparse.ArgumentParser(description="Arricchimento batch DigiKey")
    parser.add_argument("--csv", type=Path, help="CSV inventario (LCSC;MPN;…)")
    parser.add_argument("--json-dir", type=Path, default=DEFAULT_JSON_DIR)
    parser.add_argument("--delay", type=float, default=0.8, help="Secondi tra richieste")
    parser.add_argument("--force", action="store_true", help="Riscarica anche se JSON esiste")
    parser.add_argument("--search", metavar="MPN", help="Prova singola ricerca")
    args = parser.parse_args()

    if not CONFIG_PATH.exists():
        raise SystemExit(f"Config non trovato: {CONFIG_PATH}")

    config = load_config()

    if args.search:
        token = access_token(config)
        products = search_mpn(args.search, config, token, record_count=5)
        print(json.dumps(products, indent=2, ensure_ascii=False)[:6000])
        return

    if not args.csv:
        raise SystemExit("Specifica --csv o --search")

    items = load_inventory(args.csv)
    print(f"Componenti con MPN: {len(items)}")
    ok, skipped, errors = enrich_inventory(
        items, config, args.json_dir, args.delay, force=args.force
    )
    print(f"\nFatto: {ok} aggiornati, {skipped} saltati, {errors} errori → {args.json_dir}")


if __name__ == "__main__":
    main()
