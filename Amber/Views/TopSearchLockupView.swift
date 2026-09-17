import SwiftUI

// MARK: - 热门搜索结果卡片网格（TopSearchLockup 复刻）

/// 「热门搜索结果」分区（TopSearchLockupComponentItem，框架层规格 §2）。
/// Music 实测：一行 4 张横向卡片（~278×77、圆角 10），艺人卡打头（尾标 chevron），
/// 歌曲卡随后（尾标 ellipsis 菜单）。宽度断点 740/1000/1320/1680（[实测]）映射为列数阶梯。
enum TopResultsItem: Identifiable {
    case artist(Artist)
    case track(Track)

    var id: String {
        switch self {
        case .artist(let artist): return "artist-\(artist.id)"
        case .track(let track): return "track-\(track.id)"
        }
    }
}

struct TopResultsCardGrid: View {
    let items: [TopResultsItem]

    var body: some View {
        // [实测] 宽度断点 740/1000/1320/1680 的列数阶梯，用自适应网格等价实现：
        // 1175pt 内容宽落在 4 列档（Music 实测同为 4 列），窄窗依次 3/2 列。
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 22)],
                  alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                TopResultsCard(item: item)
            }
        }
    }
}

/// 热门搜索结果卡：leading 封面 44 + 两行文本（标题 13 semibold / 副标题 11 secondary）
/// + 尾标（艺人 chevron、歌曲 ellipsis）。
struct TopResultsCard: View {
    @Environment(AppState.self) private var appState
    let item: TopResultsItem

    var body: some View {
        card
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var card: some View {
        switch item {
        case .artist(let artist):
            NavigationLink(value: Route.artist(artist)) {
                HStack(spacing: 12) {
                    ArtworkView(url: artist.avatarURL, tint: .amberKey, points: 44)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    lockup(title: artist.name, subtitle: "艺人")
                    Spacer(minLength: 0)
                    trailingIcon("chevron.right")
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
        case .track(let track):
            Button {
                appState.playNow(track)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: track.artworkURL, tint: .amberKey, points: 44)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    lockup(title: track.title, subtitle: "歌曲 · \(track.artistName)")
                    Spacer(minLength: 0)
                    trailingIcon("ellipsis")
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
        }
    }

    private func lockup(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func trailingIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Shelf 组件（结果页各分区的横向卡片）

/// 专辑/播放列表 shelf 卡（Music 实测：封面 ~174pt 方形圆角 6，标题 13 两行 + 副标题 11）。
struct ShelfCard: View {
    let artworkURL: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: artworkURL, tint: .amberKey, points: 174)
                .frame(width: 174, height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.system(size: 13))
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 174, alignment: .leading)
    }
}

/// 艺人 shelf 项（Music 实测：圆形头像 ~133pt，名字居中 12pt）。
struct ArtistShelfItem: View {
    let artist: Artist

    var body: some View {
        VStack(spacing: 8) {
            ArtworkView(url: artist.avatarURL, tint: .amberKey, points: 133)
                .frame(width: 133, height: 133)
                .clipShape(Circle())
            Text(artist.name)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .frame(width: 133)
    }
}

/// 歌曲 shelf 行（Music 实测：小封面 40 + 歌名 13 / 艺人 11 secondary，点击即播）。
struct TrackShelfRow: View {
    let track: Track
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                ArtworkView(url: track.artworkURL, tint: .amberKey, points: 40)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// MV shelf 卡（Music 实测：16:9 缩略图 ~200pt 宽、圆角 6，标题 13 / 歌手 11 在下）。
struct MVCard: View {
    let mv: MV

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 不传 points：MV 封面是 T015R640x360 的 16:9 模板，
            // ArtworkSize 的方图改写会让 CDN 404。
            ArtworkView(url: mv.coverURL, tint: .amberKey)
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    // 时长角标
                    Text(Self.durationText(mv.duration))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                        .padding(6)
                }
            Text(mv.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Text(mv.artistName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 200, alignment: .leading)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        // 补零走共用的 `zeroPadded`（`Models.swift`），与从前的 `%02d` 逐字符等价。
        return "\(m):\(s.zeroPadded(to: 2))"
    }
}
