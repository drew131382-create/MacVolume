import Foundation

enum CommunicationRoutingPolicy {
    /// WeChat's web/media host may play Channels while the main process owns
    /// the call. Protect that separate output without tapping the call itself.
    static func protectsCallMedia(ownerBundleID: String, processBundleID: String?, isInputting: Bool) -> Bool {
        guard ownerBundleID.lowercased() == "com.tencent.xinwechat", !isInputting,
              let bundleID = processBundleID?.lowercased() else { return false }
        return bundleID == "com.tencent.flue.wechatappex"
            || bundleID.hasPrefix("com.tencent.flue.wechatappex.")
    }
}
