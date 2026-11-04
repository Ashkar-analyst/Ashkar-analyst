"""Offline tests: fake DexScreener/RugCheck feeds drive the real bot logic."""

from __future__ import annotations

import pytest

from memebot.bot import Bot
from memebot.config import Config
from memebot.data import Market, parse_pair
from memebot.filters import safety_reason
from memebot.portfolio import Position
from memebot.strategy import exit_orders

T0 = 1_700_000_000.0


def market(addr="TOKEN1", price=0.0001, liq=20_000, mcap=100_000, age_min=30, **kw) -> Market:
    base = dict(address=addr, symbol=addr[:4], name=addr, price_usd=price, liquidity_usd=liq,
                market_cap_usd=mcap, volume_m5=5_000, volume_h1=40_000, buys_m5=40, sells_m5=20,
                buys_h1=300, sells_h1=150, price_change_m5=5, price_change_h1=50,
                created_at=T0 - age_min * 60, dex_id="pumpswap", url=f"https://dexscreener.com/solana/{addr}")
    base.update(kw)
    return Market(**base)


class FakeDex:
    def __init__(self):
        self.new: list[str] = []
        self.data: dict[str, Market] = {}

    def latest_tokens(self):
        return self.new

    def markets(self, addresses):
        return {a: self.data[a] for a in addresses if a in self.data}


class FakeRug:
    def __init__(self, report=None):
        self.report = report if report is not None else {"risks": [], "score_normalised": 10}

    def summary(self, mint):
        return self.report


class Clock:
    def __init__(self):
        self.t = T0

    def __call__(self):
        return self.t


@pytest.fixture
def setup(tmp_path):
    cfg = Config(data_dir=str(tmp_path), slippage_pct=0, fee_usd_per_trade=0)
    dex, rug, clock = FakeDex(), FakeRug(), Clock()
    return cfg, dex, rug, clock, Bot(cfg, dex, rug, clock)


def test_parse_pair_dexscreener_shape():
    pair = {
        "chainId": "solana", "dexId": "pumpswap", "url": "https://dexscreener.com/solana/x",
        "baseToken": {"address": "MINT", "name": "Dog", "symbol": "DOG"},
        "priceUsd": "0.00012", "txns": {"m5": {"buys": 10, "sells": 3}, "h1": {"buys": 100, "sells": 40}},
        "volume": {"m5": 1000, "h1": 20000}, "priceChange": {"m5": 2.5, "h1": 30},
        "liquidity": {"usd": 15000}, "marketCap": 120000, "pairCreatedAt": 1_700_000_000_000,
    }
    m = parse_pair(pair)
    assert m.address == "MINT" and m.symbol == "DOG"
    assert m.price_usd == pytest.approx(0.00012)
    assert m.buys_h1 == 100 and m.liquidity_usd == 15000 and m.created_at == 1_700_000_000
    assert parse_pair({"baseToken": {"address": "X"}, "priceUsd": None}) is None


def test_buys_token_that_passes_filters(setup):
    cfg, dex, rug, clock, bot = setup
    dex.new = ["GOOD"]
    dex.data["GOOD"] = market("GOOD")
    bot.cycle()
    assert "GOOD" in bot.portfolio.positions
    assert bot.portfolio.cash == pytest.approx(cfg.starting_balance_usd - cfg.position_size_usd)


def test_rejects_rugcheck_danger_and_tracks_it_as_missed(setup):
    cfg, dex, rug, clock, bot = setup
    rug.report = {"risks": [{"name": "Freeze Authority still enabled", "level": "danger"}]}
    dex.new = ["RUG"]
    dex.data["RUG"] = market("RUG")
    bot.cycle()
    assert "RUG" not in bot.portfolio.positions
    assert bot.watch["RUG"]["status"] == "rejected"
    assert "Freeze Authority" in bot.watch["RUG"]["reason"]
    dex.data["RUG"] = market("RUG", price=0.001)  # it pumped 10x anyway
    bot.cycle()
    assert bot.watch["RUG"]["peak_price"] / bot.watch["RUG"]["first_price"] == pytest.approx(10)


def test_waits_for_young_token_then_buys(setup):
    cfg, dex, rug, clock, bot = setup
    dex.new = ["BABY"]
    dex.data["BABY"] = market("BABY", age_min=1)
    bot.cycle()
    assert "BABY" not in bot.portfolio.positions
    assert bot.watch["BABY"]["status"] == "watching"
    clock.t += 5 * 60
    bot.cycle()
    assert "BABY" in bot.portfolio.positions


