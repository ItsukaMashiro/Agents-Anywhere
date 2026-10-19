"""Tavern runtime: the DSH protocol adapter with tavern identity."""

from connector.runtimes.dsh.runtime import DshRuntime


class TavernRuntime(DshRuntime):
    """Same bridge protocol as DSH; reports a tavern identity."""

    identity_runtime: str = "tavern"
    identity_display_name: str = "DSH Tavern"
