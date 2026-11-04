"""Main loop: discover tokens, refresh prices, manage exits, take new entries."""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Callable

from memebot.config import Config
from memebot.data import DexScreener, Market, RugCheck
from memebot.filters import market_reason, safety_reason
from memebot.portfolio import PaperBroker, Portfolio, TradeLog
from memebot.strategy import exit_orders

log = logging.getLogger("memebot")

KEEP_WATCH_DAYS = 7  # keep skipped-token history this long for the "missed" report


class Bot:
    def __init__(self, cfg: Config, dex: DexScreener | None = None, rug: RugCheck | None = None,
                 clock: Callable[[], float] = time.time):
        self.cfg = cfg
        self.dex = dex or DexScreener()
        self.rug = rug or RugCheck()
        self.clock = clock
        self.dir = Path(cfg.data_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.state_path = self.dir / "state.json"
        self.portfolio, self.watch = self._load()
        self.broker = PaperBroker(cfg, self.portfolio, TradeLog(self.dir / "trades.csv"))
        self.no_new_buys_after: float | None = None  # set by run(hours=...)

    # ---------- persistence ----------
    def _load(self) -> tuple[Portfolio, dict[str, dict]]:
        if self.state_path.exists():
            d = json.loads(self.state_path.read_text())
            return Portfolio.from_dict(d["portfolio"]), d.get("watch", {})
        return Portfolio(cash=self.cfg.starting_balance_usd), {}

    def save(self) -> None:
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"portfolio": self.portfolio.to_dict(), "watch": self.watch}, indent=1))
        tmp.replace(self.state_path)

    # ---------- one cycle ----------
    def cycle(self) -> None:
        now = self.clock()
        for addr in self.dex.latest_tokens():
            if addr not in self.watch:
                self.watch[addr] = {"first_seen": now, "status": "watching", "reason": "new",
                                    "symbol": "?", "first_price": None, "peak_price": None, "url": ""}

        markets = self.dex.markets(self._addresses_to_refresh(now))
        self._update_watch(markets)
        self._manage_positions(markets, now)
        self._find_entries(markets, now)
        self._prune(now)
        self.save()

        pf = self.portfolio
        log.info("equity $%.2f | cash $%.2f | open %d | watching %d",
                 pf.equity(), pf.cash, len(pf.positions),
                 sum(1 for w in self.watch.values() if w["status"] == "watching"))

    def _addresses_to_refresh(self, now: float) -> list[str]:
        held = list(self.portfolio.positions)
        cutoff = now - self.cfg.track_hours * 3600
        recent = sorted(
            (a for a, w in self.watch.items() if w["first_seen"] >= cutoff and a not in self.portfolio.positions),
            key=lambda a: self.watch[a]["first_seen"], reverse=True,
        )
        return held + recent[: max(0, self.cfg.max_tracked_tokens - len(held))]

    def _update_watch(self, markets: dict[str, Market]) -> None:
        for addr, m in markets.items():
            w = self.watch.get(addr)
            if w is None:
                continue
            w["symbol"], w["url"] = m.symbol, m.url
            if w["first_price"] is None:
                w["first_price"] = m.price_usd
            w["peak_price"] = max(w["peak_price"] or 0, m.price_usd)

    def _manage_positions(self, markets: dict[str, Market], now: float) -> None:
        for pos in list(self.portfolio.positions.values()):
            m = markets.get(pos.address)
            if m is None:
                pos.missing_cycles += 1
                if pos.missing_cycles >= self.cfg.missing_data_cycles:
                    log.warning("%s: no market data for %d cycles, writing off", pos.symbol, pos.missing_cycles)
                    self.broker.sell(pos, pos.remaining, 0.0, "no market data (assumed rug)")
                continue
            pos.missing_cycles = 0
            pos.last_price = m.price_usd
            for order in exit_orders(pos, m.price_usd, m.liquidity_usd, now, self.cfg):
                usd = self.broker.sell(pos, order.qty, m.price_usd, order.reason)
                log.info("SELL %s %s -> $%.2f (%s)", pos.symbol, f"{pos.multiple(m.price_usd):.2f}x", usd, order.reason)

    def _find_entries(self, markets: dict[str, Market], now: float) -> None:
        if self.no_new_buys_after is not None and now >= self.no_new_buys_after:
            return  # winding down before session end
        for addr, w in self.watch.items():
            if w["status"] != "watching" or addr in self.portfolio.positions:
                continue
            m = markets.get(addr)
            if m is None:
                continue
            reason = market_reason(m, self.cfg, now)
            if reason:
                w["reason"] = reason
                if reason.startswith("too old"):
                    w["status"] = "rejected"
                continue
            if len(self.portfolio.positions) >= self.cfg.max_open_positions:
                w["reason"] = "passed filters, but max positions open"
                continue
            if self.portfolio.cash < self.cfg.position_size_usd:
                w["reason"] = "passed filters, but out of cash"
                continue

            report = self.rug.summary(addr)
            if report is None and self.cfg.require_rugcheck:
                w["reason"] = "rugcheck unavailable, will retry"
                continue
            unsafe = safety_reason(report, self.cfg)
            if unsafe:
                w["status"], w["reason"] = "rejected", unsafe
                log.info("skip %s: %s", m.symbol, unsafe)
                continue

            if self.broker.buy(addr, m.symbol, m.price_usd, m.liquidity_usd, m.url, now):
                w["status"], w["reason"] = "bought", "bought"
                log.info(f"BUY {m.symbol} @ ${m.price_usd:.10g} | mcap ${m.market_cap_usd:,.0f} "
                         f"| liq ${m.liquidity_usd:,.0f} | {m.url}")

    def _prune(self, now: float) -> None:
        cutoff = now - KEEP_WATCH_DAYS * 86400
        for addr in [a for a, w in self.watch.items() if w["first_seen"] < cutoff]:
            if addr not in self.portfolio.positions:
                del self.watch[addr]

    def close_session(self, reason: str = "session end") -> None:
        """Sell open positions so nothing sits unmanaged while the bot is off.

        Positions that already hit a take-profit (stake recovered) are kept if
        keep_moonbags_overnight is on; the next session picks them up again.
        """
        to_close = [p for p in self.portfolio.positions.values()
                    if not (self.cfg.keep_moonbags_overnight and p.tp_hits)]
        if to_close:
            markets = self.dex.markets([p.address for p in to_close])
            for pos in to_close:
                m = markets.get(pos.address)
                if m is None:
                    log.warning("%s: no price available, left open", pos.symbol)
                    continue
                usd = self.broker.sell(pos, pos.remaining, m.price_usd, reason)
                log.info("SELL %s %.2fx -> $%.2f (%s)", pos.symbol, pos.multiple(m.price_usd), usd, reason)
        kept = len(self.portfolio.positions)
        self.save()
        log.info("Session closed. Equity $%.2f. %d moonbag(s) kept for next session.",
                 self.portfolio.equity(), kept)

    # ---------- main loop ----------
    def run(self, hours: float | None = None) -> None:
        end = time.time() + hours * 3600 if hours else None
        if end:
            self.no_new_buys_after = end - self.cfg.wind_down_minutes * 60
            log.info("Session: %.1f h. New buys stop %.0f min before the end; then positions close.",
                     hours, self.cfg.wind_down_minutes)
        log.info("Paper trading. Equity $%.2f, $%.2f per trade. Ctrl+C to stop early.",
                 self.portfolio.equity(), self.cfg.position_size_usd)
        try:
            while end is None or time.time() < end:
                started = time.time()
                try:
                    self.cycle()
                except Exception:  # keep the bot alive through API hiccups
                    log.exception("cycle failed")
                time.sleep(max(1.0, self.cfg.poll_seconds - (time.time() - started)))
        except KeyboardInterrupt:
            log.info("Stopping early...")
        self.close_session()
