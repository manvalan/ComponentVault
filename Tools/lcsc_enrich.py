#!/usr/bin/env python3
"""
Arricchisce l'inventario componenti scaricando i dati da LCSC.

Uso:
  python3 lcsc_enrich.py --csv "/Users/michelebigi/LCSC/Componenti Elettronici.csv"
  python3 lcsc_enrich.py --csv inventario.csv --html-dir dump_html --json-dir json_full_data

Output:
  - json_full_data/{LCSC}.json  (scheda completa, formato ComponentRecord)
  - bom_riepilogo.csv           (CSV normalizzato)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import time
from pathlib import Path

import requests
from bs4 import BeautifulSoup

BASE_DIR = Path("/Users/michelebigi/LCSC")


def extract_script(html: str, *, script_type: str | None = None, script_id: str | None = None) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    if script_type:
        tag = soup.find("script", type=script_type)
    elif script_id:
        tag = soup.find("script", id=script_id)
    else:
        return {}
    return json.loads(tag.string) if tag and tag.string else {}


def infer_value(parameters: dict[str, str], category: str) -> str:
    for key in ("Resistance", "Capacitance", "Inductance", "Voltage - Rated", "Voltage - Supply"):
        value = parameters.get(key)
        if value and value != "-":
            return value
    return "N/A"


def parse_lcsc_html(html: str, lcsc_code: str) -> dict:
    ld = extract_script(html, script_type="application/ld+json")
    nd = extract_script(html, script_id="__NEXT_DATA__")
    web = nd.get("props", {}).get("pageProps", {}).get("webData", {})

    parameters = {p["name"]: p["value"] for p in ld.get("additionalProperty", [])}
    offers = ld.get("offers", {})
    subject = ld.get("subjectOf", {})

    return {
        "lcscCode": ld.get("sku", lcsc_code),
        "mpn": ld.get("mpn", ""),
        "name": ld.get("name", ""),
        "description": ld.get("description", ""),
        "footprint": web.get("encapStandard") or parameters.get("Package", ""),
        "category": ld.get("category", web.get("catalogName", "")),
        "value": infer_value(parameters, ld.get("category", "")),
        "brand": (ld.get("brand") or {}).get("name", ""),
        "datasheetURL": subject.get("url"),
        "imageURLs": ld.get("image", []),
        "price": offers.get("price"),
        "currency": offers.get("priceCurrency"),
        "supplierStock": offers.get("inventoryLevel"),
        "dataSource": "lcsc",
        "parameters": parameters,
    }


def load_inventory(csv_path: Path) -> list[dict]:
    with csv_path.open(encoding="utf-8") as f:
        reader = csv.reader(f, delimiter=";")
        rows = list(reader)
    if not rows:
        return []

    header = [h.lower() for h in rows[0]]
    idx = {name: header.index(name) for name in header if name}

    def col(*candidates: str) -> int | None:
        for c in candidates:
            for key, i in idx.items():
                if c in key:
                    return i
        return None

    lcsc_i = col("codice", "lcsc") or 0
    mpn_i = col("mpn")
    desc_i = col("descrizione")
    fp_i = col("footprint")
    qty_i = col("quantità", "quantita", "qty")

    items = []
    for row in rows[1:]:
        if len(row) <= lcsc_i:
            continue
        lcsc = row[lcsc_i].strip()
        if not lcsc.startswith("C"):
            continue
        items.append({
            "lcscCode": lcsc,
            "mpn": row[mpn_i].strip() if mpn_i is not None and mpn_i < len(row) else "",
            "description": row[desc_i].strip() if desc_i is not None and desc_i < len(row) else "",
            "footprint": row[fp_i].strip() if fp_i is not None and fp_i < len(row) else "",
            "quantity": int(row[qty_i].strip() or 0) if qty_i is not None and qty_i < len(row) else 0,
        })
    return items


def fetch_lcsc(lcsc_code: str, html_dir: Path, delay: float) -> dict:
    html_file = html_dir / f"{lcsc_code}.html"
    if html_file.exists():
        html = html_file.read_text(encoding="utf-8")
        return parse_lcsc_html(html, lcsc_code)

    url = f"https://www.lcsc.com/product-detail/{lcsc_code}.html"
    headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
    response = requests.get(url, headers=headers, timeout=20)
    response.raise_for_status()
    html_dir.mkdir(parents=True, exist_ok=True)
    html_file.write_text(response.text, encoding="utf-8")
    time.sleep(delay)
    return parse_lcsc_html(response.text, lcsc_code)


def main() -> None:
    parser = argparse.ArgumentParser(description="Arricchisce inventario componenti da LCSC")
    parser.add_argument("--csv", type=Path, default=BASE_DIR / "Componenti Elettronici.csv")
    parser.add_argument("--html-dir", type=Path, default=BASE_DIR / "dump_html")
    parser.add_argument("--json-dir", type=Path, default=BASE_DIR / "json_full_data")
    parser.add_argument("--bom-out", type=Path, default=BASE_DIR / "bom_riepilogo.csv")
    parser.add_argument("--delay", type=float, default=0.8, help="Secondi tra richieste HTTP")
    parser.add_argument("--limit", type=int, default=0, help="Limita il numero di componenti (0 = tutti)")
    args = parser.parse_args()

    inventory = load_inventory(args.csv)
    if args.limit:
        inventory = inventory[: args.limit]

    args.json_dir.mkdir(parents=True, exist_ok=True)
    bom_rows = []

    print(f"Elaborazione di {len(inventory)} componenti…")
    for i, item in enumerate(inventory, 1):
        lcsc = item["lcscCode"]
        try:
            record = fetch_lcsc(lcsc, args.html_dir, args.delay)
            record["quantity"] = item["quantity"]
            if not record["mpn"]:
                record["mpn"] = item["mpn"]
            if not record["description"]:
                record["description"] = item["description"]
            if not record["footprint"]:
                record["footprint"] = item["footprint"]

            out_file = args.json_dir / f"{lcsc}.json"
            out_file.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")

            bom_rows.append([
                lcsc,
                record["mpn"],
                record["category"],
                record["value"],
                record["footprint"],
                record["description"],
                item["quantity"],
            ])
            print(f"[{i}/{len(inventory)}] OK {lcsc} {record['mpn']}")
        except Exception as exc:
            print(f"[{i}/{len(inventory)}] ERRORE {lcsc}: {exc}")

    with args.bom_out.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter=";")
        writer.writerow(["LCSC", "MPN", "Tipo", "Valore", "Footprint", "Descrizione", "Qty"])
        writer.writerows(bom_rows)

    print(f"\nCompletato: {len(bom_rows)} JSON in {args.json_dir}")
    print(f"CSV riepilogo: {args.bom_out}")


if __name__ == "__main__":
    main()
