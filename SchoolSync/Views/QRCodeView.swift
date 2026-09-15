import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders an invite as a QR code.
///
/// Generated at a large scale and drawn with nearest-neighbour interpolation:
/// a QR is a grid of hard squares, and letting SwiftUI smooth it produces grey
/// edges that a camera has to work to resolve. The person scanning this may be
/// holding a phone at arm's length in a kitchen, so every bit of contrast is
/// worth having.
struct QRCodeView: View {
    let contents: String
    var size: CGFloat = 240

    var body: some View {
        if let image = render() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                // A white plate regardless of theme. A dark-mode QR on a dark
                // background is a QR that doesn't scan.
                .padding(12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("Couldn't create the code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func render() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(contents.utf8)
        // Medium correction: the payload is already long, and higher levels
        // trade data capacity for damage tolerance a phone screen doesn't need.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
