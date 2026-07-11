#!/usr/bin/env python3
"""
Carica l'inventario locale (json_full_data) sul server ComponentVault.

Uso:
  python3 push_inventory.py \\
    --api https://api.michelebigi.it \\
    --key TUA_API_KEY \\
    --dir /Users/michelebigi/LCSC/json_full_data
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import requests


def load_component(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        "lcscCode": data.get("lcscCode", path.stem),
        "mpn": data.get("mpn", ""),
        "name": data.get("name", ""),
        "description": data.get("description", ""),
        "footprint": data.get("footprint", ""),
        "quantity": int(data.get("quantity", 0) or 0),
        "category": data.get("category", ""),
        "value": data.get("value", ""),
        "brand": data.get("brand", ""),
        "datasheetURL": data.get("datasheetURL"),
        "imageURLs": data.get("imageURLs", []),
        "price": data.get("price"),
        "currency": data.get("currency"),
        "supplierStock": data.get("supplierStock"),
        "dataSource": data.get("dataSource", "lcsc"),
        "parameters": data.get("parameters", {}),
        "notes": data.get("notes", ""),
        "minQuantity": int(data.get("minQuantity", 0) or 0),
        "tags": data.get("tags", []),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Push inventario ComponentVault")
    parser.add_argument("--api", required=True, help="Base URL API, es. https://api.michelebigi.it")
    parser.add_argument("--key", required=True, help="API key")
    parser.add_argument("--dir", default="/Users/michelebigi/LCSC/json_full_data")
    args = parser.parse_args()

    base = args.api.rstrip("/")
    headers = {"X-API-Key": args.key, "Content-Type": "application/json"}

    health = requests.get(f"{base}/health", timeout=20)
    health.raise_for_status()
    print("Server:", health.json())

    json_dir = Path(args.dir)
    files = sorted(json_dir.glob("C*.json"))
    if not files:
        raise SystemExit(f"Nessun JSON in {json_dir}")

    components = [load_component(p) for p in files]
    response = requests.post(
        f"{base}/sync/push",
        headers=headers,
        json={"components": components},
        timeout=120,
    )
    response.raise_for_status()
    print(f"Caricati {response.json()['upserted']} componenti")


if __name__ == "__main__":
    main()
