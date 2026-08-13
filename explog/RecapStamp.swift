import SwiftUI
import UIKit

/// Renders the on-screen stamp block into a bitmap the reel can burn into video.
///
/// The reel is one flat file, so the hour and caption — plain data on `Clip`
/// that every *live* surface draws with `ClipStamp` — have to become pixels
/// before they can appear in it. Rendering the real `ClipStamp` rather than
/// redrawing the text here is the whole point: the reel shows the same stamp
/// the feeds do, and it keeps showing it if the stamp's design ever changes.
///
/// The technique is `PostCaptureReview.saveComposite()`'s: flatten a SwiftUI
/// view with `ImageRenderer`.
@MainActor
enum RecapStamp {

    /// The stamp for one clip, drawn on a transparent `canvas`-sized bitmap.
    static func image(date: Date, caption: String, canvas: CGSize) -> CGImage? {
        guard canvas.width > 0, canvas.height > 0,
              canvas.width.isFinite, canvas.height.isFinite else { return nil }

        let renderer = ImageRenderer(content:
            ClipStamp(date: date, caption: caption)
                .frame(width: canvas.width, height: canvas.height)
        )
        // Rendered in points at 1×, then scaled up to the reel's pixel frame by
        // the compositor. Rendering at screen scale here would only make a
        // bigger bitmap of the same thing, since it gets rescaled either way.
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// The point-space canvas a stamp for `mediaSize` should be laid out in,
    /// given a `screen` of that size.
    ///
    /// This is the piece that makes the reel look like the app rather than like
    /// a video with some text on it. `ClipStamp`'s type is sized in *points*
    /// against how large the media appears on screen — 34pt of hour banner over
    /// a landscape clip letterboxed into a portrait phone. Laying it out
    /// directly at the reel's pixel size instead (1920 wide) would leave the
    /// same 34pt banner as a speck in the corner of the frame. Rendering into
    /// the rect the media actually occupies on screen, then scaling that whole
    /// bitmap up to the video, preserves the proportion the user has already
    /// seen everywhere else in the app.
    static func canvas(mediaSize: CGSize, screen: CGSize) -> CGSize {
        OverlayBurnIn.fittedRect(mediaSize: mediaSize, in: screen).size
    }
}
