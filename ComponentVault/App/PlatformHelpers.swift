import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PlatformPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    @ViewBuilder
    func platformHelp(_ text: String) -> some View {
        #if os(macOS)
        self.help(text)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformWindowMinSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, minHeight: height)
        #else
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
