#!/usr/bin/env python3
"""Reproduce known Balatro issues through the BalatroBot API, so their
telemetry can be checked. Each scenario prints RESULT lines; whether the bug still exists in this
game version is part of the outcome, not a failure of the script.

  perkeo     C1  Perkeo + Wheel of Fortune, then leave the shop (reported crash)
  spectral   S1  quit with a Spectral pack open, load the save, try to continue (reported softlock)
  retrigger  P1  retrigger jokers + red-seal face cards: scoring time and animation queue
  mouth      W1  replay the seed where The Mouth gained 60 chips outside the hand scores
  psychic    W1  short version for a screen recording: skip to The Psychic, play two blocked Pairs
  boss           force-win blinds until a boss in SCENARIO_BOSSES comes up (seeds BOSS0001..), play
                 4 real hands into it; check_traces.py then compares each hand with the blind's gain

Usage: scenarios.py <scenario> [--port 12346]
"""
import argparse
import os
import subprocess
import sys
import time

from autoplay import RPCError, best_hand, rpc, wait_for_api

FORCE_WIN = 10**9  # chips set before the last hand so the blind is won


def result(name, **facts):
    print(f"RESULT {name}: " + ", ".join(f"{k}={v}" for k, v in facts.items()), flush=True)


def alive(port):
    try:
        rpc(port, "health")
        return True
    except RPCError:
        return False


class Game:
    def __init__(self, port):
        self.port = port

    def __call__(self, method, **params):
        return rpc(self.port, method, **params)

    def start(self, seed, deck=None, stake=None):
        # BalatroBot 1.5.2 takes enum names (RED, WHITE); its dev branch takes game keys (b_red, stake_white)
        deck = deck or os.environ.get("SCENARIO_DECK", "RED")
        stake = stake or os.environ.get("SCENARIO_STAKE", "WHITE")
        wait_for_api(self.port)
        if self("gamestate")["state"] != "MENU":
            self("menu")
        return self("start", deck=deck, stake=stake, seed=seed)

    def to_shop(self, s):
        """Win the current small blind quickly and cash out."""
        if s["state"] == "BLIND_SELECT":
            s = self("select")
        self("set", chips=FORCE_WIN)
        s = self("play", cards=best_hand(s["hand"]["cards"]) if "hand" in s else [0])
        while s["state"] not in ("ROUND_EVAL", "SHOP"):
            time.sleep(0.5)
            s = self("gamestate")
        return self("cash_out") if s["state"] == "ROUND_EVAL" else s


def perkeo(game):
    s = game.to_shop(game.start("PERKEO01"))
    s = game("add", key="j_perkeo")
    s = game("add", key="c_wheel_of_fortune")
    result("perkeo", setup=f"jokers={[c['key'] for c in s['jokers']['cards']]} consumables={[c['key'] for c in s['consumables']['cards']]}")
    try:
        s = game("next_round")
        result("perkeo", crashed="no", state=s["state"], consumables=[c["key"] for c in s["consumables"]["cards"]])
        game("menu")  # ends the run, so its balatro.run span is sent
    except RPCError as e:
        result("perkeo", crashed="yes" if not alive(game.port) else "unclear", error=e)


def spectral(game):
    s = game.to_shop(game.start("SPECTRL1"))
    s = game("set", money=50)
    # the shop's booster slots are full: buy and skip one pack to free a slot
    s = game("buy", pack=0)
    s = game("pack", skip=True)
    try:
        s = game("add", key="p_spectral_normal_1")
    except RPCError as e:
        result("spectral", setup="add pack failed", error=e)
        return
    packs = s["packs"]["cards"]
    index = next(i for i, p in enumerate(packs) if p["key"].startswith("p_spectral"))
    s = game("buy", pack=index)
    result("spectral", opened=s["state"], choices=[c["key"] for c in s.get("pack", {}).get("cards", [])])
    game("save", path="/tmp/spectral.jkr")
    game("menu")
    game("load", path="/tmp/spectral.jkr")
    time.sleep(3)
    s = game("gamestate")
    try:
        after = game("pack", skip=True)
        result("spectral", softlock="no", state_after_load=s["state"], state_after_skip=after["state"])
    except RPCError as e:
        result("spectral", softlock="yes", state_after_load=s["state"], error=e)
    try:
        game("menu")
    except RPCError:
        pass


