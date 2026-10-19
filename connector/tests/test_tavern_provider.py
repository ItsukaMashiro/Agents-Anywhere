from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

from connector.runtimes.dsh.discovery import BridgeEndpoint, DshDiscovery
from connector.runtimes.tavern.provider import TavernProvider

CATALOG = {
    "groups": [{"id": "g1", "name": "默认组"}],
    "cards": [{"id": "card-1", "name": "Alice", "group": "g1"}],
}


def _endpoint(tmp_path: Path) -> BridgeEndpoint:
    path = tmp_path / "home" / "agents-anywhere" / "bridge" / "endpoint.json"
    return BridgeEndpoint("127.0.0.1", 23456, "token", os.getpid(), path)


def test_tavern_provider_identity() -> None:
    provider = TavernProvider()
    assert provider.runtime == "tavern"
    assert provider.runtime_type == "tavern"
    assert provider.display_name == "DSH Tavern"


def test_tavern_discover_surfaces_card_catalog(tmp_path: Path) -> None:
    endpoint = _endpoint(tmp_path)

    async def discover(values: dict[str, Any]) -> DshDiscovery:
        # The static discoverer never touches the bridge: no catalog here.
        return DshDiscovery(
            available=True,
            configured=True,
            endpoint=endpoint,
            metadata={"profile": "tavern"},
        )

    async def probe(values: dict[str, Any]) -> DshDiscovery:
        return DshDiscovery(
            available=True,
            configured=True,
            endpoint=endpoint,
            metadata={"tavernCardCatalog": CATALOG},
        )

    async def run() -> None:
        provider = TavernProvider(dsh_home=str(tmp_path / "home"))
        provider._discoverer = discover
        provider._prober = probe
        descriptor = await provider.discover()
        assert descriptor.runtime_type == "tavern"
        assert descriptor.available is True
        assert descriptor.config_schema.metadata["tavernCardCatalog"] == CATALOG

    asyncio.run(run())


def test_tavern_discover_without_bridge_keeps_schema_usable(tmp_path: Path) -> None:
    home = str(tmp_path / "home")

    async def discover(values: dict[str, Any]) -> DshDiscovery:
        return DshDiscovery(available=False, configured=False, endpoint=None, metadata={})

    async def probe(values: dict[str, Any]) -> DshDiscovery:
        raise RuntimeError("bridge offline")

    async def run() -> None:
        provider = TavernProvider(dsh_home=home)
        provider._discoverer = discover
        provider._prober = probe
        descriptor = await provider.discover()
        assert descriptor.available is False
        assert "tavernCardCatalog" not in descriptor.config_schema.metadata
        assert descriptor.config_schema.defaults["dshHome"] == home

    asyncio.run(run())
