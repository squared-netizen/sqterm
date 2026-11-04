// sqterm: what its files share. A terminal for Android, on squared.
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// Two halves, one on each end of the Telegraph:
//
//   Shell         the model, on its own thread: the shell in a pty, its
//                 output fed to a Terminal, the screen published as a
//                 snapshot; keys and the size come in as telegrams.
//   TerminalView  the widget, on the UI thread: the newest screen drawn
//                 from one glyph texture; what is typed sent to the Shell;
//                 a selection (long press, two handles, a Copy and Paste
//                 bar), its text made by the Shell, the clipboard's pasted.
//   Glyphs        the fonts (mapped from the APK), the glyph atlas and its
//                 texture: one for the process, kept while windows come
//                 and go.

#pragma once

import squared;
import sq.files;
import sq.font;
import sq.graphics;
import sq.term;

namespace sqterm {

/// The addresses between the two ends, written by hand (no names.json).
namespace addresses {

/// Bytes for the shell: what was typed, a key's sequence.
inline constexpr sq::messaging::Key<std::string_view, sq::messaging::do_> input{"term.input"};
/// The grid that fits the widget: (columns, rows).
inline constexpr sq::messaging::Key<std::array<float, 2>, sq::messaging::do_> size{"term.size"};
/// How far back into the scrollback to show: lines, 0 for the screen.
inline constexpr sq::messaging::Key<std::int64_t, sq::messaging::do_> scroll{"term.scroll"};
/// The screen, as sq::term::ScreenPublisher writes it.
inline constexpr sq::messaging::SnapshotKey screen{"term.screen"};
/// The shell has ended: Enter now closes sqterm.
inline constexpr sq::messaging::Key<bool, sq::messaging::state> completed{"term.completed"};
/// A selection's text, asked for: "from_line from_column to_line to_column"
/// (sq::term::TextPoint's, decimal), either way round.
inline constexpr sq::messaging::Key<std::string_view, sq::messaging::do_> copy{"term.copy"};
/// That text, UTF-8, as Terminal::copy_text makes it: for the clipboard.
inline constexpr sq::messaging::SnapshotKey copied{"term.copied"};

}  // namespace addresses

/// Where the shell runs: given by squared_main, from the app's private files.
struct Places {
    std::string home;  ///< $HOME and where the shell starts
    std::string tmp;   ///< $TMPDIR
};

/// The model: the shell in a pty, on the model's thread.
class Shell final {
public:
    explicit Shell(Places places);
    ~Shell();
    Shell(const Shell&) = delete;
    Shell& operator=(const Shell&) = delete;
    Shell(Shell&&) = delete;
    Shell& operator=(Shell&&) = delete;

    void start(sq::messaging::Telegraph& t);
    void receive(sq::messaging::Telegraph& t, const sq::messaging::Received& received);
    void readable(sq::messaging::Telegraph& t, int fd);

private:
    void spawn(sq::messaging::Telegraph& t);
    void ended(sq::messaging::Telegraph& t);
    void complete(sq::messaging::Telegraph& t);
    void copy(sq::messaging::Telegraph& t, std::span<const std::byte> asked);
    void publish(sq::messaging::Telegraph& t);
    void say(std::string_view text);

    Places places_;
    std::array<std::string, 8> environment_text_;
    std::array<std::string_view, 8> environment_{};
    std::size_t environment_count_ = 0;
    sq::term::Terminal terminal_;
    sq::term::Pty pty_;
    sq::term::ScreenPublisher publisher_;
    std::unique_ptr<std::byte[]> buffer_;
    /// The shell has ended (or never started): what is typed is dropped.
    bool completed_ = false;
};

/// The fonts, the atlas and its texture. UI thread only.
class Glyphs final {
public:
    Glyphs() = default;
    Glyphs(const Glyphs&) = delete;
    Glyphs& operator=(const Glyphs&) = delete;
    Glyphs(Glyphs&&) = delete;
    Glyphs& operator=(Glyphs&&) = delete;

    /// Ready to draw glyphs `pixels` high: the fonts mapped and opened the
    /// first time, the size set (the atlas started again when it changes).
    /// False, and said once, when the bundled font is missing.
    bool prepare(sq::files::FileSystem& files, std::uint16_t pixels);

    [[nodiscard]] bool ready() const noexcept { return opened_ && pixels_ != 0; }
    /// The bundled font did not open: the widget says so instead of drawing.
    [[nodiscard]] bool failed() const noexcept { return failed_; }
    [[nodiscard]] sq::font::FontMetrics metrics() const noexcept { return fonts_.metrics(); }

    /// Where `code` is in the atlas, rendered now if it was not.
    [[nodiscard]] std::optional<sq::font::AtlasGlyph> glyph(char32_t code,
                                                            sq::font::GlyphStyle style) noexcept;

    /// Moves on when the atlas starts again: every glyph looked up before is stale.
    [[nodiscard]] std::uint32_t generation() const noexcept { return atlas_.generation(); }

    /// What the atlas drew since the last call, into the texture (made the
    /// first time, or whole again after the atlas started again).
    void upload() noexcept;

    [[nodiscard]] const sq::graphics::Texture& texture() const noexcept { return texture_; }

    /// The Stage's surface hook: the texture back after Android took the surface.
    static void restore(void* context, sq::graphics::Context& graphics) noexcept;

private:
    static bool regenerate(void* context, sq::graphics::TextureRecoveryTarget& target) noexcept;

