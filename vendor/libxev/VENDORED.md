Vendored libxev for the cmux ghostty fork.

Upstream: mitchellh/libxev @ 34fa50878aec6e5fa8f532867001ab3c36fae23e
(the same commit ghostty's build.zig.zon previously pinned by URL+hash).

Local patch (src/backend/kqueue.zig): machport kevent registration and
threadpool loop wakeup were gated to `os.tag == .macos`, which silently
disabled every `xev.Async` on iOS — completions were accepted but never
registered with the kernel, so `Async.notify()` posted mach messages to
ports no kqueue watched. On iOS that made ghostty's renderer/io thread
stop signals undeliverable and `Surface.deinit` joins hang forever
(cmux iOS 0x8BADF00D watchdog kills). EVFILT_MACHPORT + MACH_RCV_MSG via
kevent64 verified working on the iOS 26.5 simulator empirically, so both
gates are widened from `== .macos` to `isDarwin()`.
