import AVFoundation
import SwiftUI
import UIKit

struct PairingQRScannerView: View {
    let title: String
    let detail: String
    let showsCloseButton: Bool
    let dismissesAfterSuccessfulScan: Bool
    let onScanned: @MainActor (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isApplyingScan = false
    @State private var scannerResetID = UUID()

    init(
        title: String = "Scan the pairing QR from helm on your Mac.",
        detail: String = "The QR contains the full setup link, including the preferred bridge address and pairing token.",
        showsCloseButton: Bool = true,
        dismissesAfterSuccessfulScan: Bool = true,
        onScanned: @escaping @MainActor (String) async -> Bool
    ) {
        self.title = title
        self.detail = detail
        self.showsCloseButton = showsCloseButton
        self.dismissesAfterSuccessfulScan = dismissesAfterSuccessfulScan
        self.onScanned = onScanned
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PairingQRScannerCameraView(
                    onScanned: { value in
                        handleScannedValue(value)
                    },
                    onFailure: { message in
                        errorMessage = message
                    }
                )
                .id(scannerResetID)
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(detail)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))

                    if isApplyingScan {
                        Label("Pairing...", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func handleScannedValue(_ value: String) {
        guard !isApplyingScan else { return }
        isApplyingScan = true
        errorMessage = nil

        Task { @MainActor in
            let didPair = await onScanned(value)
            isApplyingScan = false

            if didPair {
                if dismissesAfterSuccessfulScan {
                    dismiss()
                }
            } else {
                errorMessage = "That QR was not a valid helm pairing code. Try scanning the QR from your Mac again."
                scannerResetID = UUID()
            }
        }
    }
}

private struct PairingQRScannerCameraView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> PairingQRScannerViewController {
        let controller = PairingQRScannerViewController()
        controller.onScanned = onScanned
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ uiViewController: PairingQRScannerViewController, context: Context) {}
}

private final class PairingQRScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didConfigureSession = false
    private var didEmitResult = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onFailure?("Camera access is required to scan a pairing QR.")
                    }
                }
            }
        case .denied, .restricted:
            onFailure?("Camera access is required to scan a pairing QR.")
        @unknown default:
            onFailure?("Camera access is unavailable.")
        }
    }

    private func configureSession() {
        guard previewLayer == nil else {
            startRunning()
            return
        }

        view.backgroundColor = .black

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            onFailure?("This device does not have a camera available for QR scanning.")
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)

            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                onFailure?("helm could not access the camera input.")
                return
            }

            let metadataOutput = AVCaptureMetadataOutput()
            if captureSession.canAddOutput(metadataOutput) {
                captureSession.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                metadataOutput.metadataObjectTypes = [.qr]
            } else {
                onFailure?("helm could not configure QR scanning.")
                return
            }

            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
            self.previewLayer = previewLayer

            startRunning()
        } catch {
            onFailure?("helm could not start the camera scanner.")
        }
    }

    private func startRunning() {
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmitResult,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let value = metadataObject.stringValue
        else {
            return
        }

        didEmitResult = true
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        onScanned?(value)
    }
}
