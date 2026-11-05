// sqterm: the prefix (12.5). The packages the APK carries, unpacked into the
// app's files (files/usr), where the shell and its programs run from.
//
// This file is YOURS (ownership class: seeded, sqterm's own).
//
// Two halves, on two threads:
//
//   stage_packages   the UI thread, as the app starts (squared_main): the APK's
//                    package index (assets/packages/index, written by
//                    packages/build.sh) against the one last installed
//                    (usr/var/lib/sqterm/packages). When they differ, each
//                    archive is copied out of the APK into usr/var/cache/sqterm/,
//                    a plain file the model's thread can read whatever the
//                    activity does meanwhile. Nothing to do: nothing read but
//                    the two indexes.
//   unpack_package   the model's thread (Shell::start), before the shell: one
//                    archive, a tar compressed with zstd, unpacked into the
//                    prefix. The Shell then records the index as installed and
//                    removes the copies.
//
// The reader takes what packages/build.sh writes (ustar: regular files,
// directories, symbolic and hard links; names under 255 bytes) and nothing
// that would leave the prefix (an absolute name, a "..").
//
// Memory, while it unpacks: zstd's decoder (about 100 KB) and its window
// (packages/build.sh compresses with a 1 MB window), 64 KB in and 128 KB out,
// freed when it is done. Nothing after.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "sqterm.hpp"
#include "zstd.h"

namespace sqterm {

namespace {

constexpr std::string_view index_asset = "packages/index";
constexpr std::string_view index_header = "sqterm packages 1\n";
constexpr std::string_view installed_file = "usr/var/lib/sqterm/packages";
constexpr std::string_view cache_directory = "usr/var/cache/sqterm";

/// The largest window the archives may ask for (2^21 bytes, 2 MB): what the
/// decoder allocates is bounded, whatever a damaged archive says.
constexpr int window_log_max = 21;

constexpr std::size_t in_bytes = std::size_t{64} * 1024;
constexpr std::size_t out_bytes = std::size_t{128} * 1024;

[[nodiscard]] std::string_view as_text(std::span<const std::byte> bytes) noexcept {
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
}

[[nodiscard]] std::string errno_text(std::string_view what, std::string_view path) {
    std::string out(what);
    out += ' ';
    out += path;
    out += ": ";
    out += strerror(errno);
    return out;
}

/// `path`'s parents, made as needed (0755).
[[nodiscard]] bool make_parents(std::string& path) {
    for (std::size_t slash = path.find('/', 1); slash != std::string::npos;
         slash = path.find('/', slash + 1)) {
        path[slash] = '\0';
        const bool made = mkdir(path.c_str(), 0755) == 0 || errno == EEXIST;
        path[slash] = '/';
        if (!made) {
            return false;
        }
    }
    return true;
}

/// An octal field of a tar header: digits, ended by a space or a NUL.
[[nodiscard]] std::optional<std::uint64_t> octal(std::span<const char> field) noexcept {
    std::uint64_t value = 0;
    bool digits = false;
    for (const char c : field) {
        if (c >= '0' && c <= '7') {
            value = (value * 8) + static_cast<std::uint64_t>(c - '0');
            digits = true;
        } else if (c == ' ' || c == '\0') {
            if (digits) {
                break;
            }
        } else {
            return std::nullopt;
        }
    }
    return value;
}

/// A NUL-ended (or full) field as text.
[[nodiscard]] std::string_view field_text(std::span<const char> field) noexcept {
    const auto end = std::find(field.begin(), field.end(), '\0');
    return {field.data(), static_cast<std::size_t>(end - field.begin())};
}

/// A name the archive may give: relative, no "..", no empty part.
[[nodiscard]] bool safe_name(std::string_view name) noexcept {
    if (name.empty() || name.front() == '/') {
        return false;
    }
    std::size_t start = 0;
    while (start < name.size()) {
        std::size_t end = name.find('/', start);
        if (end == std::string_view::npos) {
            end = name.size();
        }
        const std::string_view part = name.substr(start, end - start);
        if (part == ".." || (part.empty() && end != name.size())) {
            return false;
        }
        start = end + 1;
    }
    return true;
}

/// The tar reader: bytes in, files out under `root`. A header block (512
/// bytes), then the entry's data, padded to 512.
class TarWriter {
public:
    explicit TarWriter(std::string_view root) : root_(root) {}
    TarWriter(const TarWriter&) = delete;
    TarWriter& operator=(const TarWriter&) = delete;
    TarWriter(TarWriter&&) = delete;
    TarWriter& operator=(TarWriter&&) = delete;
    ~TarWriter() { close_file(); }

