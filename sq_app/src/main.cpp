// sqterm: the app. A terminal for Android, on squared (Sprint 12).
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// squared_main runs once, when the first window is up. It starts the Shell
// (the model: the shell in a pty, on its own thread), names the terminal
// widget as a custom node, gives the Stage the glyphs' surface hook (their
// texture comes back after Android takes the surface away), and shows the
// one screen. The shell's home is the app's private files: files/home.
// It also keeps the App, for quit_app (Enter after the shell has ended), and
// keeps sqterm running in the background while the shell runs (12.6): the
// notification Termux has, with Exit and the wake lock (BACKGROUND=1).

#include "sqterm.hpp"

namespace sqterm {

namespace {

/// The one App of the process, named by squared_main (UI thread only).
sq::App* the_app = nullptr;

}  // namespace

void quit_app() noexcept {
    if (the_app != nullptr) {
        the_app->quit();
    }
}

void Screen::build(sq::gui::LayoutWriter& root) {
    root.add_custom("terminal_view").grow();
}

std::unique_ptr<sq::gui::Widget> make_terminal(sq::Stage& stage) {
    return std::make_unique<TerminalView>(stage, glyphs());
}

}  // namespace sqterm

void squared_main(sq::App& app) {
    sqterm::the_app = &app;
    sqterm::Places places;
    if (sq::files::FileSystem* files = app.stage.files()) {
        using sq::files::FileType;
        static_cast<void>(files->make_directories(FileType::Local, "home"));
        static_cast<void>(files->make_directories(FileType::Local, "tmp"));
        places.home = files->resolve_platform_path(FileType::Local, "home");
        places.tmp = files->resolve_platform_path(FileType::Local, "tmp");
    }
    app.run<sqterm::Shell>(std::move(places));
    static_cast<void>(app.keep_running({.title = "sqterm", .text = "1 session"}));
    app.stage.add<sqterm::Screen>();  // by its name: so Android can keep it
    app.stage.custom("terminal_view", &sqterm::make_terminal);
    app.stage.on_surface(&sqterm::Glyphs::restore, &sqterm::glyphs());
    app.stage.push<sqterm::Screen>();
}
