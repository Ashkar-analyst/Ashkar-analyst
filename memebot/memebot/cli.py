"""Command line: python -m memebot run | report | reset"""

from __future__ import annotations

import argparse
import logging
import shutil
import sys
import time
from pathlib import Path

from memebot.bot import Bot
from memebot.config import Config


def setup_logging(data_dir: str) -> None:
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%H:%M:%S")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    for handler in (logging.StreamHandler(sys.stdout), logging.FileHandler(Path(data_dir) / "bot.log")):
        handler.setFormatter(fmt)
        root.addHandler(handler)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def report(bot: Bot, missed_min_multiple: float) -> None:
    pf, cfg = bot.portfolio, bot.cfg
    equity = pf.equity()
    start = cfg.starting_balance_usd
    print(f"\n=== Paper account ===\nEquity ${equity:,.2f}  (start ${start:,.2f}, "
          f"{(equity / start - 1) * 100:+.1f}%)   cash ${pf.cash:,.2f}")

    closed = pf.closed
    if closed:
        wins = [c for c in closed if c["pnl_usd"] > 0]
        realized = sum(c["pnl_usd"] for c in closed)
        best = max(closed, key=lambda c: c["peak_multiple"])
        print(f"Closed {len(closed)} | win rate {len(wins) / len(closed) * 100:.0f}% | "
              f"realized P&L ${realized:+,.2f} | best peak {best['symbol']} {best['peak_multiple']:.1f}x")

    if pf.positions:
        print("\n=== Open positions ===")
        print(f"{'symbol':<12}{'now':>8}{'peak':>8}{'value $':>10}{'taken $':>10}  age")
        for p in sorted(pf.positions.values(), key=lambda p: -p.multiple(p.last_price)):
            age = (time.time() - p.opened_at) / 60
            print(f"{p.symbol[:11]:<12}{p.multiple(p.last_price):>7.2f}x{p.multiple(p.peak_price):>7.1f}x"
                  f"{p.value():>10.2f}{p.proceeds_usd:>10.2f}  {age:.0f}m")

    missed = []
    for w in bot.watch.values():
        if w["status"] != "bought" and w["first_price"] and w["peak_price"]:
            mult = w["peak_price"] / w["first_price"]
            if mult >= missed_min_multiple:
                missed.append((mult, w))
    print(f"\n=== Skipped tokens that later went {missed_min_multiple:g}x+ (from when the bot first saw them) ===")
    if not missed:
        print("none yet")
    for mult, w in sorted(missed, key=lambda x: -x[0])[:25]:
        print(f"{w['symbol'][:11]:<12}{mult:>7.1f}x  skipped because: {w['reason']}  {w['url']}")
    print()


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="memebot", description="Solana memecoin paper-trading bot")
    ap.add_argument("command", choices=["run", "report", "close", "reset"])
    ap.add_argument("--hours", type=float, help="run: session length; stops buying near the end, then closes positions")
    ap.add_argument("--config", default="config.toml")
    ap.add_argument("--missed", type=float, default=5.0, help="report: show skipped tokens that ran at least this multiple")
    args = ap.parse_args(argv)

    cfg = Config.load(args.config)
    if args.command == "reset":
        if input(f"Delete all paper-trading data in '{cfg.data_dir}/'? [y/N] ").strip().lower() == "y":
            shutil.rmtree(cfg.data_dir, ignore_errors=True)
            print("Reset.")
        return
    if args.command == "report":
        report(Bot(cfg), args.missed)
        return

    setup_logging(cfg.data_dir)
    if args.command == "close":
        Bot(cfg).close_session("manual close")
        return
    Bot(cfg).run(args.hours)
    print("Stopped. Run `python -m memebot report` to see results.")