def test_moonshot_lifecycle_takes_profits_and_trails(setup):
    cfg, dex, rug, clock, bot = setup
    dex.new = ["MOON"]
    dex.data["MOON"] = market("MOON", price=1.0)
    bot.cycle()
    pos = bot.portfolio.positions["MOON"]
    qty = pos.qty

    for price in (2.0, 5.0, 20.0, 100.0, 250.0):  # runs to 250x
        dex.data["MOON"] = market("MOON", price=price)
        bot.cycle()
    assert pos.tp_hits == [0, 1, 2, 3]
    assert pos.remaining == pytest.approx(qty * 0.15)

    dex.data["MOON"] = market("MOON", price=130.0)  # -48% from the 250x peak -> trailing stop
    bot.cycle()
    assert "MOON" not in bot.portfolio.positions
    closed = bot.portfolio.closed[-1]
    assert closed["peak_multiple"] == pytest.approx(250)
    expected = qty * (0.5 * 2 + 0.15 * 5 + 0.1 * 20 + 0.1 * 100 + 0.15 * 130)
    assert closed["proceeds_usd"] == pytest.approx(expected)


def test_stop_loss_and_rug_detection(setup):
    cfg, dex, rug, clock, bot = setup
    dex.new = ["DUD", "PULL"]
    dex.data["DUD"] = market("DUD", price=1.0)
    dex.data["PULL"] = market("PULL", price=1.0, liq=50_000)
    bot.cycle()
    assert set(bot.portfolio.positions) == {"DUD", "PULL"}
    dex.data["DUD"] = market("DUD", price=0.45)
    dex.data["PULL"] = market("PULL", price=1.1, liq=5_000)
    bot.cycle()
    reasons = {c["symbol"]: c["exit_reason"] for c in bot.portfolio.closed}
    assert reasons["DUD"].startswith("stop loss")
    assert reasons["PULL"].startswith("liquidity dropped")


def test_vanished_token_is_written_off(setup):
    cfg, dex, rug, clock, bot = setup
    dex.new = ["GONE"]
    dex.data["GONE"] = market("GONE")
    bot.cycle()
    del dex.data["GONE"]
    for _ in range(cfg.missing_data_cycles):
        bot.cycle()
    assert "GONE" not in bot.portfolio.positions
    assert bot.portfolio.closed[-1]["pnl_usd"] == pytest.approx(-cfg.position_size_usd)


def test_stale_position_exits(setup):
    cfg = Config(slippage_pct=0, fee_usd_per_trade=0)
    pos = Position("A", "A", T0, 1.0, 10, 10, 10, 10_000, 1.0)
    assert exit_orders(pos, 1.1, 10_000, T0 + 60 * 60, cfg) == []
    orders = exit_orders(pos, 1.1, 10_000, T0 + 91 * 60, cfg)
    assert orders and orders[0].reason.startswith("stale")


def test_state_survives_restart(setup):
    cfg, dex, rug, clock, bot = setup
    dex.new = ["KEEP"]
    dex.data["KEEP"] = market("KEEP")
    bot.cycle()
    again = Bot(cfg, dex, rug, clock)
    assert "KEEP" in again.portfolio.positions
    assert again.portfolio.cash == pytest.approx(bot.portfolio.cash)


def test_respects_max_positions(setup):
    cfg, dex, rug, clock, bot = setup
    cfg.max_open_positions = 2
    dex.new = ["A1", "A2", "A3"]
    for a in dex.new:
        dex.data[a] = market(a)
    bot.cycle()
    assert len(bot.portfolio.positions) == 2


def test_safety_reason_score_and_missing_report():
    cfg = Config()
    assert safety_reason({"risks": [], "score_normalised": 80}, cfg).startswith("rugcheck score")
    assert safety_reason(None, cfg) == "no rugcheck report"
    assert safety_reason({"risks": [{"name": "Low holders", "level": "warn"}], "score_normalised": 5}, cfg) is None


def test_config_file_overrides(tmp_path):
    p = tmp_path / "config.toml"
    p.write_text("position_size_usd = 5\ntake_profits = [[3.0, 0.4]]\n")
    cfg = Config.load(p)
    assert cfg.position_size_usd == 5 and cfg.take_profits == [[3.0, 0.4]]
    p.write_text("typo_setting = 1\n")
    with pytest.raises(ValueError):
        Config.load(p)
