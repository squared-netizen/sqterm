// sqterm: the app. A terminal for Android, on squared (Sprint 12).
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// squared_main runs once, when the first window is up. It starts the Shell
// (the model: the shell in a pty, on its own thread), names the terminal
// widget as a custom node, gives the Stage the glyphs' surface hook (their
// texture comes back after Android takes the surface away), and shows the
// one screen. The shell's home is the app's private files: files/home.

#include "sqterm.hpp"

namespace sqterm {

void Screen::build(sq::gui::LayoutWriter& root) {
    root.add_custom("terminal_view").grow();
}

std::unique_ptr<sq::gui::Widget> make_terminal(sq::Stage& stage) {
    return std::make_unique<TerminalView>(stage, glyphs());
}

}  // namespace sqterm

void squared_main(sq::App& app) {
    sqterm::Places places;
    if (sq::files::FileSystem* files = app.stage.files()) {
        using sq::files::FileType;
        static_cast<void>(files->make_directories(FileType::Local, "home"));
        static_cast<void>(files->make_directories(FileType::Local, "tmp"));
        places.home = files->resolve_platform_path(FileType::Local, "home");
        places.tmp = files->resolve_platform_path(FileType::Local, "tmp");
    }
    app.run<sqterm::Shell>(std::move(places));
    app.stage.add<sqterm::Screen>();  // by its name: so Android can keep it
    app.stage.custom("terminal_view", &sqterm::make_terminal);
    app.stage.on_surface(&sqterm::Glyphs::restore, &sqterm::glyphs());
    app.stage.push<sqterm::Screen>();
}
