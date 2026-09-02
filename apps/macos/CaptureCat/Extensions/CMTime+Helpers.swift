import AVFoundation

extension CMTime {
    var seconds: Double {
        CMTimeGetSeconds(self)
    }

    var formattedTimecode: String {
        let totalSeconds = Int(max(0, seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func from(seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

extension TimeInterval {
    var formattedTimecode: String {
        let totalSeconds = Int(max(0, self))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
