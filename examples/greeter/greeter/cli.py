import sys

import cowsay


def _who() -> str:
    return sys.argv[1] if len(sys.argv) > 1 else "world"


def main() -> int:
    cowsay.cow(f"hello, {_who()}")
    return 0


def loud() -> int:
    print(f"HELLO, {_who().upper()}!")
    return 0
