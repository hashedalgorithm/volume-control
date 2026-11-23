/// UserDefaults keys shared between the live popover (OutputTabView's section
/// @AppStorage) and PreferencesView, so a section's current expand/collapse state and
/// its "default for next launch" are the same stored value, not two things that can
/// drift apart.
enum PreferenceKeys {
    static let deviceLevelsExpanded = "sectionDeviceLevelsExpanded"
    static let applicationsExpanded = "sectionApplicationsExpanded"

    /// Whether clicking outside the menu-bar popup closes it. Read directly by
    /// PopoverController (not a SwiftUI view, so no @AppStorage there) via
    /// UserDefaults -- registered with a `true` default in main.swift so both sides
    /// agree on the behavior before the user ever opens Preferences.
    static let closeOnOutsideClick = "closeOnOutsideClick"
    static let autoHideEnabled = "autoHideEnabled"
    static let autoHideSeconds = "autoHideSeconds"
}