    /// Bytes of the archive, in order. False, with `error()`, on a fault.
    bool feed(std::span<const std::byte> bytes) {
        while (!bytes.empty() && error_.empty()) {
            if (data_left_ > 0 || pad_left_ > 0) {
                bytes = take_data(bytes);
                continue;
            }
            const std::size_t room = header_.size() - header_used_;
            const std::size_t take = std::min(room, bytes.size());
            std::memcpy(header_.data() + header_used_, bytes.data(), take);
            header_used_ += take;
            bytes = bytes.subspan(take);
            if (header_used_ == header_.size()) {
                header_used_ = 0;
                start_entry();
            }
        }
        return error_.empty();
    }

    /// The archive ended: false if it ended inside an entry.
    [[nodiscard]] bool finish() {
        if (error_.empty() && (data_left_ > 0 || header_used_ != 0)) {
            error_ = "the archive ends inside an entry";
        }
        close_file();
        return error_.empty();
    }

    [[nodiscard]] const std::string& error() const noexcept { return error_; }
    [[nodiscard]] std::size_t files() const noexcept { return files_; }

private:
    std::span<const std::byte> take_data(std::span<const std::byte> bytes) {
        if (data_left_ > 0) {
            const auto take =
                static_cast<std::size_t>(std::min<std::uint64_t>(data_left_, bytes.size()));
            if (fd_ >= 0 && !write_all(bytes.first(take))) {
                error_ = errno_text("cannot write", path_);
            }
            data_left_ -= take;
            if (data_left_ == 0) {
                close_file();
            }
            return bytes.subspan(take);
        }
        const auto take =
            static_cast<std::size_t>(std::min<std::uint64_t>(pad_left_, bytes.size()));
        pad_left_ -= take;
        return bytes.subspan(take);
    }

    [[nodiscard]] bool write_all(std::span<const std::byte> bytes) const {
        while (!bytes.empty()) {
            const ssize_t n = ::write(fd_, bytes.data(), bytes.size());
            if (n < 0) {
                if (errno == EINTR) {
                    continue;
                }
                return false;
            }
            bytes = bytes.subspan(static_cast<std::size_t>(n));
        }
        return true;
    }

    void close_file() {
        if (fd_ >= 0) {
            if (::close(fd_) != 0 && error_.empty()) {
                error_ = errno_text("cannot write", path_);
            }
            fd_ = -1;
        }
    }

