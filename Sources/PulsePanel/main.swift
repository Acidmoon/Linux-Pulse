import Foundation

#if canImport(CGTK4)
import CGTK4
import Pulse
#endif

print("PulsePanel: 目标建立")
#if canImport(CGTK4)
print("CGTK4 可用，后端 = \(String(cString: pulse_display_backend()))")
#endif
