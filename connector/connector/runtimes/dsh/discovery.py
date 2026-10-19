from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from connector.runtimes.dsh import provider_config


@dataclass(frozen=True, slots=True)
class BridgeEndpoint:
    host: str
    port: int
    token: str
    pid: int
    path: Path


@dataclass(frozen=True, slots=True)
class DshDiscovery:
    available: bool
    configured: bool
    endpoint: BridgeEndpoint | None
    bridge_version: str | None = None
    reason: str | None = None
    metadata: dict[str, Any] | None = None


def _static_metadata(values: dict[str, Any]) -> dict[str, Any]:
    return {
        "endpoint": str(provider_config.endpoint_path(values)),
        "storageMode": "dsh-native",
        "sameSessionWriterLimit": 1,
        "crossProcessWriterExclusion": False,
    }


async def discover(values: dict[str, Any]) -> DshDiscovery:
    """Report that this connector supports the DSH runtime type.

    The device list only answers "which runtime types does this connector
    support", so discovery must not touch the DSH bridge. Whether a bridge is
    actually reachable is a configuration/start concern and belongs to
    probe(); ``configured`` and ``endpoint`` are only meaningful there.
    """
    return DshDiscovery(
        True,
        True,
        None,
        reason=None,
        metadata=_static_metadata(values),
    )


async def probe(values: dict[str, Any]) -> DshDiscovery:
    """Authenticate against a running DSH bridge. Configuration/start only."""

    try:
        endpoints = load_endpoints(values)
    except (OSError, ValueError):
        return DshDiscovery(
            False,
            False,
            None,
            reason="请启动 DSH，并启用手机连接插件。",
        )
    # A stale fixed endpoint must not hide a live one published by an older plugin.
    results = [await _probe_endpoint(endpoint, values) for endpoint in endpoints]
    return next((result for result in results if result.available), results[0])


async def _probe_endpoint(endpoint: BridgeEndpoint, values: dict[str, Any]) -> DshDiscovery:
    # Windows os.kill(pid, 0) is not a process-existence probe: it uses
    # TerminateProcess. On Windows rely on the authenticated handshake below.
    if os.name != "nt" and not _process_exists(endpoint.pid):
        return DshDiscovery(
            False,
            False,
            None,
            reason="DSH 插件发现记录已失效，请重新启动 DSH。",
        )
    # A live PID is insufficient: authenticate a short-lived connection to the actual port.
    # Import here because BridgeClient's endpoint DTO belongs to this module.
    from connector.runtimes.dsh.bridge.client import BridgeClient

    async def ignore_notification(method: str, params: Mapping[str, Any]) -> None:
        pass

    async def ignore_exit(code: int | None) -> None:
        pass

    client = BridgeClient(
        endpoint=endpoint,
        connector_id="discovery",
        client_version="1.0",
        startup_timeout=2,
        request_timeout=2,
        notification_handler=ignore_notification,
        exit_handler=ignore_exit,
    )
    try:
        result = await client.start()
        await client.request("ping")
        extra: dict[str, Any] = {}
        for method, key, params in (
            ("runtime.getCapabilities", "runtimeCapabilities", None),
            ("catalog.listAgentPresets", "agentPresetCatalog", None),
            # Slim card list only: openings are fetched per card on demand and
            # the full catalog would exceed the connector<->server frame budget.
            ("catalog.listTavernCards", "tavernCardCatalog", {"openings": False}),
        ):
            try:
                extra[key] = await client.request(method, params)
            except (RuntimeError, ValueError):
                # Older or read-only plugins remain discoverable; they cannot advertise these controls.
                pass
    except (OSError, RuntimeError, ValueError):
        return DshDiscovery(
            False, False, None, reason="无法连接 DSH 插件，请确认插件已启动。"
        )
    finally:
        await client.close()
    return DshDiscovery(
        True,
        True,
        endpoint,
        bridge_version=result["identity"].get("bridgeVersion"),
        metadata={**extra, **_static_metadata(values)},
    )


def load_endpoints(values: dict[str, Any]) -> list[BridgeEndpoint]:
    """Readable endpoints in connection order: the fixed location, then DSH_HOME.

    Older plugins only publish under DSH_HOME. Callers try each in turn, so a
    missing, invalid or stale fixed endpoint never blocks the legacy one.
    """
    endpoints: list[BridgeEndpoint] = []
    errors: list[Exception] = []
    paths = (provider_config.endpoint_path(values), provider_config.legacy_endpoint_path(values))
    for path in dict.fromkeys(paths):
        try:
            endpoints.append(read_endpoint(path))
        except (OSError, ValueError) as exc:
            errors.append(exc)
    if not endpoints:
        # A malformed record explains more than a missing one.
        raise next((error for error in errors if not isinstance(error, FileNotFoundError)), errors[0])
    return endpoints


def load_endpoint(values: dict[str, Any]) -> BridgeEndpoint:
    return load_endpoints(values)[0]


def read_endpoint(path: Path) -> BridgeEndpoint:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("version") != 1:
        raise ValueError("bridge endpoint has an unsupported version")
    host = raw.get("host")
    port = raw.get("port")
    token = raw.get("token")
    pid = raw.get("pid")
    if host != "127.0.0.1":
        raise ValueError("bridge endpoint is not loopback-only")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65_535:
        raise ValueError("bridge endpoint port is invalid")
    if not isinstance(token, str) or not token:
        raise ValueError("bridge endpoint token is missing")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise ValueError("bridge endpoint process is invalid")
    return BridgeEndpoint(host=host, port=port, token=token, pid=pid, path=path)


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
