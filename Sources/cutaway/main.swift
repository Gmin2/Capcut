import Foundation

// Deliberately trivial and frozen. Recompiling this file invalidates the
// screen recording permission, so it must never need to change: all real
// logic lives in the dylib it loads.
let lib = NSString(string: "~/Library/Application Support/Cutaway/libCutawayCore.dylib")
    .expandingTildeInPath

guard let handle = dlopen(lib, RTLD_NOW | RTLD_GLOBAL) else {
    FileHandle.standardError.write(Data("cutaway: \(String(cString: dlerror()))\n".utf8))
    exit(1)
}
guard let sym = dlsym(handle, "cutaway_main") else {
    FileHandle.standardError.write(Data("cutaway: entry point not found\n".utf8))
    exit(1)
}
unsafeBitCast(sym, to: (@convention(c) () -> Void).self)()
