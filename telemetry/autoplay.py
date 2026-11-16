#!/usr/bin/env python3
"""Play one seeded Balatro run through the BalatroBot JSON-RPC API (https://coder.github.io/balatrobot/).

Not a good player: it only has to walk through every part of the game the telemetry covers
(skip, play, discard, cash out, buy joker/voucher/pack, reroll, sell, game over).
For the first --force-rounds rounds it uses BalatroBot's debug `set` to win the blind on the last
hand (chips) and to afford the shop (money), so those blinds report a forced score. After that
it plays on its own until game over.
Usage: autoplay.py [--seed SEED] [--deck RED] [--stake WHITE] [--force-rounds 4] [--max-rounds 12] [--port 12346]
"""

import argparse
import collections
import http.client
import itertools
import json
import os
import time
import urllib.error
import urllib.request

import bot_telemetry as telemetry

_request_ids = itertools.count(1)

RANKS = "23456789TJQKA"


class RPCError(Exception):
    def __init__(self, message, *, kind="transport_error", code=None):
        super().__init__(message)
        self.kind, self.code = kind, code


def rpc(port, method, **params):
    request_id = next(_request_ids)
    with telemetry.client_call(port, method, request_id) as (_, headers):
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": request_id}).encode()
        headers["Content-Type"] = "application/json"
        req = urllib.request.Request(f"http://127.0.0.1:{port}", body, headers)
        try:
            with urllib.request.urlopen(req, timeout=float(os.environ.get("RPC_TIMEOUT", "90"))) as resp:
                reply = json.load(resp)
        except ValueError as e:
            raise RPCError(f"{method}: invalid JSON response", kind="protocol_error") from e
        except (http.client.HTTPException, OSError) as e:
            # A timeout does not establish whether an action ran. Recovery re-reads state.
            raise RPCError(f"{method}: connection failed ({e!r})") from e
        if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0" or reply.get("id") != request_id:
            raise RPCError(f"{method}: invalid JSON-RPC response", kind="protocol_error")
        if "error" in reply:
            error = reply["error"]
            if not isinstance(error, dict) or type(error.get("code")) is not int:
                raise RPCError(f"{method}: invalid JSON-RPC error", kind="protocol_error")
            code = error["code"]
            raise RPCError(f"{method}: {error}", kind="jsonrpc_error", code=code)
        if "result" not in reply:
            raise RPCError(f"{method}: missing result", kind="protocol_error")
        return reply["result"]


