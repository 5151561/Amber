import Combine
import Foundation

/// 把 `PlayerController` 接到遥控器上。
///
/// **只用播放器的公开面**（`resume` / `pause` / `next` / `previous` / `seek` / `volume` /
/// `toggleShuffle` / `cycleRepeatMode` / `objectWillChange`），播放器本体一行不动——
/// 它归另一位负责人，这一轮不该为遥控器往里加钩子。
extension PlayerController: RemoteControlTarget {

    func remotePlay() {
        // 没有 `play()`：起播是 `resume()`，队列空时它自己什么也不做。
        resume()
    }

    func remotePause() { pause() }

    func remoteTogglePlayPause() { togglePlayPause() }

    /// 遥控器按下一首＝用户自己按的，要记一次「跳过」（与界面上那颗按钮同义）。
    func remoteNext() { next(userInitiated: true) }

    func remotePrevious() { previous() }

    func remoteSeek(toMilliseconds ms: Int) {
        seek(to: TimeInterval(ms) / 1000)
    }

    var remoteVolume: Int {
        get { Int((volume * 100).rounded()) }
        set { volume = min(1, max(0, Double(newValue) / 100)) }
    }

    func remoteSetShuffle(_ on: Bool) {
        guard isShuffled != on else { return }
        toggleShuffle()
    }

    /// DACP 的 `dacp.repeatstate` 是 0 关 / 1 单曲 / 2 全部，
    /// 与 `RepeatMode`（off / all / one）的编号**对不上**，要显式换算。
    func remoteSetRepeat(_ state: Int) {
        let wanted: RepeatMode
        switch state {
        case 1: wanted = .one
        case 2: wanted = .all
        default: wanted = .off
        }
        // 播放器只给了「循环切下一档」，最多转三次一定到位。
        for _ in 0..<RepeatMode.allCases.count where repeatMode != wanted {
            cycleRepeatMode()
        }
    }

    func snapshot() -> RemotePlayState {
        var state = RemotePlayState()
        state.volume = remoteVolume
        state.shuffle = isShuffled
        state.repeatState = {
            switch repeatMode {
            case .off: return 0
            case .one: return 1
            case .all: return 2
            }
        }()
        guard let track = currentTrack else { return state }
        state.hasTrack = true
        state.isPlaying = isPlaying
        state.title = track.title
        state.artist = track.artistName
        state.album = track.albumName
        // `Track` 没有曲风字段（只有 `Album.genre`，队列里拿不到），留空。
        // 遥控 App 会把这一行略掉，不会显示成空白占位。
        state.genre = ""
        state.elapsedMs = Int((currentTime * 1000).rounded())
        // `duration` 在 item 就绪前是 0，这时用曲目元数据里的时长兜底，
        // 免得遥控器上的进度条一开始是满的（见 `workingDuration` 同一个坑）。
        let seconds = duration > 0 ? duration : track.duration
        state.totalMs = Int((seconds * 1000).rounded())
        state.trackKey = RemoteIDHash.u32(track.id)
        state.albumKey = RemoteIDHash.u64(track.albumId ?? track.albumName)
        state.artworkURL = track.artworkURL
        return state
    }

    var remoteChanges: AsyncStream<Void> {
        // `clock`（10 Hz 的进度）**不能**并进来：那会把长轮询打成每秒十次唤醒，
        // 遥控器的电池和这台机器的 CPU 都受不了。进度靠 `cant`/`cast` 由客户端自己推。
        //
        // 遥控器要的是 `snapshot()` 里那几项的任意变化。`@Observable` 没有
        // 「随便什么变了」那条信号，所以在这里把它们逐项列出来——反倒比
        // `objectWillChange` 准：以前任何一个属性变都会唤醒长轮询，现在只有
        // 这七项才会。
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pump = Task { @MainActor [weak self] in
            let changes = Observations { [weak self] in
                guard let self else { return nil as Int? }
                var hasher = Hasher()
                hasher.combine(self.currentIndex)
                hasher.combine(self.isPlaying)
                hasher.combine(self.duration)
                hasher.combine(self.repeatMode)
                hasher.combine(self.isShuffled)
                hasher.combine(self.volume)
                hasher.combine(self.queue.count)
                return hasher.finalize()
            }
            for await _ in changes.dropFirst() {
                continuation.yield(())
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }
}

/// 把字符串 id 折成 DACP 要的定长数字 id。
///
/// `canp` / `asai` 只能装整数，而 Amber 的 id 是 `qq:0039MnYb0qxYhV` 这种字符串。
/// 折的目的只是「换歌时这个数一定跟着变」，不需要防碰撞——FNV-1a 够了。
enum RemoteIDHash {
    static func u64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        // 0 在 DACP 里被当成「没有」，撞上就挪一格
        return hash == 0 ? 1 : hash
    }

    static func u32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash == 0 ? 1 : hash
    }
}
