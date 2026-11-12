import ServiceManagement

package nonisolated enum LoginItem {
    package static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    package static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