def wait_for_api(port, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return rpc(port, "health")
        except (urllib.error.URLError, ConnectionError, RPCError):
            time.sleep(2)
    raise SystemExit(f"BalatroBot API on :{port} did not come up within {timeout}s")


def best_hand(cards):
    """Indices of a reasonable hand: a flush if there is one, else the biggest rank group, else high cards."""
    with telemetry.operation("balatro.bot.choose_hand") as span:
        by_suit, by_rank = collections.defaultdict(list), collections.defaultdict(list)
        for i, c in enumerate(cards):
            by_suit[c["value"]["suit"]].append(i)
            by_rank[c["value"]["rank"]].append(i)
        rank = lambda i: RANKS.index(cards[i]["value"]["rank"]) if cards[i]["value"]["rank"] in RANKS else 0
        flush = max(by_suit.values(), key=len)
        if len(flush) >= 5:
            span.set_attribute("balatro.bot.strategy", "flush")
            return sorted(flush, key=rank, reverse=True)[:5]
        group = max(by_rank.values(), key=lambda g: (len(g), rank(g[0])))
        if len(group) >= 2:
            span.set_attribute("balatro.bot.strategy", "rank_group")
            return group[:5]
        span.set_attribute("balatro.bot.strategy", "high_cards")
        return sorted(range(len(cards)), key=rank, reverse=True)[:5]


def shop(call, s, forced, opened_pack):
    """One shop pass: buy a joker and a voucher, sell, reroll, open one pack per run, then leave."""
    if forced:
        s = call("set", money=40)
    jokers = s["jokers"]
    for i, c in enumerate(s["shop"]["cards"]):
        if c["set"] == "JOKER" and c["cost"]["buy"] <= s["money"] and jokers["count"] < jokers["limit"]:
            s = call("buy", card=i)
            break
    for i, v in enumerate(s["vouchers"]["cards"]):
        if v["cost"]["buy"] <= s["money"]:
            s = call("buy", voucher=i)
            break
    if s["round_num"] == 3 and s["jokers"]["count"] > 0:  # sell once, for balatro.card.sell
        s = call("sell", joker=0)
    if s["money"] >= s["round"]["reroll_cost"] + 4:
        s = call("reroll")
    if not opened_pack:
        for i, p in enumerate(s["packs"]["cards"]):
            if p["cost"]["buy"] <= s["money"]:
                return call("buy", pack=i)  # back in the shop after the pack; then next_round
    return call("next_round")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", default="OTELTEST")
    ap.add_argument("--deck", default="RED")
    ap.add_argument("--stake", default="WHITE")
    ap.add_argument("--force-rounds", type=int, default=4)
    ap.add_argument("--max-rounds", type=int, default=12)
    ap.add_argument("--port", type=int, default=12346)
    args = ap.parse_args()
    with telemetry.run(args.seed, args.deck, args.stake) as run_span:
        play_run(args, run_span)


def play_run(args, run_span):
    call = lambda method, **p: rpc(args.port, method, **p)

    wait_for_api(args.port)
    s = call("gamestate")
    if s["state"] != "MENU":
        s = call("menu")
    s = call("start", deck=args.deck, stake=args.stake, seed=args.seed)
    skipped = discarded_round = opened_pack = False
    shopped_round = None

    for _ in range(500):  # hard stop if the loop ever stalls
        state = s["state"]
        forced = s["round_num"] <= args.force_rounds
        print(f"ante {s['ante_num']} round {s['round_num']} ${s['money']} {state}", flush=True)
        if state == "GAME_OVER" or s["round_num"] > args.max_rounds:
            break
        with telemetry.decision(state, forced) as decision_span:
            decision_span.set_attribute("balatro.bot.action", state.lower() if state in telemetry.STATES else "other")
            try:
                if state == "BLIND_SELECT":
                    if not skipped:  # skip the first small blind once, for balatro.blind.skip
                        skipped = True
                        s = call("skip")
                    else:
                        s = call("select")
                        discarded_round = False
                elif state == "SELECTING_HAND":
                    hand = s["hand"]["cards"]
                    play = best_hand(hand)
                    if not discarded_round and s["round"]["discards_left"] > 0:
                        discarded_round = True
                        keep = set(play)
                        s = call("discard", cards=[i for i in range(len(hand)) if i not in keep][:5] or [0])
                    else:
                        if forced and s["round"]["hands_left"] == 1:
                            call("set", chips=10**9)  # make sure this hand wins the blind
                        s = call("play", cards=play)
                elif state == "ROUND_EVAL":
                    s = call("cash_out")
                elif state == "SHOP":
                    if shopped_round == s["round_num"]:  # back from a booster pack
                        s = call("next_round")
                    else:
                        shopped_round = s["round_num"]
                        s = shop(call, s, forced, opened_pack)
                        opened_pack = opened_pack or s["state"] == "SMODS_BOOSTER_OPENED"
                elif state == "SMODS_BOOSTER_OPENED":
                    choices = s["pack"]["cards"]
                    no_target = [i for i, c in enumerate(choices) if c["set"] in ("JOKER", "PLANET")]
                    s = call("pack", card=no_target[0]) if no_target else call("pack", skip=True)
                else:
                    time.sleep(0.5)
                    s = call("gamestate")
            except RPCError as e:  # NOT_ALLOWED or a dropped connection: log it, re-read the state, move on
                telemetry.recovery(state)
                print(f"  {e}", flush=True)
                s = wait_for_api(args.port, timeout=60) and call("gamestate")
                if s["state"] == "SHOP":
                    s = call("next_round")

    outcome = (
        "game_over" if s["state"] == "GAME_OVER" else "max_rounds" if s["round_num"] > args.max_rounds else "step_limit"
    )
    run_span.set_attribute("balatro.bot.run.outcome", outcome)
    print(f"done: {s['state']} at ante {s['ante_num']}, round {s['round_num']}", flush=True)
    call("menu")


if __name__ == "__main__":
    main()
