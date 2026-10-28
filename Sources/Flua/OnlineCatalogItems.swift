import Foundation

enum OnlineWallpaperItems {
    static let all: [OnlineWallpaper] = [
        OnlineWallpaper(
            id: "dareful-koolau-mountains-aerial",
            title: "Ko'olau Mountains Aerial (1080p)",
            sourceName: "Dareful",
            sourceURL: URL(string: "https://dareful.com/koolau-mountains-aerial/")!,
            creator: "Joel Holland",
            licenseName: "Creative Commons Attribution 4.0 International",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            modificationNotice: "Preview is a silent 568x320, 4-second excerpt. Download is the original 1080p source; credit Dareful and Joel Holland.",
            thumbnailURL: URL(string: "https://dareful.com/wp-content/uploads/2022/06/1430651915-40de20e58420481997b65c179efb6e49781fb48b083707e222ce0bf7dabcfdef-d_1280x720.jpg")!,
            previewURL: bundledPreview("dareful-koolau-mountains-aerial-preview"),
            downloadRoute: .direct(URL(string: "https://stream.mux.com/Ukq3iTE5dAkLMOdyIn7M700NbuTOEaStSVSdLbEGifbI/high.mp4?download=koolau-mountains-aerial-4k")!),
            fileExtension: "mp4"
        ),
        OnlineWallpaper(
            id: "isorepublic-sky-before-dawn",
            title: "Sky Before Dawn (4096×2304)",
            sourceName: "ISO Republic",
            sourceURL: URL(string: "https://isorepublic.com/video/sky-before-dawn/")!,
            creator: "Free Nature Stock",
            licenseName: "CC0",
            licenseURL: URL(string: "https://isorepublic.com/license/")!,
            modificationNotice: "Bundled preview is a silent 4-second excerpt resized and re-encoded to H.264 at 568 × 320. The downloadable source remains the original MP4.",
            thumbnailURL: URL(string: "https://isorepublic.com/wp-content/uploads/2019/01/sky-before-dawn-video-preview-533x300.jpg")!,
            previewURL: bundledPreview("isorepublic-sky-before-dawn-preview"),
            downloadRoute: .direct(URL(string: "https://isorepublic.com/wp-content/uploads/2019/01/iso-republic-sky-before-dawn.mp4")!),
            fileExtension: "mp4"
        ),
        OnlineWallpaper(
            id: "cutestockfootage-white-particles",
            title: "White Particles Slowly Falling Black Background (1080p)",
            sourceName: "Cute Stock Footage",
            sourceURL: URL(string: "https://cutestockfootage.com/stock-footage/11801/white-particles-slowly-falling-black-background/")!,
            creator: "CuteStockFootage.com",
            licenseName: "Creative Commons Attribution 4.0 International",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
            modificationNotice: "Bundled preview is a silent 4-second excerpt resized and re-encoded to H.264 at 568 × 320. The downloadable source remains the original MP4.",
            thumbnailURL: URL(string: "https://cutestockfootage.com/wp-content/uploads/2019/05/1037643185_1920x1080.jpg")!,
            previewURL: bundledPreview("cutestockfootage-white-particles-preview"),
            downloadRoute: .cuteStockFootage(
                pageURL: URL(string: "https://cutestockfootage.com/stock-footage/11801/white-particles-slowly-falling-black-background/")!,
                videoID: "501489629"
            ),
            fileExtension: "mp4"
        ),
        OnlineWallpaper(
            id: "nasa-third-stage-firing",
            title: "Third Stage Firing",
            sourceName: "NASA SVS",
            sourceURL: URL(string: "https://svs.gsfc.nasa.gov/12729/")!,
            creator: "NASA/JHUAPL",
            licenseName: "Public domain",
            licenseURL: URL(string: "https://svs.gsfc.nasa.gov/help/")!,
            modificationNotice: "Preview is a silent 640x360, 1.5-second excerpt; the downloadable original is unchanged.",
            thumbnailURL: URL(string: "https://svs.gsfc.nasa.gov/vis/a010000/a012700/a012729/ThirdStageFiring.00001_searchweb.png")!,
            previewURL: bundledPreview("nasa-third-stage-firing"),
            downloadRoute: .direct(URL(string: "https://svs.gsfc.nasa.gov/vis/a010000/a012700/a012729/ThirdStageFiring.mp4")!),
            fileExtension: "mp4"
        ),
        OnlineWallpaper(
            id: "grand-canyon-south-rim-summer",
            title: "Time-lapse: South Rim Summer (1080p)",
            sourceName: "Grand Canyon National Park",
            sourceURL: URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd01.htm")!,
            creator: "National Park Service; individual creator not listed",
            licenseName: "Public domain (Grand Canyon NPS B-roll)",
            licenseURL: URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd_index.htm")!,
            modificationNotice: nil,
            thumbnailURL: URL(string: "https://www.nps.gov/nps-audiovideo/thumbnail/48415e02-695b-45b0-bb91-25a5cb1e7e96.jpg")!,
            previewURL: URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/48415e02-695b-45b0-bb91-25a5cb1e7e96360p.mp4")!,
            downloadRoute: .direct(URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/48415e02-695b-45b0-bb91-25a5cb1e7e961080p.mp4")!),
            fileExtension: "mp4"
        ),
        OnlineWallpaper(
            id: "joshua-tree-sunrise-sunset-north-entrance",
            title: "Sunrise and Sunset Near the North Entrance (1080p)",
            sourceName: "Joshua Tree National Park",
            sourceURL: URL(string: "https://www.nps.gov/jotr/learn/photosmultimedia/sunclips.htm")!,
            creator: "National Park Service; individual creator not listed",
            licenseName: "Public domain (Joshua Tree NPS B-roll)",
            licenseURL: URL(string: "https://www.nps.gov/jotr/learn/photosmultimedia/broll.htm")!,
            modificationNotice: nil,
            thumbnailURL: URL(string: "https://www.nps.gov/nps-audiovideo/thumbnail/bf403faa-915c-44ea-b9a5-eb6a3cf9bb1a.jpg")!,
            previewURL: URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/bf403faa-915c-44ea-b9a5-eb6a3cf9bb1a360p.mp4")!,
            downloadRoute: .direct(URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/bf403faa-915c-44ea-b9a5-eb6a3cf9bb1a1080p.mp4")!),
            fileExtension: "mp4"
        )
    ]

    private static func bundledPreview(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "mp4") else {
            preconditionFailure("Missing bundled online wallpaper preview: \(name).mp4")
        }
        return url
    }
}
