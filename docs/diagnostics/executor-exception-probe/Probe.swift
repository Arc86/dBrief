import Foundation

// Diagnostic only. No audio devices or dBrief state are accessed.
@_cdecl("scheduleProbe")
public func scheduleProbe(_ mode: Int32) {
    Task { @MainActor in
        print("task entered on main actor")
        if mode == 1 { raiseProbeException() }
        if mode == 2 { containProbeException() }
        print("task returned normally")
    }
}

@_cdecl("checkProbe")
public func checkProbe() {
    print("checking main actor after run loop")
    MainActor.preconditionIsolated()
    print("main actor check passed")
}