    void start_entry() {
        const std::span<const char> h(header_.data(), header_.size());
        if (std::all_of(h.begin(), h.end(), [](char c) { return c == '\0'; })) {
            return;  // the two empty blocks that end an archive
        }
        // ustar: name[100] mode[8] uid gid size[12] mtime chksum type link[100]
        // "ustar" ... prefix[155] at 345.
        if (field_text(h.subspan(257, 6)).substr(0, 5) != "ustar") {
            error_ = "not a ustar archive";
            return;
        }
        std::string name(field_text(h.subspan(345, 155)));
        if (!name.empty()) {
            name += '/';
        }
        name += field_text(h.subspan(0, 100));
        while (name.size() > 1 && name.back() == '/') {
            name.pop_back();
        }
        if (name.starts_with("./")) {
            name.erase(0, 2);
        }
        const auto mode = octal(h.subspan(100, 8));
        const auto size = octal(h.subspan(124, 12));
        const char type = h[156];
        const std::string_view link = field_text(h.subspan(157, 100));
        if (!mode || !size) {
            error_ = "a damaged header";
            return;
        }
        if (name == "." || name.empty()) {
            return;
        }
        if (!safe_name(name)) {
            error_ = "a name outside the prefix: " + name;
            return;
        }
        path_ = root_ + "/" + name;
        data_left_ = (type == '0' || type == '\0') ? *size : 0;
        const std::uint64_t padded = (*size + 511) / 512 * 512;
        pad_left_ = (type == '0' || type == '\0') ? padded - *size : padded;
        if (!make_parents(path_)) {
            error_ = errno_text("cannot make the directories of", path_);
            return;
        }
        const auto permissions = static_cast<mode_t>(*mode & 07777U);
        switch (type) {
            case '0':
            case '\0':
                // Unlinked first: a running program cannot be written over
                // (ETXTBSY), and a new file takes the new mode.
                static_cast<void>(::unlink(path_.c_str()));
                fd_ = ::open(path_.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, permissions);
                if (fd_ < 0) {
                    error_ = errno_text("cannot create", path_);
                    return;
                }
                ++files_;
                if (data_left_ == 0) {
                    close_file();
                }
                return;
            case '5':
                if (::mkdir(path_.c_str(), permissions | 0700) != 0 && errno != EEXIST) {
                    error_ = errno_text("cannot make", path_);
                }
                return;
            case '2':
                static_cast<void>(::unlink(path_.c_str()));
                if (::symlink(std::string(link).c_str(), path_.c_str()) != 0) {
                    error_ = errno_text("cannot link", path_);
                }
                return;
            case '1': {
                // A hard link: a copy of the file it names (Android may
                // refuse the link itself).
                if (!safe_name(link)) {
                    error_ = "a link outside the prefix: " + std::string(link);
                    return;
                }
                const std::string from = root_ + "/" + std::string(link);
                if (!copy_file(from, path_, permissions)) {
                    error_ = errno_text("cannot copy to", path_);
                }
                return;
            }
            default:
                return;  // anything else (a device, a fifo) is not unpacked
        }
    }

    [[nodiscard]] static bool copy_file(const std::string& from, const std::string& to,
                                        mode_t permissions) {
        const int in = ::open(from.c_str(), O_RDONLY | O_CLOEXEC);
        if (in < 0) {
            return false;
        }
        static_cast<void>(::unlink(to.c_str()));
        const int out = ::open(to.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, permissions);
        bool ok = out >= 0;
        std::array<char, 16384> buffer{};
        while (ok) {
            const ssize_t n = ::read(in, buffer.data(), buffer.size());
            if (n == 0) {
                break;
            }
            ok = n > 0 && ::write(out, buffer.data(), static_cast<std::size_t>(n)) == n;
        }
        ::close(in);
        if (out >= 0) {
            ok = ::close(out) == 0 && ok;
        }
        return ok;
    }

