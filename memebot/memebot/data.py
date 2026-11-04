"""Market data clients: DexScreener (prices, discovery) and RugCheck (token safety).

Both are free public APIs with no key. DexScreener allows ~60 req/min on the
discovery endpoints and ~300 req/min on the token endpoint.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any, Iterable

import requests

log = logging.getLogger(__name__)

DEXSCREENER = "https://api.dexscreener.com"
RUGCHECK = "https://api.rugcheck.xyz/v1"
CHAIN = "solana"
BATCH = 30  # DexScreener accepts up to 30 token addresses per request


def _f(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


@dataclass
class Market:
    """Snapshot of a token's most liquid trading pair."""

    address: str
    symbol: str
    name: str
    price_usd: float
    liquidity_usd: float
    market_cap_usd: float
    volume_m5: float
    volume_h1: float
    buys_m5: int
    sells_m5: int
    buys_h1: int
    sells_h1: int
    price_change_m5: float
    price_change_h1: float
    created_at: float | None  # epoch seconds
    dex_id: str
    url: str

    def age_minutes(self, now: float) -> float | None:
        if self.created_at is None:
            return None
        return max(0.0, (now - self.created_at) / 60)


def parse_pair(pair: dict[str, Any]) -> Market | None:
    base = pair.get("baseToken") or {}
    price = _f(pair.get("priceUsd"))
    if not base.get("address") or price <= 0:
        return None
    txns = pair.get("txns") or {}
    vol = pair.get("volume") or {}
    chg = pair.get("priceChange") or {}
    created_ms = pair.get("pairCreatedAt")
    return Market(
        address=base["address"],
        symbol=str(base.get("symbol") or "?"),
        name=str(base.get("name") or ""),
        price_usd=price,
        liquidity_usd=_f((pair.get("liquidity") or {}).get("usd")),
        market_cap_usd=_f(pair.get("marketCap"), _f(pair.get("fdv"))),
        volume_m5=_f(vol.get("m5")),
        volume_h1=_f(vol.get("h1")),
        buys_m5=int(_f((txns.get("m5") or {}).get("buys"))),
        sells_m5=int(_f((txns.get("m5") or {}).get("sells"))),
        buys_h1=int(_f((txns.get("h1") or {}).get("buys"))),
        sells_h1=int(_f((txns.get("h1") or {}).get("sells"))),
        price_change_m5=_f(chg.get("m5")),
        price_change_h1=_f(chg.get("h1")),
        created_at=_f(created_ms) / 1000 if created_ms else None,
        dex_id=str(pair.get("dexId") or ""),
        url=str(pair.get("url") or ""),
    )


class Http:
    def __init__(self, timeout: float = 15, retries: int = 3):
        self.session = requests.Session()
        self.session.headers["User-Agent"] = "memebot/0.1"
        self.timeout = timeout
        self.retries = retries

    def get_json(self, url: str) -> Any | None:
        delay = 2.0
        for attempt in range(1, self.retries + 1):
            try:
                resp = self.session.get(url, timeout=self.timeout)
                if resp.status_code == 429 or resp.status_code >= 500:
                    raise requests.HTTPError(f"HTTP {resp.status_code}")
                if resp.status_code != 200:
                    log.debug("GET %s -> HTTP %s", url, resp.status_code)
                    return None
                return resp.json()
            except (requests.RequestException, ValueError) as exc:
                if attempt == self.retries:
                    log.warning("GET %s failed: %s", url, exc)
                    return None
                time.sleep(delay)
                delay *= 2
        return None


class DexScreener:
    def __init__(self, http: Http | None = None):
        self.http = http or Http()

    def latest_tokens(self) -> list[str]:
        """Newly promoted Solana tokens (fresh profiles and boosts)."""
        found: list[str] = []
        for path in ("/token-profiles/latest/v1", "/token-boosts/latest/v1"):
            data = self.http.get_json(DEXSCREENER + path)
            if isinstance(data, dict):  # some endpoints wrap a single item
                data = [data]
            for item in data or []:
                if item.get("chainId") == CHAIN and item.get("tokenAddress"):
                    if item["tokenAddress"] not in found:
                        found.append(item["tokenAddress"])
        return found

    def markets(self, addresses: Iterable[str]) -> dict[str, Market]:
        """Best (most liquid) pair for each token address."""
        addrs = list(dict.fromkeys(addresses))
        best: dict[str, Market] = {}
        for i in range(0, len(addrs), BATCH):
            chunk = addrs[i : i + BATCH]
            data = self.http.get_json(f"{DEXSCREENER}/tokens/v1/{CHAIN}/{','.join(chunk)}")
            if isinstance(data, dict):
                data = data.get("pairs") or []
            for pair in data or []:
                m = parse_pair(pair)
                if m is None or m.address not in chunk:
                    continue
                if m.address not in best or m.liquidity_usd > best[m.address].liquidity_usd:
                    best[m.address] = m
        return best


class RugCheck:
    def __init__(self, http: Http | None = None):
        self.http = http or Http()

    def summary(self, mint: str) -> dict[str, Any] | None:
        data = self.http.get_json(f"{RUGCHECK}/tokens/{mint}/report/summary")
        return data if isinstance(data, dict) else None
