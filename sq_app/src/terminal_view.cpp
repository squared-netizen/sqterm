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
//
// Selecting (12.4), as Termux does: a long press selects the word under the
// finger (a long press on blank space shows Paste alone), and a drag that
// follows moves its end; two handles below the ends move either; a bar above
// it has Copy and Paste; a tap anywhere else puts it away. A handle dragged
// to the top or bottom edge scrolls, so a selection runs through the whole
// scrollback: its ends are the terminal's line numbers (ScreenView::top_line),
// and the Shell makes its text (do term.copy), which comes back as the
// snapshot term.copied for the clipboard. A paste is the clipboard's text as
// sq::term::paste_text makes it, sent in pieces the Telegraph takes.

#include "sqterm.hpp"

namespace sqterm {

namespace {

/// The glyphs' height, in logical units (720 across the shorter side): about
/// 60 columns on a phone held upright.
constexpr float font_units = 20.0F;

/// A press held this long without moving selects (Android's long press).
constexpr double long_press_seconds = 0.45;
/// How far a finger may move and still be a tap or a long press, in units.
constexpr float slop_units = 10.0F;
/// The handles: a square this big below each end; a finger this near takes it.
constexpr float handle_units = 22.0F;
constexpr float handle_reach_units = 40.0F;
/// The bar's buttons, and how far it sits from the line.
constexpr float button_width_units = 110.0F;
constexpr float button_height_units = 52.0F;
constexpr float bar_gap_units = 10.0F;
/// A handle at the edge scrolls a line this often.
constexpr double edge_scroll_seconds = 0.06;
/// The most a paste sends in one telegram (a quarter of the data ring is
/// the most a telegram can carry).
constexpr std::size_t paste_piece = 1024;

constexpr sq::graphics::Color selection_color{
    .red = 0.24F, .green = 0.50F, .blue = 0.95F, .alpha = 0.40F};
constexpr sq::graphics::Color handle_color{
    .red = 0.24F, .green = 0.55F, .blue = 0.99F, .alpha = 1.0F};
constexpr sq::graphics::Color bar_color{
    .red = 0.20F, .green = 0.20F, .blue = 0.22F, .alpha = 0.96F};
constexpr sq::graphics::Color bar_pressed_color{
    .red = 0.30F, .green = 0.30F, .blue = 0.34F, .alpha = 1.0F};
constexpr sq::graphics::Color bar_text_color{
    .red = 0.95F, .green = 0.95F, .blue = 0.95F, .alpha = 1.0F};

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

[[nodiscard]] bool inside(const sq::gui::Rectangle& r, float x, float y) noexcept {
    return r.width > 0.0F && x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

/// A cell that is part of a word: anything but a blank (a wide character's
/// second cell is its character's).
[[nodiscard]] bool word_cell(const sq::term::Cell& cell) noexcept {
    return cell.flags.wide_tail || (cell.code != U' ' && cell.code != 0);
}

}  // namespace

TerminalView::TerminalView(sq::Stage& stage, Glyphs& glyphs) noexcept
    : stage_(stage), glyphs_(glyphs) {
    // A text copied before this widget was made (a rotation makes it again)
    // is the clipboard's already.
    if (const auto copied = stage_.telegraph().snapshot(addresses::copied)) {
        copied_sequence_ = copied->sequence;
    }
}

TerminalView::~TerminalView() {
    // The Stage lets go of its widgets as the activity goes: so does the
    // glyphs' texture, which belongs to that activity's GL context.
    glyphs_.forget_texture();
}

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
    // A selection's text the Shell made: the clipboard's now.
    if (const auto copied = stage_.telegraph().snapshot(addresses::copied);
        copied && copied->sequence != copied_sequence_) {
        copied_sequence_ = copied->sequence;
        if (sq::app::ClipboardService* clipboard = stage_.clipboard()) {
            static_cast<void>(clipboard->set_text(
                {reinterpret_cast<const char*>(copied->bytes.data()), copied->bytes.size()}));
        }
    }
    send_paste();
    if (pressing_ && !moved_) {
        held_ += delta_seconds;
        if (held_ >= long_press_seconds) {
            long_press();
        }
    }
    follow_finger(delta_seconds);
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

