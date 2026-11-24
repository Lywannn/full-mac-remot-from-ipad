import Foundation

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