    sq::files::MappedFile regular_file_;
    sq::files::MappedFile bold_file_;
    sq::font::FontSet fonts_;
    sq::font::GlyphAtlas atlas_{1024, 1024, 2048};
    sq::graphics::Texture texture_;
    std::uint32_t uploaded_generation_ = 0;
    std::uint16_t pixels_ = 0;
    bool opened_ = false;
    bool failed_ = false;
};

/// The process's glyphs, made on first use (on the UI thread).
Glyphs& glyphs();

/// The terminal widget: the newest screen, drawn; what is typed, sent.
class TerminalView final : public sq::gui::Widget {
public:
    TerminalView(sq::Stage& stage, Glyphs& glyphs) noexcept;

    [[nodiscard]] sq::gui::Size preferred_size(sq::gui::Painter& painter,
                                               const sq::gui::Skin& skin) const override;
    void act(double delta_seconds) override;
    void paint(sq::gui::Painter& painter, const sq::gui::Skin& skin, float stage_x,
               float stage_y) const override;

    bool pointer_event(const sq::gui::PointerEvent& event) override;
    bool key_down(sq::app::Key key, sq::app::KeyModifiers modifiers) override;
    bool text_input(std::string_view text) override;
    bool key_text(std::string_view text, sq::app::KeyModifiers modifiers) override;
    [[nodiscard]] bool focusable() const noexcept override { return true; }
    [[nodiscard]] bool wants_text_input() const noexcept override { return true; }

protected:
    void input_event(sq::gui::InputEvent& event) override;

private:
    /// The Copy and Paste bar's buttons, in the widget's units.
    struct Bar {
        sq::gui::Rectangle copy{};  ///< empty with Paste alone
        sq::gui::Rectangle paste{};
    };
    enum class Button : std::uint8_t { none, copy, paste };

    void fit() noexcept;
    void send(std::string_view bytes) noexcept;

    // The selection (12.4).
    [[nodiscard]] sq::term::TextPoint point_at(float x, float y) const noexcept;
    [[nodiscard]] std::optional<std::pair<sq::term::TextPoint, sq::term::TextPoint>> word_at(
        sq::term::TextPoint at) const noexcept;
    /// The selection's two ends, the first one first.
    [[nodiscard]] std::pair<sq::term::TextPoint, sq::term::TextPoint> ends() const noexcept;
    /// Where a handle hangs, below its end's cell; nothing when off screen.
    [[nodiscard]] std::optional<std::pair<float, float>> handle_at(sq::term::TextPoint end,
                                                                   bool first) const noexcept;
    [[nodiscard]] Bar bar() const noexcept;
    [[nodiscard]] Button button_at(float x, float y) const noexcept;
    void long_press() noexcept;
    void clear_selection() noexcept;
    void copy_selection() noexcept;
    void start_paste() noexcept;
    void send_paste() noexcept;
    void follow_finger(double delta_seconds) noexcept;
    void paint_selection(sq::gui::Painter& painter, float x0, float y0) const;

    sq::Stage& stage_;
    Glyphs& glyphs_;
    std::optional<sq::term::ScreenView> view_;
    std::uint64_t sequence_ = 0;
    std::uint64_t copied_sequence_ = 0;  ///< the last copied text given to the clipboard
    /// A paste being sent, in pieces the Telegraph takes (empty: none).
    std::string paste_;
    std::size_t pasted_ = 0;
    sq::term::TextPoint anchor_{};  ///< the selection's end that stays
    sq::term::TextPoint head_{};    ///< the end a finger moves
    std::uint64_t bar_line_ = 0;    ///< the line the bar sits by
    /// Where the bar is centred: set when it is shown, never by a later
    /// touch (a tap on the bar must not move it under the finger).
    float bar_x_ = 0.0F;
    float press_x_ = 0.0F;  ///< where the finger went down
    float press_y_ = 0.0F;
    float finger_x_ = 0.0F;  ///< where it is, moving a handle
    float finger_y_ = 0.0F;
    float grab_offset_ = 0.0F;  ///< a handle's finger is this far below its line
    double held_ = 0.0;         ///< seconds down without moving
    double scroll_wait_ = 0.0;  ///< seconds since a handle at the edge scrolled
    Button pressed_ = Button::none;
    bool pressing_ = false;    ///< down, not moved: may become a long press
    bool moved_ = false;       ///< moved past a tap
    bool selecting_ = false;   ///< a selection is shown
    bool grabbing_ = false;    ///< a finger moves the head
    bool word_held_ = false;   ///< a long press's word, kept whole while the finger is on it
    bool bar_shown_ = false;   ///< the bar is shown
    bool paste_only_ = false;  ///< with Paste alone
    float scale_ = 0.0F;       ///< pixels to a logical unit
    float cell_w_ = 0.0F;      ///< a cell, in logical units
    float cell_h_ = 0.0F;
    std::uint16_t columns_ = 0;  ///< the grid asked of the Shell
    std::uint16_t rows_ = 0;
    float drag_y_ = 0.0F;        ///< where a drag last was, for scrolling back
    float drag_rest_ = 0.0F;     ///< part of a line dragged, not yet scrolled
    std::int64_t scrolled_ = 0;  ///< lines back, as asked
    bool dragging_ = false;
};

/// The one screen: the terminal, filling it.
struct Screen {
    static constexpr std::string_view name = "terminal";
    static void build(sq::gui::LayoutWriter& root);
};

/// The custom node's maker (Stage::custom).
std::unique_ptr<sq::gui::Widget> make_terminal(sq::Stage& stage);

/// Close sqterm, as Termux does after its last session: the model stops
/// (the shell with it) and Android closes the activity; the next launch
/// starts afresh. The App is the one squared_main was given.
void quit_app() noexcept;

}  // namespace sqterm