    // The selection over the backgrounds, under the glyphs.
    if (selecting_) {
        const auto [first, last] = ends();
        const std::uint64_t top = view.top_line();
        for (std::uint16_t r = 0; r < rows; ++r) {
            const std::uint64_t line = top + r;
            if (line < first.line || line > last.line) {
                continue;
            }
            const std::uint16_t from = line == first.line ? first.column : 0;
            const std::uint16_t to =
                line == last.line ? std::min<std::uint16_t>(last.column, columns - 1) : columns - 1;
            if (to < from) {
                continue;
            }
            painter.fill_rectangle(
                {x0 + (static_cast<float>(from) * cell_w_), y0 + (static_cast<float>(r) * cell_h_),
                 static_cast<float>(to - from + 1) * cell_w_, cell_h_},
                selection_color);
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

    // 4. The handles and the bar, over everything.
    paint_selection(painter, x0, y0);
}

void TerminalView::paint_selection(sq::gui::Painter& painter, float x0, float y0) const {
    if (selecting_) {
        const auto [first, last] = ends();
        for (const bool is_first : {true, false}) {
            const auto at = handle_at(is_first ? first : last, is_first);
            if (!at) {
                continue;
            }
            const auto [hx, hy] = *at;
            // A stem from the line down to a square.
            painter.fill_rectangle({x0 + hx - 1.0F, y0 + hy - handle_units, 2.0F, handle_units},
                                   handle_color);
            painter.fill_rectangle({x0 + hx - (handle_units * 0.5F),
                                    y0 + hy - (handle_units * 0.5F), handle_units, handle_units},
                                   handle_color);
        }
    }
    if (!bar_shown_ || grabbing_) {
        return;
    }
    const Bar buttons = bar();
    const auto draw = [&](const sq::gui::Rectangle& r, std::string_view label, Button which) {
        if (r.width <= 0.0F) {
            return;
        }
        const sq::gui::Rectangle at{x0 + r.x, y0 + r.y, r.width, r.height};
        painter.fill_rectangle(at, pressed_ == which ? bar_pressed_color : bar_color);
        const sq::gui::Size size = painter.measure_text(label);
        painter.draw_text(label, at.x + ((at.width - size.width) * 0.5F),
                          at.y + ((at.height - size.height) * 0.5F), bar_text_color);
    };
    draw(buttons.copy, "Copy", Button::copy);
    draw(buttons.paste, "Paste", Button::paste);
}

bool TerminalView::pointer_event(const sq::gui::PointerEvent& event) {
    using sq::gui::PointerAction;
    switch (event.action) {
        case PointerAction::down: {
            press_x_ = event.x;
            press_y_ = event.y;
            drag_y_ = event.y;
            drag_rest_ = 0.0F;
            dragging_ = false;
            moved_ = false;
            held_ = 0.0;
            pressed_ = bar_shown_ ? button_at(event.x, event.y) : Button::none;
            if (pressed_ != Button::none) {
                return true;
            }
            // A handle: the finger takes that end, the other one stays.
            if (selecting_) {
                const auto [first, last] = ends();
                for (const bool is_first : {true, false}) {
                    const auto at = handle_at(is_first ? first : last, is_first);
                    if (at && std::hypot(event.x - at->first, event.y - at->second) <
                                  handle_reach_units) {
                        anchor_ = is_first ? last : first;
                        head_ = is_first ? first : last;
                        grabbing_ = true;
                        // The finger is below the line it moves: by as
                        // much as it is below that line's middle now.
                        const float line_middle =
                            at->second - (handle_units * 0.5F) - 2.0F - (cell_h_ * 0.5F);
                        grab_offset_ = event.y - line_middle;
                        word_held_ = false;
                        finger_x_ = event.x;
                        finger_y_ = event.y;
                        return true;
                    }
                }
            }
            pressing_ = true;
            return true;  // the Ui focuses it, which raises the keyboard
        }
        case PointerAction::move: {
            if (pressed_ != Button::none) {
                return true;
            }
            if (grabbing_) {
                finger_x_ = event.x;
                finger_y_ = event.y;
                follow_finger(0.0);
                return true;
            }
            if (std::abs(event.x - press_x_) > slop_units ||
                std::abs(event.y - press_y_) > slop_units) {
                moved_ = true;
                pressing_ = false;
            }
            if (cell_h_ <= 0.0F || !view_) {
                return true;
            }
            drag_rest_ += event.y - drag_y_;
            drag_y_ = event.y;
            if (!dragging_ && std::abs(drag_rest_) < cell_h_ * 0.5F) {
                return true;
            }
            dragging_ = true;
            moved_ = true;
            pressing_ = false;
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
        case PointerAction::cancel: {
            const bool up = event.action == PointerAction::up;
            const bool tapped = pressing_ && !moved_;
            pressing_ = false;
            dragging_ = false;
            if (pressed_ != Button::none) {
                const Button which = pressed_;
                pressed_ = Button::none;
                if (up && button_at(event.x, event.y) == which) {
                    if (which == Button::copy) {
                        copy_selection();
                    } else {
                        start_paste();
                    }
                    clear_selection();
                }
                return true;
            }
            if (grabbing_) {
                grabbing_ = false;
                bar_line_ = ends().first.line;
                bar_x_ = finger_x_;  // over where the finger left the selection
                bar_shown_ = true;   // shown again where the selection is now
                paste_only_ = false;
                return true;
            }
            if (up && tapped && (selecting_ || bar_shown_)) {
                clear_selection();  // a tap anywhere else puts it away
            }
            return true;
        }
    }
    return true;
}

sq::term::TextPoint TerminalView::point_at(float x, float y) const noexcept {
    if (!view_ || cell_w_ <= 0.0F || cell_h_ <= 0.0F) {
        return {};
    }
    const auto rows = std::min<std::uint16_t>(view_->rows(), rows_);
    const auto columns = std::min<std::uint16_t>(view_->columns(), columns_);
    const auto row = static_cast<std::uint16_t>(std::clamp(
        std::floor(y / cell_h_), 0.0F, static_cast<float>(std::max(rows, std::uint16_t{1}) - 1)));
    const auto column = static_cast<std::uint16_t>(
        std::clamp(std::floor(x / cell_w_), 0.0F,
                   static_cast<float>(std::max(columns, std::uint16_t{1}) - 1)));
    return {.line = view_->top_line() + row, .column = column};
}

std::optional<std::pair<sq::term::TextPoint, sq::term::TextPoint>> TerminalView::word_at(
    sq::term::TextPoint at) const noexcept {
    if (!view_ || at.line < view_->top_line() || at.line >= view_->top_line() + view_->rows()) {
        return std::nullopt;
    }
    const std::span<const sq::term::Cell> cells =
        view_->row(static_cast<std::uint16_t>(at.line - view_->top_line()));
    if (at.column >= cells.size() || !word_cell(cells[at.column])) {
        return std::nullopt;
    }
    std::uint16_t first = at.column;
    while (first > 0 && word_cell(cells[first - 1])) {
        --first;
    }
    std::uint16_t last = at.column;
    while (last + 1U < cells.size() && word_cell(cells[last + 1U])) {
        ++last;
    }
    return std::pair{sq::term::TextPoint{.line = at.line, .column = first},
                     sq::term::TextPoint{.line = at.line, .column = last}};
}

std::pair<sq::term::TextPoint, sq::term::TextPoint> TerminalView::ends() const noexcept {
    return head_ < anchor_ ? std::pair{head_, anchor_} : std::pair{anchor_, head_};
}

std::optional<std::pair<float, float>> TerminalView::handle_at(sq::term::TextPoint end,
                                                               bool first) const noexcept {
    if (!view_ || end.line < view_->top_line() ||
        end.line >= view_->top_line() + std::min<std::uint16_t>(view_->rows(), rows_)) {
        return std::nullopt;
    }
    const auto row = static_cast<float>(end.line - view_->top_line());
    // The first end's handle at its cell's left, the last's at its right.
    const float x = (static_cast<float>(end.column) + (first ? 0.0F : 1.0F)) * cell_w_;
    const float y = ((row + 1.0F) * cell_h_) + (handle_units * 0.5F) + 2.0F;
    return std::pair{x, y};
}

TerminalView::Bar TerminalView::bar() const noexcept {
    const float bar_width = button_width_units * (paste_only_ ? 1.0F : 2.0F);
    float y = 0.0F;
    if (view_ && bar_line_ >= view_->top_line()) {
        const auto row = static_cast<float>(bar_line_ - view_->top_line());
        y = (row * cell_h_) - button_height_units - bar_gap_units;
        if (y < 0.0F) {
            // No room above the line: below it, under the handles.
            y = ((row + 1.0F) * cell_h_) + handle_units + bar_gap_units;
        }
    }
    y = std::clamp(y, 0.0F, std::max(0.0F, height() - button_height_units));
    const float x =
        std::clamp(bar_x_ - (bar_width * 0.5F), 0.0F, std::max(0.0F, width() - bar_width));
    Bar out;
    if (paste_only_) {
        out.paste = {x, y, button_width_units, button_height_units};
    } else {
        out.copy = {x, y, button_width_units, button_height_units};
        out.paste = {x + button_width_units, y, button_width_units, button_height_units};
    }
    return out;
}

TerminalView::Button TerminalView::button_at(float x, float y) const noexcept {
    const Bar buttons = bar();
    if (inside(buttons.copy, x, y)) {
        return Button::copy;
    }
    if (inside(buttons.paste, x, y)) {
        return Button::paste;
    }
    return Button::none;
}

void TerminalView::long_press() noexcept {
    pressing_ = false;
    const sq::term::TextPoint at = point_at(press_x_, press_y_);
    if (const auto word = word_at(at)) {
        anchor_ = word->first;
        head_ = word->second;
        selecting_ = true;
        // The finger still down moves the end, as it does in Termux.
        grabbing_ = true;
        grab_offset_ = 0.0F;
        finger_x_ = press_x_;
        finger_y_ = press_y_;
        word_held_ = true;  // the word stays whole until the finger leaves it
        bar_shown_ = false;
        paste_only_ = false;
    } else {
        selecting_ = false;
        bar_line_ = at.line;
        bar_x_ = press_x_;
        bar_shown_ = true;
        paste_only_ = true;
    }
}

void TerminalView::follow_finger(double delta_seconds) noexcept {
    if (!grabbing_ || !view_ || cell_h_ <= 0.0F) {
        return;
    }
    const float y = finger_y_ - grab_offset_;
    // At the top or bottom edge: a line at a time, back or forward.
    int step = 0;
    if (y < cell_h_ * 0.5F) {
        step = 1;
    } else if (y > height() - (cell_h_ * 0.5F)) {
        step = -1;
    }
    scroll_wait_ += delta_seconds;
    if (step != 0 && scroll_wait_ >= edge_scroll_seconds) {
        scroll_wait_ = 0.0;
        const auto most = static_cast<std::int64_t>(view_->history_size());
        const std::int64_t back = std::clamp<std::int64_t>(scrolled_ + step, 0, most);
        if (back != scrolled_) {
            scrolled_ = back;
            static_cast<void>(stage_.telegraph().do_(addresses::scroll, scrolled_));
        }
    }
    // A long press's word stays whole until the finger leaves it.
    const sq::term::TextPoint at = point_at(finger_x_, y);
    if (word_held_) {
        if (at.line == anchor_.line && at.column >= anchor_.column && at.column <= head_.column) {
            return;
        }
        word_held_ = false;
    }
    head_ = at;
}

void TerminalView::clear_selection() noexcept {
    selecting_ = false;
    grabbing_ = false;
    word_held_ = false;
    bar_shown_ = false;
    paste_only_ = false;
    pressed_ = Button::none;
}

void TerminalView::copy_selection() noexcept {
    if (!selecting_) {
        return;
    }
    const auto [first, last] = ends();
    std::array<char, 96> text{};
    const int n = std::snprintf(
        text.data(), text.size(), "%llu %u %llu %u", static_cast<unsigned long long>(first.line),
        static_cast<unsigned>(first.column), static_cast<unsigned long long>(last.line),
        static_cast<unsigned>(last.column));
    if (n > 0) {
        static_cast<void>(stage_.telegraph().do_(
            addresses::copy, std::string_view(text.data(), static_cast<std::size_t>(n))));
    }
}

void TerminalView::start_paste() noexcept {
    sq::app::ClipboardService* clipboard = stage_.clipboard();
    if (clipboard == nullptr || !paste_.empty() ||
        stage_.telegraph().value(addresses::completed).value_or(false)) {
        return;
    }
    // Read whole: the size, then the text (twice more if it changed between).
    std::string text;
    for (int attempt = 0; attempt < 3; ++attempt) {
        const std::size_t size = clipboard->text({});
        text.assign(size, '\0');
        if (clipboard->text(text) == size) {
            break;
        }
        text.clear();
    }
    if (text.empty()) {
        return;
    }
    const sq::term::TerminalModes modes = view_ ? view_->modes() : sq::term::TerminalModes{};
    paste_.assign(sq::term::paste_text(text, modes, {}), '\0');
    static_cast<void>(sq::term::paste_text(text, modes, paste_));
    pasted_ = 0;
    scrolled_ = 0;  // the Shell goes back to the prompt for input
    send_paste();
}

void TerminalView::send_paste() noexcept {
    // As much as the rings take now; the rest at the next frame.
    while (pasted_ < paste_.size()) {
        const std::size_t n = std::min(paste_.size() - pasted_, paste_piece);
        const sq::messaging::DoResult sent =
            stage_.telegraph().do_(addresses::input, std::string_view(paste_).substr(pasted_, n));
        if (sent.result != sq::messaging::SendResult::sent) {
            break;
        }
        pasted_ += n;
    }
    if (!paste_.empty() && pasted_ >= paste_.size()) {
        std::string().swap(paste_);  // its memory back
        pasted_ = 0;
    }
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
    if (selecting_ || bar_shown_) {
        clear_selection();  // typing puts a selection away
    }
    static_cast<void>(stage_.telegraph().do_(addresses::input, bytes));
}

}  // namespace sqterm
