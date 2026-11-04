// sqterm: the fonts, the glyph atlas and its texture.
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// JetBrains Mono NL (the family without ligatures: a terminal draws one cell
// at a time), regular and bold, bundled in the APK and mapped from it, not
// read into memory: FreeType reads the pages it needs, and Android may drop
// them. What they lack (CJK, symbols) comes from Android's own fonts. Glyphs
// are rendered once, as they first appear, into one 1024 x 1024 coverage
// image, and the texture takes only the rectangle that changed.

#include <stdio.h>

#include "sqterm.hpp"

namespace sqterm {

namespace {

constexpr std::string_view regular_path = "fonts/JetBrainsMonoNL-Regular.ttf";
constexpr std::string_view bold_path = "fonts/JetBrainsMonoNL-Bold.ttf";

}  // namespace

Glyphs& glyphs() {
    static Glyphs one;
    return one;
}

bool Glyphs::prepare(sq::files::FileSystem& files, std::uint16_t pixels) {
    if (failed_ || pixels == 0) {
        return false;
    }
    if (!opened_) {
        sq::files::MapResult regular = files.map(sq::files::FileType::Internal, regular_path);
        sq::font::Face face;
        sq::font::FaceError error;
        if (regular) {
            error = face.open_memory(regular.file.bytes());
        }
        if (!regular || error || fonts_.add(std::move(face))) {
            std::fprintf(stderr, "sqterm: %.*s does not open\n",
                         static_cast<int>(regular_path.size()), regular_path.data());
            failed_ = true;
            return false;
        }
        regular_file_ = std::move(regular.file);
        sq::files::MapResult bold = files.map(sq::files::FileType::Internal, bold_path);
        sq::font::Face bold_face;
        if (bold && !bold_face.open_memory(bold.file.bytes()) &&
            !fonts_.set_bold(std::move(bold_face))) {
            bold_file_ = std::move(bold.file);  // else bold is made by emboldening
        }
        static_cast<void>(fonts_.add_system_fallbacks());
        opened_ = true;
    }
    if (pixels != pixels_) {
        if (fonts_.set_pixel_size(pixels)) {
            return false;
        }
        pixels_ = pixels;
        atlas_.clear();  // the old size's glyphs: the generation moves, all upload again
    }
    return true;
}

std::optional<sq::font::AtlasGlyph> Glyphs::glyph(char32_t code,
                                                  sq::font::GlyphStyle style) noexcept {
    return atlas_.glyph(fonts_, code, style);
}

void Glyphs::upload() noexcept {
    const std::span<const std::uint8_t> image = atlas_.pixels();
    const int width = atlas_.width();
    if (!texture_.has_content() || uploaded_generation_ != atlas_.generation()) {
        const bool made = texture_.create_alpha(
            width, atlas_.height(), image.data(),
            sq::graphics::TextureRecoveryOptions::regenerate(&Glyphs::regenerate, this));
        if (made) {
            // Linear: a glyph lands on whole pixels, but a scale that is not
            // a whole number of pixels to a unit is filtered, not cut.
            texture_.set_filter(sq::graphics::TextureFilter::Linear,
                                sq::graphics::TextureFilter::Linear);
            uploaded_generation_ = atlas_.generation();
            atlas_.clear_dirty();
        }
        return;
    }
    const sq::font::GlyphAtlas::Rect dirty = atlas_.dirty();
    if (dirty.empty()) {
        return;
    }
    const std::size_t first = (std::size_t{dirty.y} * static_cast<std::size_t>(width)) + dirty.x;
    if (texture_.update(dirty.x, dirty.y, dirty.width, dirty.height, image.data() + first, width)) {
        atlas_.clear_dirty();
    }
}

bool Glyphs::regenerate(void* context, sq::graphics::TextureRecoveryTarget& target) noexcept {
    const auto& self = *static_cast<const Glyphs*>(context);
    return target.upload_alpha(self.atlas_.width(), self.atlas_.height(),
                               self.atlas_.pixels().data());
}

void Glyphs::forget_texture() noexcept {
    texture_.invalidate();
    uploaded_generation_ = 0;  // made whole again at the next upload
}

void Glyphs::restore(void* context, sq::graphics::Context& graphics) noexcept {
    auto& self = *static_cast<Glyphs*>(context);
    if (self.texture_.restorable()) {
        static_cast<void>(self.texture_.restore(graphics));
    }
}

}  // namespace sqterm
