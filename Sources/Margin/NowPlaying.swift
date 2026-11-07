import AppKit
import Foundation
import os

struct Track: Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    /// Bundle ID of the app playing it.
    var player: String
}

/// The current song from Music and Spotify.
///
/// macOS no longer gives third-party apps the system-wide now-playing info, so
/// this listens to the notifications those two apps post on every change. That
/// needs no permission and no polling. A one-off AppleScript query fills in the
/// song that was already playing when Margin launched, and only runs against an
/// app that's already open, so it can never launch one. Audio from browsers
/// isn't visible here, though the media keys still control it.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published var current: Track?

    /// Set just before a skip, so the new song shows in the on-screen readout.
    /// Skips run on the action queue, so this is locked rather than main-actor.
    nonisolated static let announceNextChange = OSAllocatedUnfairLock(initialState: false)

    private static let players = ["com.spotify.client", "com.apple.Music"]
    private static let notifications = [
        "com.spotify.client.PlaybackStateChanged": "com.spotify.client",
        "com.apple.Music.playerInfo": "com.apple.Music",
    ]
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        for (name, player) in Self.notifications {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo
                let title = info?["Name"] as? String ?? ""
                let artist = info?["Artist"] as? String ?? ""
                let state = info?["Player State"] as? String ?? ""
                MainActor.assumeIsolated { self?.received(title: title, artist: artist, state: state, player: player) }
            })
        }
        refresh()
    }

    private func received(title: String, artist: String, state: String, player: String) {
        guard !title.isEmpty, state != "Stopped" else {
            if current?.player == player { current = nil }
            return
        }
        let track = Track(title: title, artist: artist, isPlaying: state == "Playing", player: player)
        // A paused app shouldn't replace the one that's actually playing.
        if !track.isPlaying, current?.isPlaying == true, current?.player != player { return }
        let changed = track.title != current?.title
        current = track
        let announce = Self.announceNextChange.withLock { flag -> Bool in
            defer { flag = false }
            return flag
        }
        if changed, announce {
            HUD.shared.show(symbol: "music.note", title: artist.isEmpty ? title : "\(title) · \(artist)", value: nil)
        }
    }

    /// Asks the open players directly. Only needed when nothing's been heard yet.
    func refresh() {
        guard current == nil else { return }
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let found = running.compactMap(Self.query)
            let best = found.first { $0.isPlaying } ?? found.first
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.current == nil { self.current = best }
                }
            }
        }
    }

    private nonisolated static func query(_ player: String) -> Track? {
        let script = """
        tell application id "\(player)"
            if player state is stopped then return ""
            return (name of current track) & "\\n" & (artist of current track) & "\\n" & (player state as text)
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // An unanswered permission prompt would otherwise leave this waiting forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        return Track(title: lines[0], artist: lines[1], isPlaying: lines[2] == "playing", player: player)
    }
}
