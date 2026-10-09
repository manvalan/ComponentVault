import CoreGraphics

enum AppLayout {
    static let defaultWidth: CGFloat = 1440
    static let defaultHeight: CGFloat = 860
    static let minWidth: CGFloat = 1120
    static let minHeight: CGFloat = 680

    static let sectionSidebarWidth: CGFloat = 168

    /// Sidebar NavigationSplitView su iPad.
    static let padSidebarMin: CGFloat = 240
    static let padSidebarIdeal: CGFloat = 280

    static let inventoryListMin: CGFloat = 280
    static let inventoryListIdeal: CGFloat = 320

    static let catalogTypeMin: CGFloat = 200
    static let catalogTypeIdeal: CGFloat = 220
    static let catalogGroupMin: CGFloat = 340
    static let catalogGroupIdeal: CGFloat = 420

    static let projectsListMin: CGFloat = 240
    static let projectsListIdeal: CGFloat = 280

    static let alertsListMin: CGFloat = 260
    static let alertsListIdeal: CGFloat = 300

    static let detailMin: CGFloat = 360
}
