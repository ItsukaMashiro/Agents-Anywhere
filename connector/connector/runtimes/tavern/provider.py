"""Tavern runtime provider: a DSH-family runtime served by the main connector.

Tavern is a second DSH instance (SillyTavern-compatible) whose bridge endpoint
lives under its own DSH home. The provider reuses the DSH provider surface so
the bridge protocol, capability set, and session projection stay identical,
while the runtime TYPE and identity are separate so the device page lists it as
an independent agent alongside Codex/DSH. The character-card catalog observed
through the bridge is surfaced on the config schema metadata so clients can
drive the opening flow without extra round-trips.
"""

from __future__ import annotations

import dataclasses
import os
from pathlib import Path

from connector.runtimes.dsh.provider import DshProvider

DEFAULT_TAVERN_DSH_HOME = os.environ.get("DSH_TAVERN_HOME", r"E:\dsh-tavern")


class TavernProvider(DshProvider):
    def __init__(self, dsh_home: str | None = None) -> None:
        super().__init__()
        self._tavern_dsh_home = dsh_home or DEFAULT_TAVERN_DSH_HOME
        # A second DSH instance must not contend for the shared per-user bridge
        # lease: point it at the bridge directory under its own DSH home, which
        # is also where the legacy endpoint publication lands for it.
        self._tavern_bridge_dir = str(Path(self._tavern_dsh_home) / "agents-anywhere" / "bridge")
        self._last_values = {**self._last_values, "dshHome": self._tavern_dsh_home}

    @property
    def runtime(self) -> str:
        return "tavern"

    @property
    def runtime_type(self) -> str:
        return "tavern"

    @property
    def display_name(self) -> str:
        return "DSH Tavern"

    @property
    def description(self) -> str:
        return "DSH Tavern local service runtime (SillyTavern-compatible)"

    async def discover(self):
        # The card catalog only exists while the Tavern bridge runs, and the
        # static discoverer never touches it: refresh through the prober first
        # so the descriptor's config schema carries tavernCardCatalog for the
        # device page in the same pass as availability.
        await self._refresh_presets()
        return await super().discover()

    def _config_schema(self):
        schema = super()._config_schema()
        metadata = dict(schema.metadata)
        if self._tavern_catalog.get("cards"):
            metadata["tavernCardCatalog"] = dict(self._tavern_catalog)
        return dataclasses.replace(
            schema,
            defaults={
                **schema.defaults,
                "dshHome": self._tavern_dsh_home,
                "bridgeDir": self._tavern_bridge_dir,
            },
            metadata=metadata,
        )

    async def validate_config(self, values):
        if not values.get("dshHome"):
            values = {**values, "dshHome": self._tavern_dsh_home}
        if not values.get("bridgeDir"):
            values = {**values, "bridgeDir": self._tavern_bridge_dir}
        return await super().validate_config(values)

    async def create_runtime(self, config, host):
        from connector.runtimes.tavern.runtime import TavernRuntime

        return TavernRuntime(config=config, host=host)
