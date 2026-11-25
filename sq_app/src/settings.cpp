// sqterm: the app's Settings, squared's Settings screen (sq.settings) over the
// app's preferences (sq.preferences; docs/design/preferences.md in squared).
//
// This file is sqterm's own (sqIDE, built on sqterm, uses it too).
//
// What squared gives every app: the UI's zoom, pinch to zoom and the zoom's
// range, and Reset all. sqterm's own sections (the terminal's scrollback,
// bell, shell; the theme and the font, moved in from theme.json and
// terminal.font) come later, when the terminal reads them from here.

#include "sqterm.hpp"

import sq.preferences;
import sq.settings;

namespace sqterm {

namespace {

/// The app's preferences and Settings: one each, for the process (UI thread).
std::optional<sq::preferences::Preferences> the_preferences;
std::optional<sq::Settings> the_settings;

}  // namespace

void start_settings(sq::Stage& stage, std::string_view app_id) {
    if (the_settings.has_value()) {
        return;
    }
    sq::files::FileSystem* files = stage.files();
    if (files == nullptr) {
        return;
    }
    auto opened = sq::preferences::Preferences::open(*files, app_id);
    if (!opened) {
        return;  // no Settings: the app runs with squared's defaults
    }
    the_preferences.emplace(std::move(*opened));
    // The Input section's keyboard on start: not the terminal's to read yet.
    the_settings.emplace(stage, *the_preferences,
                         sq::StandardSettings::zoom | sq::StandardSettings::preferences);
    the_settings->apply();
    stage.add<sq::SettingsScreen>();  // by its name: so Android can keep it
}

void show_settings(sq::Stage& stage) {
    if (the_settings.has_value()) {
        static_cast<void>(stage.push<sq::SettingsScreen>());
    }
}

}  // namespace sqterm
