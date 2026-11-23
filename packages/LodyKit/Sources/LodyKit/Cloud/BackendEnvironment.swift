import Foundation

/// Build-owned endpoints. No deep link, preference or remote response can override these.
public enum BackendEnvironment {
  private static let values = Bundle.main.object(forInfoDictionaryKey: "LodyBackends") as? [String: String] ?? [:]
  public static let convex = values["CONVEX_URL"] ?? "https://convex.lody.ai"
  public static let site = values["CONVEX_SITE_URL"] ?? "https://backend.lody.ai"
  public static let worker = values["CF_WORKER_URL"] ?? "https://api.lody.ai"
  public static let storageSuffix = values["STORAGE_SUFFIX"] ?? ""
}
