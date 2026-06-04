# Third-Party Notices

This file lists third-party software used by AzadiTunnel.

## Psiphon (Psiphon Inc.)

- **Organization:** https://github.com/psiphon-inc  
- **Website:** https://psiphon.ca  
- **License:** GNU General Public License v3 (tunnel-core components)  
- **Use:** Psiphon tunnel technology powers the VPN tunnel core.  
- **Note:** Psiphon® is a registered trademark of Psiphon Inc. AzadiTunnel is an independent client and is not developed, endorsed, or affiliated with Psiphon Inc.

## psiphon-tunnel-core

- **Project:** https://github.com/shirokhorshid/psiphon-tunnel-core  
- **License:** GNU General Public License v3  
- **Use:** Tunnel client core (iOS `PsiphonTunnel` / `PsiphonTunnelCore.xcframework`)  
- **Pinned commit:** See `Tooling/psiphon/PSIPHON_PINNED_COMMIT`  
- **Source offer:** Same repository as AzadiTunnel plus tunnel-core source at the pinned revision.

## tun2socks (packet forwarding)

- **Project:** https://github.com/EbrahimTahernejad/tun2socks-swift (Swift Package)  
- **License:** See upstream repository  
- **Use:** Forward `NEPacketTunnelFlow` traffic to local Psiphon SOCKS proxy  

## Apple system frameworks

- NetworkExtension, Network, SwiftUI — Apple SDK license terms apply.

---

_Add additional dependencies here as they are added. Do not remove Psiphon attribution._
