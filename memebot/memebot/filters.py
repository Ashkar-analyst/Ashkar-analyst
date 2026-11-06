"""Entry filters. Each returns None if the token passes, or a short reason it doesn't."""

from __future__ import annotations

from typing import Any

from memebot.config import Config
from memebot.data import Market


def market_reason(m: Market, cfg: Config, now: float) -> str | None:
    age = m.age_minutes(now)
    if age is None:
        return "unknown age"
    if age < cfg.min_age_minutes:
        return f"too young ({age:.0f}m)"
    if age > cfg.max_age_minutes:
        return f"too old ({age:.0f}m)"
    if m.liquidity_usd < cfg.min_liquidity_usd:
        return f"low liquidity (${m.liquidity_usd:,.0f})"
    if m.market_cap_usd < cfg.min_market_cap_usd:
        return f"mcap too small (${m.market_cap_usd:,.0f})"
    if m.market_cap_usd > cfg.max_market_cap_usd:
        return f"mcap too big (${m.market_cap_usd:,.0f})"
    if m.volume_h1 < cfg.min_volume_h1_usd:
        return f"low 1h volume (${m.volume_h1:,.0f})"
    if m.buys_h1 < cfg.min_buys_h1:
        return f"few buyers ({m.buys_h1} buys/1h)"
    if m.buys_h1 < cfg.min_buy_sell_ratio_h1 * max(m.sells_h1, 1):
        return f"sell pressure ({m.buys_h1} buys / {m.sells_h1} sells)"
    if m.price_change_h1 > cfg.max_price_change_h1_pct:
        return f"already vertical (+{m.price_change_h1:.0f}% 1h)"
    return None


def safety_reason(report: dict[str, Any] | None, cfg: Config) -> str | None:
    if report is None:
        return "no rugcheck report" if cfg.require_rugcheck else None
    if cfg.reject_danger_risks:
        for risk in report.get("risks") or []:
            if str(risk.get("level", "")).lower() == "danger":
                return f"rugcheck danger: {risk.get('name', 'unknown')}"
    score = report.get("score_normalised")
    if isinstance(score, (int, float)) and score > cfg.max_rugcheck_score:
        return f"rugcheck score {score:.0f} > {cfg.max_rugcheck_score:.0f}"
    return None