def retrigger(game):
    s = game.start("RETRIG01")
    s = game("select")
    s = game("set", hands=6, discards=6)
    # baseline: one card, too weak to beat the blind, so the round goes on
    s = game("play", cards=[0])
    while s["state"] in ("HAND_PLAYED", "DRAW_TO_HAND"):
        time.sleep(0.5)
        s = game("gamestate")
    result("retrigger", baseline_hand="played", state=s["state"])
    if s["state"] != "SELECTING_HAND":
        return
    for key in ("j_hanging_chad", "j_sock_and_buskin", "j_selzer", "j_blueprint", "j_brainstorm"):
        s = game("add", key=key)
    for card in ("H_K", "S_K", "D_K", "C_K", "H_Q"):
        s = game("add", key=card, seal="RED", enhancement="GLASS", edition="POLYCHROME")
    hand = s["hand"]["cards"]
    build = [i for i, c in enumerate(hand) if (c.get("modifier") or {}).get("seal") == "RED"][:5]
    t0 = time.time()
    s = game("play", cards=build)
    while s["state"] == "HAND_PLAYED" or s["state"] == "DRAW_TO_HAND":
        time.sleep(0.5)
        s = game("gamestate")
    result("retrigger", cards=len(build), play_seconds=round(time.time() - t0, 1), state=s["state"],
           chips=s["round"]["chips"])
    game("menu")


def mouth(game):
    # The Mouth gap was seen in seed C10002 (BLUE deck, RED stake) with autoplay's normal play.
    code = subprocess.call([sys.executable, __file__.replace("scenarios.py", "autoplay.py"),
                            "--seed", "C10002", "--deck", "BLUE", "--stake", "RED", "--port", str(game.port)])
    result("mouth", autoplay_exit=code, check="telemetry/check_traces.py flags blinds whose score != hands")


def psychic(game):
    # W110002's first boss is The Psychic on Steamodded beta-1814a (hands of fewer than 5 cards are
    # debuffed); bosses differ on newer Steamodded (smods#1565), so SCENARIO_SEED can override it
    # win small and big blind instantly (skipping can open a tag's booster pack, which `skip` hangs on)
    s = game.start(os.environ.get("SCENARIO_SEED", "W110002"))
    for _ in range(2):
        game.to_shop(s)
        s = game("next_round")
    boss = s["blinds"]["boss"]["name"]
    s = game("select")
    for _ in range(2):
        before = s["round"]["chips"]
        hand = s["hand"]["cards"]
        ranks = [c["value"]["rank"] for c in hand]
        pair = next(([i, j] for i in range(len(hand)) for j in range(i + 1, len(hand)) if ranks[i] == ranks[j]), [0, 1])
        time.sleep(2)  # let the viewer see the hand
        s = game("play", cards=pair)
        while s["state"] in ("HAND_PLAYED", "DRAW_TO_HAND"):
            time.sleep(0.5)
            s = game("gamestate")
        result("psychic", boss=boss, played=[hand[i]["key"] for i in pair], blind_gained=s["round"]["chips"] - before)
        time.sleep(3)
    game("menu")


def boss(game):
    wanted = set(os.environ.get("SCENARIO_BOSSES", "The Flint,The House,The Wheel,The Mark").split(","))
    for n in range(1, 41):
        if not wanted:
            break
        s = game.start(f"BOSS{n:04d}")
        while s["ante_num"] <= 4 and wanted:
            name = s["blinds"]["boss"]["name"]
            on_boss = s["blinds"]["boss"]["status"] == "SELECT"
            if on_boss and name in wanted:
                wanted.discard(name)
                s = game("select")
                s = game("set", hands=6)
                for _ in range(4):
                    before = s["round"]["chips"]
                    s = game("play", cards=best_hand(s["hand"]["cards"]))
                    while s["state"] in ("HAND_PLAYED", "DRAW_TO_HAND"):
                        time.sleep(0.5)
                        s = game("gamestate")
                    result("boss", seed=f"BOSS{n:04d}", boss=name, blind_gained=s["round"]["chips"] - before)
                    if s["state"] != "SELECTING_HAND":
                        break
                break
            s = game.to_shop(s)
            s = game("next_round")
        game("menu")
    result("boss", not_found=sorted(wanted))


SCENARIOS = {"perkeo": perkeo, "spectral": spectral, "retrigger": retrigger, "mouth": mouth, "psychic": psychic, "boss": boss}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario", choices=SCENARIOS)
    ap.add_argument("--port", type=int, default=12346)
    args = ap.parse_args()
    try:
        SCENARIOS[args.scenario](Game(args.port))
    except RPCError as e:
        result(args.scenario, aborted=e)


if __name__ == "__main__":
    main()
