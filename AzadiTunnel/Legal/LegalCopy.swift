import Foundation

enum LegalCopy {
    static let disclaimer =
        """
        This app is not developed, endorsed, sponsored, or affiliated with Psiphon Inc.

        AzadiTunnel is an independent open-source VPN client. Psiphon® is a registered trademark of Psiphon Inc.
        """

    static let gplSummary =
        """
        AzadiTunnel is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

        AzadiTunnel is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file in the project repository for the full text.
        """

    static let sourceAvailability =
        """
        Corresponding source code for distributed builds is available in the project repository. Include build instructions for the Psiphon tunnel core xcframework (see Tooling/psiphon/build-ios-xcframework.sh).
        """

    static let privacy =
        """
        AzadiTunnel routes network traffic through a VPN tunnel. Diagnostic logs stored on your device may contain connection events but do not include your full Psiphon configuration or embedded server entries.

        Optional feedback or crash reports, if enabled in a future version, would be sent only with your consent.
        """

    static let vpnDataCollection =
        """
        AzadiTunnel uses Apple’s Network Extension framework to create a VPN tunnel. Traffic is processed on your device and through the Psiphon tunnel core.

        Connection statistics (bytes transferred, duration) are stored locally in the App Group shared container. They are not uploaded by default.
        """
}
