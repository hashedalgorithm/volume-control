/// UserDefaults keys shared between the live popover (OutputTabView's section
/// @AppStorage) and PreferencesView, so a section's current expand/collapse state and
/// its "default for next launch" are the same stored value, not two things that can
/// drift apart.
enum PreferenceKeys {
    static let systemExpanded = "sectionSystemExpanded"
    static let deviceLevelsExpanded = "sectionDeviceLevelsExpanded"
    static let applicationsExpanded = "sectionApplicationsExpanded"
}
