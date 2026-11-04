// sqterm: the model. The shell in a pty, on the model's thread.
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// The model sleeps until the shell writes (Telegraph::watch on the pty), the
// UI sends keys or a size, or Android's lifecycle reaches it: no tick, no
// polling. Each time the shell writes, what it wrote goes through the
// Terminal and the whole screen is published as a snapshot; the UI draws the
// newest one. When the shell ends, the terminal says so as Termux does,
// `[Process completed (code N) - press Enter]`, and what is typed after is
// dropped: Enter closes sqterm (the widget sees term.completed and quits the
// app). One session for now; with several (later), only the last one's end
// will close the app.

#include "sqterm.hpp"

namespace sqterm {

namespace {

/// Read at most this much in one turn before publishing: a flood of output
/// still shows, and keys still get through.
constexpr std::size_t read_per_turn = std::size_t{256} * 1024;
constexpr std::size_t buffer_bytes = std::size_t{16} * 1024;

/// Writing keys waits no longer than this for a shell that is not reading.
constexpr int key_wait_ms = 100;

/// The shell (12.5 brings zsh in sqterm's own prefix; until then Android's).
constexpr std::string_view shell_program = "/system/bin/sh";

}  // namespace

Shell::Shell(Places places)
    : places_(std::move(places)),
      terminal_(sq::term::TerminalConfig{.columns = 80, .rows = 24}),
      buffer_(std::make_unique_for_overwrite<std::byte[]>(buffer_bytes)) {
    // The environment the shell starts with; .zshrc adds the rest (12.5).
    const std::array<std::string, 8> text{
        "TERM=sqterm",
        "COLORTERM=truecolor",
        "LANG=en_US.UTF-8",
        "HOME=" + places_.home,
        "TMPDIR=" + places_.tmp,
        "PATH=/system/bin:/system/xbin",
        "SHELL=" + std::string(shell_program),
        "SQTERM=1",
    };
    environment_text_ = text;
    for (const std::string& line : environment_text_) {
        environment_[environment_count_++] = line;
    }
}

Shell::~Shell() = default;

void Shell::start(sq::messaging::Telegraph& t) {
    spawn(t);
}

void Shell::spawn(sq::messaging::Telegraph& t) {
    pty_ = sq::term::Pty{};
    const sq::term::PtyConfig config{
        .program = shell_program,
        .arguments = {},
        .environment = std::span(environment_.data(), environment_count_),
        .directory = places_.home,
        .columns = terminal_.columns(),
        .rows = terminal_.rows(),
    };
    if (const sq::term::PtyError error = pty_.spawn(config)) {
        std::array<char, 160> line{};
        const int n = std::snprintf(line.data(), line.size(), "\r\n[sqterm: %.*s (errno %d)]\r\n",
                                    static_cast<int>(error.what().size()), error.what().data(),
                                    error.system_error);
        say({line.data(), static_cast<std::size_t>(n > 0 ? n : 0)});
        say("[Process completed - press Enter]");
        complete(t);
        publish(t);
        return;
    }
    if (!t.watch(pty_.fd())) {
        say("\r\n[sqterm: cannot watch the shell]\r\n");
    }
    publish(t);
}

void Shell::receive(sq::messaging::Telegraph& t, const sq::messaging::Received& received) {
    const sq::messaging::Name to = received.telegram.address().name;
    if (to == addresses::input.name()) {
        if (completed_) {
            return;  // Enter closes the app: the widget's to do
        }
        if (publisher_.scrolled_back() != 0) {
            publisher_.scroll_back(0);  // typing goes back to the prompt
            publish(t);
        }
        static_cast<void>(pty_.write(received.data, key_wait_ms));
    } else if (to == addresses::size.name()) {
        const std::array<float, 4> wanted = received.telegram.as_floats();
        const auto clamp = [](float value) {
            return static_cast<std::uint16_t>(std::clamp(value, 2.0F, 1000.0F));
        };
        const std::uint16_t columns = clamp(wanted[0]);
        const std::uint16_t rows = clamp(wanted[1]);
        if (columns != terminal_.columns() || rows != terminal_.rows()) {
            terminal_.resize(columns, rows);
            pty_.resize(columns, rows);
            publish(t);
        }
    } else if (to == addresses::scroll.name()) {
        const std::int64_t lines = received.telegram.as_integer();
        publisher_.scroll_back(lines > 0 ? static_cast<std::size_t>(lines) : 0);
        publish(t);
    }
}

void Shell::readable(sq::messaging::Telegraph& t, int fd) {
    if (fd != pty_.fd()) {
        t.unwatch(fd);  // an old shell's: it is gone
        return;
    }
    std::size_t total = 0;
    while (total < read_per_turn) {
        const std::size_t got = pty_.read({buffer_.get(), buffer_bytes});
        if (got == 0) {
            break;
        }
        terminal_.feed(std::span<const std::byte>(buffer_.get(), got));
        total += got;
    }
    // What the terminal answers (where the cursor is, what it is) goes back.
    if (const auto replies = terminal_.replies(); !replies.empty()) {
        static_cast<void>(pty_.write(replies, key_wait_ms));
        terminal_.clear_replies();
    }
    static_cast<void>(terminal_.take_events());  // the bell, the title: 12.4
    if (pty_.closed()) {
        ended(t);
    }
    publish(t);
}

void Shell::ended(sq::messaging::Telegraph& t) {
    t.unwatch(pty_.fd());
    pty_.hang_up();  // reaps it
    const std::optional<sq::term::ProcessExit> exit = pty_.poll_exit();
    std::array<char, 96> line{};
    int n = 0;
    // Termux's words, on a line of their own.
    if (exit && exit->signal != 0) {
        n = std::snprintf(line.data(), line.size(),
                          "\r\n[Process completed (signal %d) - press Enter]", exit->signal);
    } else {
        n = std::snprintf(line.data(), line.size(),
                          "\r\n[Process completed (code %d) - press Enter]", exit ? exit->code : 0);
    }
    say({line.data(), static_cast<std::size_t>(n > 0 ? n : 0)});
    complete(t);
}

void Shell::complete(sq::messaging::Telegraph& t) {
    completed_ = true;
    if (publisher_.scrolled_back() != 0) {
        publisher_.scroll_back(0);  // the words are at the bottom
    }
    static_cast<void>(t.state(addresses::completed, true));
}

void Shell::say(std::string_view text) {
    terminal_.feed(text);
}

void Shell::publish(sq::messaging::Telegraph& t) {
    const std::span<std::byte> room =
        t.snapshot(addresses::screen, publisher_.bytes_for(terminal_));
    if (room.empty()) {
        return;
    }
    const std::size_t written = publisher_.write(terminal_, room);
    if (written != 0) {
        static_cast<void>(t.publish(addresses::screen, written));
    }
}

}  // namespace sqterm
