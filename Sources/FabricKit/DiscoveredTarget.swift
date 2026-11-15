import Foundation

/// One target a discovery found: an iSCSI SendTargets record, or an NVMe/TCP
/// discovery log entry (the subsystem NQN and its one transport address).
public struct DiscoveredTarget: Sendable, Equatable {
    public var name: String
    /// "host:port,tpgt" entries for iSCSI, "host:port" for NVMe/TCP; may be
    /// empty when an iSCSI target only answers on the portal we asked.
    public var addresses: [String]

    public init(name: String, addresses: [String]) {
        self.name = name
        self.addresses = addresses
    }
}
