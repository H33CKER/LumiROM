from __future__ import annotations

import sys

INSTALL_HINT = (
    "LumiROM Builder TUI dependencies are missing.\n"
    "Install them with:\n\n"
    "    python3 -m pip install --break-system-packages -r scripts/tui/requirements.txt\n"
)


def main() -> None:
    try:
        import textual_tty  # noqa: F401
    except ImportError:
        print(INSTALL_HINT, file=sys.stderr)
        raise SystemExit(1)

    from .app import LumiTUI

    LumiTUI().run()


if __name__ == "__main__":
    main()
