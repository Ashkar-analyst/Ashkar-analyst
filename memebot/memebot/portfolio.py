"""Paper portfolio: simulated fills, positions, and the trade log."""

from __future__ import annotations

import csv
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from memebot.config import Config


@dataclass
class Position:
    address: str
    symbol: str
    opened_at: float
    entry_price: float       # effective price paid per token, incl. slippage
    qty: float               # tokens bought
    remaining: float         # tokens still held
    cost_usd: float          # USD spent incl. fee
    entry_liquidity: float
    peak_price: float
    url: str = ""
    proceeds_usd: float = 0.0  # USD received from sells so far
    tp_hits: list[int] = field(default_factory=list)
    missing_cycles: int = 0
    last_price: float = 0.0

    def multiple(self, price: float) -> float:
        return price / self.entry_price if self.entry_price > 0 else 0.0

    def value(self, price: float | None = None) -> float:
        return self.remaining * (self.last_price if price is None else price)


@dataclass
class Portfolio:
    cash: float
    positions: dict[str, Position] = field(default_factory=dict)
    closed: list[dict] = field(default_factory=list)  # summaries of fully closed positions

    @classmethod
    def from_dict(cls, d: dict) -> "Portfolio":
        return cls(
            cash=d["cash"],
            positions={k: Position(**v) for k, v in d.get("positions", {}).items()},
            closed=d.get("closed", []),
        )

    def to_dict(self) -> dict:
        return {
            "cash": self.cash,
            "positions": {k: asdict(v) for k, v in self.positions.items()},
            "closed": self.closed,
        }

    def equity(self) -> float:
        return self.cash + sum(p.value() for p in self.positions.values())


class TradeLog:
    COLUMNS = ["time_utc", "side", "symbol", "address", "price_usd", "qty", "usd", "multiple", "reason", "url"]

    def __init__(self, path: Path):
        self.path = path

    def write(self, **row) -> None:
        new = not self.path.exists()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=self.COLUMNS)
            if new:
                w.writeheader()
            row["time_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            w.writerow({k: row.get(k, "") for k in self.COLUMNS})


class PaperBroker:
    """Simulates buys/sells against the latest quoted price with slippage and fees."""

    def __init__(self, cfg: Config, portfolio: Portfolio, log: TradeLog):
        self.cfg = cfg
        self.pf = portfolio
        self.log = log

    def buy(self, address: str, symbol: str, price: float, liquidity: float, url: str, now: float) -> Position | None:
        size = self.cfg.position_size_usd
        if self.pf.cash < size or size <= self.cfg.fee_usd_per_trade:
            return None
        fill = price * (1 + self.cfg.slippage_pct / 100)
        qty = (size - self.cfg.fee_usd_per_trade) / fill
        self.pf.cash -= size
        pos = Position(
            address=address, symbol=symbol, opened_at=now, entry_price=fill, qty=qty,
            remaining=qty, cost_usd=size, entry_liquidity=liquidity, peak_price=price,
            url=url, last_price=price,
        )
        self.pf.positions[address] = pos
        self.log.write(side="BUY", symbol=symbol, address=address, price_usd=f"{fill:.10g}",
                       qty=f"{qty:.6g}", usd=f"{size:.2f}", multiple="1.00", reason="entry", url=url)
        return pos

    def sell(self, pos: Position, qty: float, price: float, reason: str) -> float:
        qty = min(qty, pos.remaining)
        if qty <= 0:
            return 0.0
        fill = price * (1 - self.cfg.slippage_pct / 100)
        usd = max(0.0, qty * fill - self.cfg.fee_usd_per_trade)
        pos.remaining -= qty
        pos.proceeds_usd += usd
        self.pf.cash += usd
        self.log.write(side="SELL", symbol=pos.symbol, address=pos.address, price_usd=f"{fill:.10g}",
                       qty=f"{qty:.6g}", usd=f"{usd:.2f}", multiple=f"{pos.multiple(price):.2f}",
                       reason=reason, url=pos.url)
        if pos.remaining <= pos.qty * 1e-9:
            self.pf.positions.pop(pos.address, None)
            self.pf.closed.append({
                "symbol": pos.symbol, "address": pos.address, "opened_at": pos.opened_at,
                "cost_usd": pos.cost_usd, "proceeds_usd": pos.proceeds_usd,
                "pnl_usd": pos.proceeds_usd - pos.cost_usd,
                "peak_multiple": pos.multiple(pos.peak_price), "exit_reason": reason,
            })
        return usd
