#!/usr/bin/env python3
"""
Ricerca live nel catalogo LCSC per keyword o MPN.

Uso:
  pip3 install requests gmssl
  python3 lcsc_catalog_search.py --keyword "FRC0805F1002TS"
  python3 lcsc_catalog_search.py --keyword "10k 0805 resistor" --limit 5

Output JSON array su stdout.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys

import requests

MAIN_URL = "https://www.lcsc.com/"
SEARCH_URL = "https://wmsc.lcsc.com/ftps/wm/search/v3/global"


def search_keyword(keyword: str, limit: int = 5) -> list[dict]:
    try:
        from gmssl.sm2 import CryptSM2
    except ImportError as exc:
        raise RuntimeError("Installa gmssl: pip3 install gmssl requests") from exc

    session = requests.Session()
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "Accept-Language": "it-IT,it;q=0.9,en;q=0.8",
    })

    home = session.get(MAIN_URL, timeout=30)
    home.raise_for_status()

    match = re.search(r'encryptPublicHexKey:"([a-f0-9]+)"', home.text)
    if not match:
        raise RuntimeError("Chiave pubblica LCSC non trovata")

    public_key = match.group(1)[2:]
    sm2 = CryptSM2(None, public_key, mode=1)
    encrypted = sm2.encrypt(base64.b64encode(keyword.encode("utf-8")))
    payload = {"keyword": f"{{secret}}04{encrypted.hex()}"}

    response = session.post(SEARCH_URL, json=payload, timeout=30)
    response.raise_for_status()
    body = response.json()

    result = body.get("result") or {}
    search_block = result.get("productSearchResultVO") or result
    products = search_block.get("productList") or []

    output: list[dict] = []
    for product in products[:limit]:
        code = product.get("productCode") or ""
        if not code:
            continue
        output.append({
            "lcscCode": code,
            "mpn": product.get("productModel") or "",
            "name": product.get("productNameEn") or product.get("productModel") or "",
            "description": product.get("productIntroEn") or product.get("productDescEn") or "",
            "footprint": product.get("encapStandard") or "",
            "brand": product.get("brandNameEn") or "",
            "category": product.get("catalogName") or product.get("parentCatalogName") or "",
            "price": first_price(product),
            "currency": "USD",
            "supplierStock": product.get("stockNumber"),
            "productURL": f"https://www.lcsc.com/product-detail/{code}.html",
        })

    return output


def first_price(product: dict) -> float | None:
    price_list = product.get("productPriceList") or []
    if price_list:
        value = price_list[0].get("usdPrice") or price_list[0].get("currencyPrice")
        return float(value) if value else None
    ladder = product.get("productLadderPrice") or ""
    if ladder:
        first = ladder.split(",")[0]
        parts = first.split("~")
        if len(parts) >= 3:
            try:
                return float(parts[2])
            except ValueError:
                return None
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Ricerca catalogo LCSC")
    parser.add_argument("--keyword", help="MPN o keyword di ricerca")
    parser.add_argument("--mpn", help="Alias di --keyword per ricerca da MPN")
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()
    keyword = (args.mpn or args.keyword or "").strip()
    if not keyword:
        parser.error("Specifica --keyword o --mpn")

    try:
        results = search_keyword(keyword, limit=max(1, min(args.limit, 15)))
        print(json.dumps(results, ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stdout)
        sys.exit(1)


if __name__ == "__main__":
    main()
