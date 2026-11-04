"""Bot settings. Defaults live here; override any of them in config.toml."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field, fields
from pathlib import Path


@dataclass
class Config:
    # --- loop ---
    poll_seconds: int = 20             # how often to refresh market data
    data_dir: str = "data"             # where state, trade log and bot log are written

    # --- paper account ---
    starting_balance_usd: float = 1000.0
    position_size_usd: float = 20.0    # small fixed bet per token ("lottery ticket")
    max_open_positions: int = 15
    slippage_pct: float = 3.0          # simulated slippage on every buy and sell
    fee_usd_per_trade: float = 0.05    # simulated network + priority fee

    # --- entry filters (market data) ---
    min_age_minutes: float = 3         # skip the first minutes, when most instant rugs happen
    max_age_minutes: float = 360       # older than this = no longer "early", stop watching
    min_liquidity_usd: float = 8_000
    min_market_cap_usd: float = 10_000
    max_market_cap_usd: float = 500_000  # 200x from $500k is a $100M coin; keep entries early
    min_volume_h1_usd: float = 10_000
    min_buys_h1: int = 50
    min_buy_sell_ratio_h1: float = 1.1  # more buys than sells over the last hour
    max_price_change_h1_pct: float = 400  # don't buy the top of a vertical candle

    # --- entry filters (RugCheck safety report) ---
    require_rugcheck: bool = True      # no report = no buy
    reject_danger_risks: bool = True   # any "danger"-level risk (mint/freeze authority, etc.) = reject
    max_rugcheck_score: float = 50     # score_normalised from RugCheck; higher = riskier

    # --- exits ---
    stop_loss_pct: float = 50          # before any take-profit: sell all at -50%
    # [multiple, fraction of the ORIGINAL position to sell]. 2x sells half = stake back.
    take_profits: list[list[float]] = field(
        default_factory=lambda: [[2.0, 0.5], [5.0, 0.15], [20.0, 0.1], [100.0, 0.1]]
    )  # what's left (15% here) is the moonbag that can ride to 200x+
    trailing_stop_pct: float = 45      # after the first take-profit: sell rest if price falls this far from its peak
    stale_minutes: float = 90          # no take-profit yet after this long and...
    stale_min_multiple: float = 1.3    # ...below this multiple = dead money, exit
    rug_liquidity_drop_pct: float = 70  # liquidity fell this much since entry = treat as rug, exit
    missing_data_cycles: int = 15      # token vanished from the API this many cycles in a row = written off

    # --- watchlist / missed-opportunity tracking ---
    track_hours: float = 24            # keep tracking skipped tokens this long to see if they pumped
    max_tracked_tokens: int = 600      # cap on tokens refreshed each cycle (API rate limits)

    @classmethod
    def load(cls, path: str | Path = "config.toml") -> "Config":
        cfg = cls()
        p = Path(path)
        if p.exists():
            with p.open("rb") as fh:
                overrides = tomllib.load(fh)
            known = {f.name for f in fields(cls)}
            unknown = set(overrides) - known
            if unknown:
                raise ValueError(f"Unknown settings in {p}: {', '.join(sorted(unknown))}")
            for key, value in overrides.items():
                setattr(cfg, key, value)
        cfg.take_profits = sorted(cfg.take_profits, key=lambda tp: tp[0])
        if sum(frac for _, frac in cfg.take_profits) > 1.0 + 1e-9:
            raise ValueError("take_profits fractions add up to more than 1.0")
        return cfg