    std::string root_;
    std::string path_;
    std::array<char, 512> header_{};
    std::size_t header_used_ = 0;
    std::uint64_t data_left_ = 0;
    std::uint64_t pad_left_ = 0;
    std::size_t files_ = 0;
    int fd_ = -1;
    std::string error_;
};

}  // namespace

void stage_packages(sq::files::FileSystem& files, Places& places) {
    using sq::files::FileType;
    places.staged.clear();
    places.index.clear();
    const sq::files::FileReadResult index = files.read(FileType::Internal, index_asset);
    if (!index) {
        return;  // a build with no packages (packages/build.sh was not run)
    }
    const std::string_view text = as_text(index.bytes);
    if (!text.starts_with(index_header)) {
        std::fprintf(stderr, "sqterm: %.*s is not a package index\n",
                     static_cast<int>(index_asset.size()), index_asset.data());
        return;
    }
    if (const sq::files::FileReadResult installed = files.read(FileType::Local, installed_file);
        installed && as_text(installed.bytes) == text) {
        return;  // installed already: nothing copied
    }
    static_cast<void>(files.make_directories(FileType::Local, cache_directory));
    // Each line after the first: "name version file sha".
    std::size_t at = index_header.size();
    while (at < text.size()) {
        std::size_t end = text.find('\n', at);
        if (end == std::string_view::npos) {
            end = text.size();
        }
        const std::string_view line = text.substr(at, end - at);
        at = end + 1;
        std::array<std::string_view, 4> word{};
        std::size_t words = 0;
        for (std::size_t from = 0; from < line.size() && words < word.size();) {
            const std::size_t space = std::min(line.find(' ', from), line.size());
            word[words++] = line.substr(from, space - from);
            from = space + 1;
        }
        if (words < 3) {
            continue;
        }
        const std::string asset = "packages/" + std::string(word[2]);
        const std::string copy = std::string(cache_directory) + "/" + std::string(word[2]);
        // Stored uncompressed in the APK (SQ_STORED has zst): mapped, then written out.
        sq::files::MapResult mapped = files.map(FileType::Internal, asset);
        sq::files::FileError wrote;
        if (mapped) {
            wrote = files.write(FileType::Local, copy, mapped.file.bytes(), false);
        } else {
            const sq::files::FileReadResult read = files.read(FileType::Internal, asset);
            if (!read) {
                std::fprintf(stderr, "sqterm: %s is not in the APK\n", asset.c_str());
                continue;
            }
            wrote = files.write(FileType::Local, copy, read.bytes, false);
        }
        if (wrote) {
            std::fprintf(stderr, "sqterm: cannot copy %s: %s\n", asset.c_str(),
                         wrote.message.c_str());
            continue;
        }
        places.staged.push_back({.name = std::string(word[0]) + " " + std::string(word[1]),
                                 .archive = files.resolve_platform_path(FileType::Local, copy)});
    }
    places.index = std::string(text);
    places.installed = files.resolve_platform_path(FileType::Local, installed_file);
}

std::string unpack_package(std::string_view archive, std::string_view prefix) {
    const std::string path(archive);
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return errno_text("cannot open", path);
    }
    ZSTD_DStream* stream = ZSTD_createDStream();
    if (stream == nullptr) {
        ::close(fd);
        return "no memory for the decoder";
    }
    static_cast<void>(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, window_log_max));
    const auto in_buffer = std::make_unique_for_overwrite<std::byte[]>(in_bytes);
    const auto out_buffer = std::make_unique_for_overwrite<std::byte[]>(out_bytes);
    TarWriter tar(prefix);
    std::string error;
    std::size_t last = 1;  // what the decoder said it wants: 0 at a frame's end
    for (;;) {
        const ssize_t got = ::read(fd, in_buffer.get(), in_bytes);
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = errno_text("cannot read", path);
            break;
        }
        if (got == 0) {
            if (last != 0) {
                error = "the archive is cut short";
            }
            break;
        }
        ZSTD_inBuffer in{in_buffer.get(), static_cast<std::size_t>(got), 0};
        // Until the input is used and the output did not fill: a full
        // output may mean more is waiting in the decoder.
        bool full = true;
        while (error.empty() && (in.pos < in.size || full)) {
            ZSTD_outBuffer out{out_buffer.get(), out_bytes, 0};
            last = ZSTD_decompressStream(stream, &out, &in);
            if (ZSTD_isError(last) != 0U) {
                error = "the archive is damaged (zstd error " +
                        std::to_string(static_cast<int>(ZSTD_getErrorCode(last))) + ")";
                break;
            }
            full = out.pos == out_bytes;
            if (!tar.feed({out_buffer.get(), out.pos})) {
                error = tar.error();
            }
        }
        if (!error.empty()) {
            break;
        }
    }
    ZSTD_freeDStream(stream);
    ::close(fd);
    if (!tar.finish() && error.empty()) {
        error = tar.error();
    }
    return error;
}

bool record_installed(const Places& places) {
    if (places.installed.empty()) {
        return false;
    }
    std::string path = places.installed;
    if (!make_parents(path)) {
        return false;
    }
    const std::string fresh = path + ".new";
    const int fd = ::open(fresh.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        return false;
    }
    const bool wrote = ::write(fd, places.index.data(), places.index.size()) ==
                       static_cast<ssize_t>(places.index.size());
    const bool closed = ::close(fd) == 0;
    return wrote && closed && ::rename(fresh.c_str(), path.c_str()) == 0;
}

}  // namespace sqterm
