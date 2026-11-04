// sqterm: the terminal widget, on the UI thread.
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// Each frame it takes the newest screen the Shell published (a snapshot: the
// UI never waits and never sees half a screen), makes sure every glyph on it
// is in the atlas, uploads what the atlas drew, and paints: the backgrounds
// first, then the glyphs, then underlines, so the painter's batch changes
// texture twice a frame, not twice a cell. What is typed goes to the Shell
// as the bytes a program reads (sq::term::key_bytes); a vertical drag
// scrolls back into the scrollback. Once the shell has ended
// (term.completed), Enter closes sqterm and nothing else is sent.

#include "sqterm.hpp"

namespace sqterm {

namespace {

/// The glyphs' height, in logical units (720 across the shorter side): about
/// 60 columns on a phone held upright.
constexpr float font_units = 20.0F;

constexpr sq::graphics::Color default_foreground{
    .red = 0.86F, .green = 0.86F, .blue = 0.84F, .alpha = 1.0F};
constexpr sq::graphics::Color default_background{
    .red = 0.07F, .green = 0.07F, .blue = 0.08F, .alpha = 1.0F};

[[nodiscard]] sq::graphics::Color color_of(sq::term::Rgb rgb) noexcept {
    constexpr float unit = 1.0F / 255.0F;
    return {.red = static_cast<float>(rgb.r) * unit,
            .green = static_cast<float>(rgb.g) * unit,
            .blue = static_cast<float>(rgb.b) * unit,
            .alpha = 1.0F};
}

[[nodiscard]] sq::graphics::Color mix(sq::graphics::Color a, sq::graphics::Color b,
                                      float t) noexcept {
    return {.red = a.red + ((b.red - a.red) * t),
            .green = a.green + ((b.green - a.green) * t),
            .blue = a.blue + ((b.blue - a.blue) * t),
            .alpha = 1.0F};
}

/// A cell's colours as drawn: the theme's for the defaults, swapped for
/// inverse (and for the cursor's cell), faint halfway to the background,
/// concealed as the background.
struct Colors {
    sq::graphics::Color foreground;
    sq::graphics::Color background;
    bool default_background = true;
};

[[nodiscard]] Colors colors_of(const sq::term::Cell& cell, bool cursor) noexcept {
    Colors out{
        .foreground =
            cell.flags.default_foreground ? default_foreground : color_of(cell.foreground),
        .background =
            cell.flags.default_background ? default_background : color_of(cell.background),
        .default_background = cell.flags.default_background,
    };
    if (cell.attributes.inverse != cursor) {
        std::swap(out.foreground, out.background);
        out.default_background = false;
    }
    if (cell.attributes.faint) {
        out.foreground = mix(out.foreground, out.background, 0.5F);
    }
    if (cell.attributes.conceal) {
        out.foreground = out.background;
    }
    return out;
}

[[nodiscard]] bool drawn(const sq::term::Cell& cell) noexcept {
    return !cell.flags.wide_tail && cell.code > U' ' && !cell.attributes.conceal;
}

[[nodiscard]] sq::font::GlyphStyle style_of(const sq::term::Cell& cell) noexcept {
    return {.bold = cell.attributes.bold, .italic = cell.attributes.italic};
}

/// To whole pixels, in units.
[[nodiscard]] float snap(float units, float scale) noexcept {
    return std::round(units * scale) / scale;
}

}  // namespace

TerminalView::TerminalView(sq::Stage& stage, Glyphs& glyphs) noexcept
    : stage_(stage), glyphs_(glyphs) {}

sq::gui::Size TerminalView::preferred_size(sq::gui::Painter& /*painter*/,
                                           const sq::gui::Skin& /*skin*/) const {
    return {320.0F, 240.0F};  // it grows to fill the screen
}

void TerminalView::fit() noexcept {
    const float scale = stage_.pixels_per_unit();
    sq::files::FileSystem* files = stage_.files();
    if (scale <= 0.0F || files == nullptr) {
        return;
    }
    if (scale != scale_) {
        const auto pixels = static_cast<std::uint16_t>(std::lround(font_units * scale));
        if (!glyphs_.prepare(*files, pixels)) {
            return;
        }
        scale_ = scale;
        const sq::font::FontMetrics metrics = glyphs_.metrics();
        cell_w_ = static_cast<float>(metrics.cell_width) / scale;
        cell_h_ = static_cast<float>(metrics.cell_height) / scale;
    }
    if (cell_w_ <= 0.0F || cell_h_ <= 0.0F) {
        return;
    }
    const auto columns = static_cast<std::uint16_t>(std::max(2.0F, width() / cell_w_));
    const auto rows = static_cast<std::uint16_t>(std::max(2.0F, height() / cell_h_));
    if (columns != columns_ || rows != rows_) {
        columns_ = columns;
        rows_ = rows;
        const std::array<float, 2> grid{static_cast<float>(columns), static_cast<float>(rows)};
        static_cast<void>(stage_.telegraph().do_(addresses::size, grid));
    }
}

void TerminalView::act(double delta_seconds) {
    sq::gui::Widget::act(delta_seconds);
    fit();
    if (const auto shot = stage_.telegraph().snapshot(addresses::screen)) {
        if (shot->sequence != sequence_ || !view_) {
            view_ = sq::term::ScreenView::read(shot->bytes);
            sequence_ = shot->sequence;
        }
    }
    if (!view_ || !glyphs_.ready()) {
        return;
    }
    // Every glyph on the screen in the atlas before it is drawn; again, once,
    // if the atlas filled and started over part way.
    for (int pass = 0; pass < 2; ++pass) {
        const std::uint32_t generation = glyphs_.generation();
        for (std::uint16_t r = 0; r < view_->rows(); ++r) {
            for (const sq::term::Cell& cell : view_->row(r)) {
                if (drawn(cell)) {
                    static_cast<void>(glyphs_.glyph(cell.code, style_of(cell)));
                }
            }
        }
        if (glyphs_.generation() == generation) {
            break;
        }
    }
    glyphs_.upload();
}

void TerminalView::paint(sq::gui::Painter& painter, const sq::gui::Skin& /*skin*/, float stage_x,
                         float stage_y) const {
    painter.fill_rectangle({stage_x, stage_y, width(), height()}, default_background);
    if (glyphs_.failed()) {
        painter.draw_text("sqterm: the bundled font does not open (assets/fonts/)", stage_x + 8.0F,
                          stage_y + 8.0F, default_foreground);
        return;
    }
    if (!view_ || !glyphs_.ready() || scale_ <= 0.0F || !glyphs_.texture().has_content()) {
        return;
    }
    const sq::term::ScreenView& view = *view_;
    const float x0 = snap(stage_x, scale_);
    const float y0 = snap(stage_y, scale_);
    const auto rows = std::min<std::uint16_t>(view.rows(), rows_);
    const auto columns = std::min<std::uint16_t>(view.columns(), columns_);
    const bool show_cursor = view.cursor_shown();
    const sq::term::Cursor cursor = view.cursor();
    const auto is_cursor = [&](std::uint16_t c, std::uint16_t r) {
        return show_cursor && c == cursor.column && r == cursor.row;
    };

    // 1. Backgrounds, a run of one colour at a time.
    for (std::uint16_t r = 0; r < rows; ++r) {
        const std::span<const sq::term::Cell> line = view.row(r);
        const float y = y0 + (static_cast<float>(r) * cell_h_);
        std::uint16_t c = 0;
        while (c < columns) {
            const Colors first = colors_of(line[c], is_cursor(c, r));
            std::uint16_t end = c + 1;
            while (end < columns) {
                const Colors next = colors_of(line[end], is_cursor(end, r));
                if (next.default_background != first.default_background ||
                    next.background.red != first.background.red ||
                    next.background.green != first.background.green ||
                    next.background.blue != first.background.blue) {
                    break;
                }
                ++end;
            }
            if (!first.default_background) {
                const float x = x0 + (static_cast<float>(c) * cell_w_);
                painter.fill_rectangle({x, y, static_cast<float>(end - c) * cell_w_, cell_h_},
                                       first.background);
            }
            c = end;
        }
    }

    // 2. Glyphs, from the atlas.
    const sq::font::FontMetrics metrics = glyphs_.metrics();
    const sq::graphics::Texture& texture = glyphs_.texture();
    for (std::uint16_t r = 0; r < rows; ++r) {
        const std::span<const sq::term::Cell> line = view.row(r);
        const float y = y0 + (static_cast<float>(r) * cell_h_);
        for (std::uint16_t c = 0; c < columns; ++c) {
            const sq::term::Cell& cell = line[c];
            if (!drawn(cell)) {
                continue;
            }
            const std::optional<sq::font::AtlasGlyph> glyph =
                glyphs_.glyph(cell.code, style_of(cell));
            if (!glyph || glyph->width == 0 || glyph->height == 0) {
                continue;
            }
            const sq::graphics::TextureRegion region(texture, glyph->x, glyph->y, glyph->width,
                                                     glyph->height, false);
            const float x = x0 + (static_cast<float>(c) * cell_w_);
            const sq::gui::Rectangle at{
                x + (static_cast<float>(glyph->left) / scale_),
                y + (static_cast<float>(metrics.ascender - glyph->top) / scale_),
                static_cast<float>(glyph->width) / scale_,
                static_cast<float>(glyph->height) / scale_,
            };
            painter.draw_region(region, at, colors_of(cell, is_cursor(c, r)).foreground);
        }
    }

    // 3. Underlines and lines through.
    const float thickness =
        std::max(1.0F, static_cast<float>(metrics.underline_thickness)) / scale_;
    const float under = static_cast<float>(metrics.ascender - metrics.underline_position) / scale_;
    for (std::uint16_t r = 0; r < rows; ++r) {
        const std::span<const sq::term::Cell> line = view.row(r);
        const float y = y0 + (static_cast<float>(r) * cell_h_);
        for (std::uint16_t c = 0; c < columns; ++c) {
            const sq::term::Cell& cell = line[c];
            if (!cell.attributes.underline && !cell.attributes.crossed_out) {
                continue;
            }
            const float x = x0 + (static_cast<float>(c) * cell_w_);
            const sq::graphics::Color ink = colors_of(cell, is_cursor(c, r)).foreground;
            if (cell.attributes.underline) {
                painter.fill_rectangle(
                    {x, y + std::min(under, cell_h_ - thickness), cell_w_, thickness}, ink);
            }
            if (cell.attributes.crossed_out) {
                painter.fill_rectangle({x, y + (cell_h_ * 0.5F), cell_w_, thickness}, ink);
            }
        }
    }
}

bool TerminalView::pointer_event(const sq::gui::PointerEvent& event) {
    using sq::gui::PointerAction;
    switch (event.action) {
        case PointerAction::down:
            drag_y_ = event.y;
            drag_rest_ = 0.0F;
            dragging_ = false;
            return true;  // the Ui focuses it, which raises the keyboard
        case PointerAction::move: {
            if (cell_h_ <= 0.0F || !view_) {
                return true;
            }
            drag_rest_ += event.y - drag_y_;
            drag_y_ = event.y;
            if (!dragging_ && std::abs(drag_rest_) < cell_h_ * 0.5F) {
                return true;
            }
            dragging_ = true;
            const auto lines = static_cast<std::int64_t>(drag_rest_ / cell_h_);
            if (lines != 0) {
                drag_rest_ -= static_cast<float>(lines) * cell_h_;
                const auto most = static_cast<std::int64_t>(view_->history_size());
                const std::int64_t back = std::clamp<std::int64_t>(scrolled_ + lines, 0, most);
                if (back != scrolled_) {
                    scrolled_ = back;
                    static_cast<void>(stage_.telegraph().do_(addresses::scroll, scrolled_));
                }
            }
            return true;
        }
        case PointerAction::up:
        case PointerAction::cancel:
            dragging_ = false;
            return true;
    }
    return true;
}

bool TerminalView::key_down(sq::app::Key key, sq::app::KeyModifiers modifiers) {
    const sq::term::TerminalModes modes = view_ ? view_->modes() : sq::term::TerminalModes{};
    const sq::term::KeyBytes bytes = sq::term::key_bytes(key, modifiers, modes);
    if (bytes.empty()) {
        return false;
    }
    send(bytes.view());
    return true;
}

bool TerminalView::text_input(std::string_view text) {
    if (text.empty()) {
        return false;
    }
    send(text);
    return true;
}

bool TerminalView::key_text(std::string_view text, sq::app::KeyModifiers modifiers) {
    const sq::term::KeyBytes bytes = sq::term::key_text_bytes(text, modifiers);
    if (bytes.empty()) {
        return false;
    }
    send(bytes.view());
    return true;
}

void TerminalView::input_event(sq::gui::InputEvent& event) {
    // A key arrives as itself (key_down) and as a navigation: the second is
    // the terminal's too, or Tab and the arrows would move the focus away.
    if (event.type == sq::gui::InputType::navigation) {
        event.handle();
        event.stop();
        return;
    }
    sq::gui::Widget::input_event(event);
}

void TerminalView::send(std::string_view bytes) noexcept {
    if (stage_.telegraph().value(addresses::completed).value_or(false)) {
        // The shell has ended: Enter closes sqterm, the rest is dropped.
        if (bytes.find_first_of("\r\n") != std::string_view::npos) {
            quit_app();
        }
        return;
    }
    if (scrolled_ != 0) {
        scrolled_ = 0;  // the Shell goes back to the prompt for a key
    }
    static_cast<void>(stage_.telegraph().do_(addresses::input, bytes));
}

}  // namespace sqterm
