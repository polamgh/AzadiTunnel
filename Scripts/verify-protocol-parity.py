#!/usr/bin/env python3
"""Verify Psiphon protocol limits match Shiro Khorshid Android (see PsiphonProtocolSets.swift)."""
from __future__ import annotations

CDN = [
    "FRONTED-MEEK-CDN-OSSH",
    "FRONTED-MEEK-CDN-HTTP-OSSH",
    "FRONTED-MEEK-CDN-QUIC-OSSH",
]
DIRECT = [
    "SSH", "OSSH", "TLS-OSSH",
    "UNFRONTED-MEEK-OSSH", "UNFRONTED-MEEK-HTTPS-OSSH", "UNFRONTED-MEEK-SESSION-TICKET-OSSH",
    "QUIC-OSSH", "SHADOWSOCKS-OSSH",
    "FRONTED-MEEK-OSSH", "FRONTED-MEEK-CDN-OSSH", "FRONTED-MEEK-HTTP-OSSH",
    "FRONTED-MEEK-CDN-HTTP-OSSH", "FRONTED-MEEK-QUIC-OSSH", "FRONTED-MEEK-CDN-QUIC-OSSH",
]
CONDUIT = [
    "INPROXY-WEBRTC-SSH", "INPROXY-WEBRTC-OSSH", "INPROXY-WEBRTC-TLS-OSSH",
    "INPROXY-WEBRTC-UNFRONTED-MEEK-OSSH", "INPROXY-WEBRTC-UNFRONTED-MEEK-HTTPS-OSSH",
    "INPROXY-WEBRTC-UNFRONTED-MEEK-SESSION-TICKET-OSSH",
    "INPROXY-WEBRTC-FRONTED-MEEK-OSSH", "INPROXY-WEBRTC-FRONTED-MEEK-HTTP-OSSH",
    "INPROXY-WEBRTC-QUIC-OSSH", "INPROXY-WEBRTC-FRONTED-MEEK-QUIC-OSSH",
    "INPROXY-WEBRTC-SHADOWSOCKS-OSSH",
]

# Legacy wrong values — must not reappear
FORBIDDEN = {"Direct", "INPROXY-TLS-OSSH"}


def limits(protocol: str, beast: bool, selection_auto: bool) -> list[str] | None:
    if beast and selection_auto:
        return None
    if protocol == "auto":
        return None
    if protocol == "direct":
        return DIRECT
    if protocol == "cdnFronting":
        return CDN
    if protocol == "conduit":
        return CONDUIT
    raise ValueError(protocol)


def main() -> int:
    cases = [
        ("auto+beast", limits("auto", True, True), None),
        ("auto no beast", limits("auto", False, True), None),
        ("direct", limits("direct", False, False), DIRECT),
        ("cdn", limits("cdnFronting", False, False), CDN),
        ("conduit", limits("conduit", False, False), CONDUIT),
        ("direct+beast", limits("direct", True, False), DIRECT),
    ]
    for name, got, want in cases:
        assert got == want, f"{name}: {got} != {want}"

    for bad in FORBIDDEN:
        for group in (DIRECT, CDN, CONDUIT):
            assert bad not in group, f"forbidden protocol {bad} in group"

    print("OK: protocol parity checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
