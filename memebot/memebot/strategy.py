"""Exit rules: cut losers fast, take the stake back at 2x, let a moonbag ride with a trailing stop."""

from __future__ import annotations

from dataclasses import dataclass

from memebot.config import Config
from memebot.portfolio import Position


@dataclass
class Sell:
    qty: float
    reason: str


def exit_orders(pos: Position, price: float, liquidity: float, now: float, cfg: Config) -> list[Sell]:
    """Decide what to sell this cycle. Mutates pos.tp_hits / pos.peak_price."""
    pos.peak_price = max(pos.peak_price, price)
    mult = pos.multiple(price)

    # 1. Liquidity pulled -> rug. Get out of everything.
    if pos.entry_liquidity > 0 and liquidity < pos.entry_liquidity * (1 - cfg.rug_liquidity_drop_pct / 100):
        return [Sell(pos.remaining, f"liquidity dropped to ${liquidity:,.0f}")]

    # 2. Hard stop loss, only before the first take-profit (after that the trailing stop rules).
    if not pos.tp_hits and mult <= 1 - cfg.stop_loss_pct / 100:
        return [Sell(pos.remaining, f"stop loss ({mult:.2f}x)")]

    orders: list[Sell] = []
    left = pos.remaining

    # 3. Take-profit ladder (fractions are of the ORIGINAL position size).
    for i, (target, frac) in enumerate(cfg.take_profits):
        if i in pos.tp_hits or mult < target:
            continue
        pos.tp_hits.append(i)
        qty = min(pos.qty * frac, left)
        if qty > 0:
            orders.append(Sell(qty, f"take profit {target:g}x"))
            left -= qty

    # 4. Trailing stop on whatever is left once we've locked in profit.
    if pos.tp_hits and left > 0 and price <= pos.peak_price * (1 - cfg.trailing_stop_pct / 100):
        orders.append(Sell(left, f"trailing stop ({mult:.2f}x, peak {pos.multiple(pos.peak_price):.2f}x)"))
        return orders

    # 5. Dead money: no take-profit after a while and not moving.
    age_min = (now - pos.opened_at) / 60
    if not pos.tp_hits and age_min >= cfg.stale_minutes and mult < cfg.stale_min_multiple:
        orders.append(Sell(left, f"stale after {age_min:.0f}m ({mult:.2f}x)"))

    return orders
