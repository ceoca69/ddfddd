import SwiftUI
import Combine
import UIKit
import AVFoundation
import Photos
import Contacts
import CoreLocation
import LocalAuthentication
import CoreBluetooth

private enum TCCPermission: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case bluetooth = "Bluetooth"
    case faceTouchID = "Face/Touch ID"
    case microphone = "Microphone"
    case location = "Location"
    case camera = "Camera"
    case contacts = "Contacts"

    var id: String { rawValue }

    /// Destination filenames. For All, one user-selected image is written to all seven targets.
    var filenames: [String] {
        switch self {
        case .all:
            return [
                "Location@3x.png",
                "kTCCServicePhotos@3x.png",
                "kTCCServiceAddressBook@3x.png",
                "kTCCServiceMicrophone@3x.png",
                "kTCCServiceBluetoothAlways@3x.png",
                "kTCCServiceCamera@3x.png",
                "kTCCServiceFaceID@3x.png"
            ]
        case .photos: return ["kTCCServicePhotos@3x.png"]
        case .bluetooth: return ["kTCCServiceBluetoothAlways@3x.png"]
        case .faceTouchID: return ["kTCCServiceFaceID@3x.png"]
        case .microphone: return ["kTCCServiceMicrophone@3x.png"]
        case .location: return ["Location@3x.png"]
        case .camera: return ["kTCCServiceCamera@3x.png"]
        case .contacts: return ["kTCCServiceAddressBook@3x.png"]
        }
    }

    var remotePath: String {
        if self == .all { return "/var/mobile/tmp/com.apple.tccd" }
        return "/var/mobile/tmp/com.apple.tccd/\(filenames[0])"
    }

    /// Built-in preview image supplied by the user. All previews the camera icon,
    /// matching the permission sheet shown in the supplied reference screenshot.
    var assetName: String {
        switch self {
        case .all, .camera: return "TCC_Camera"
        case .photos: return "TCC_Photos"
        case .bluetooth: return "TCC_Bluetooth"
        case .faceTouchID: return "TCC_FaceID"
        case .microphone: return "TCC_Microphone"
        case .location: return "TCC_Location"
        case .contacts: return "TCC_Contacts"
        }
    }

    /// Text shown in the prompt template, controlled by the Permission picker.
    var promptSubject: String {
        switch self {
        case .all, .camera: return "Camera"
        case .photos: return "Photos"
        case .bluetooth: return "Bluetooth"
        case .faceTouchID: return "Face/Touch ID"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .contacts: return "Contacts"
        }
    }

    var promptTitle: String { "Allow “Erosion” to use \(promptSubject)?" }

    var promptDetail: String {
        switch self {
        case .all:
            return "Erosion is testing the iOS camera permission prompt. Prepare requests permissions but does not capture images."
        case .photos:
            return "Erosion is testing the iOS Photos permission prompt. Prepare does not access your photos."
        case .bluetooth:
            return "Erosion is testing the iOS Bluetooth permission prompt. Prepare does not connect to devices."
        case .faceTouchID:
            return "Erosion is testing the biometric authentication prompt. Prepare does not use the authentication result."
        case .microphone:
            return "Erosion is testing the iOS microphone permission prompt. Prepare does not record audio."
        case .location:
            return "Erosion is testing the iOS location permission prompt. Prepare does not collect your location."
        case .camera:
            return "Erosion is testing the iOS camera permission prompt. Prepare does not capture images."
        case .contacts:
            return "Erosion is testing the iOS Contacts permission prompt. Prepare does not read contacts."
        }
    }
}

/// Stores a custom preview per selected Permission and applies it only after the
/// standalone TCC screen's existing top-right Apply button is pressed.
@MainActor
final class TCCSession: ObservableObject {
    static let shared = TCCSession()
    static let permissionDefaultsKey = "erosion.tcc.permissionSelection.v1"
    private static let customImageKeyPrefix = "erosion.tcc.customImage.v2."

    private let remoteDirectory = "/var/mobile/tmp/com.apple.tccd"

    @Published private(set) var imageRevision = 0
    @Published private(set) var isApplying = false
    @Published private(set) var isResetting = false

    private init() {}

    private func customImageKey(for permission: TCCPermission) -> String {
        Self.customImageKeyPrefix + permission.rawValue
    }

    func customImageData(for permission: TCCPermission) -> Data? {
        UserDefaults.standard.data(forKey: customImageKey(for: permission))
    }

    func hasCustomImage(for permission: TCCPermission) -> Bool {
        guard let data = customImageData(for: permission), UIImage(data: data) != nil else { return false }
        return true
    }

    /// Called when the user taps the displayed image and picks a replacement.
    /// The replacement is resized immediately and saved silently; no alert is shown.
    func selectCustomImage(_ data: Data, for permission: TCCPermission) {
        guard let normalized = Self.normalized207PNG(data) else { return }
        UserDefaults.standard.set(normalized, forKey: customImageKey(for: permission))
        imageRevision &+= 1
    }

    func applySelectedImage(using airlift: AirliftBridge, permission: TCCPermission) async -> Bool {
        guard !isApplying, !isResetting,
              let imageData = customImageData(for: permission),
              let normalized = Self.normalized207PNG(imageData) else { return false }
        isApplying = true
        defer { isApplying = false }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_tcc_stage_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            for filename in permission.filenames {
                try normalized.write(to: stage.appendingPathComponent(filename), options: .atomic)
            }

            let succeeded = await airlift.writeDirectoryBatch(
                localDirectoryURL: stage,
                remotePath: remoteDirectory,
                logFeature: "tcc"
            )
            try? FileManager.default.removeItem(at: stage)
            return succeeded
        } catch {
            try? FileManager.default.removeItem(at: stage)
            airlift.appendFeatureLog("tcc", "Could not stage TCC image(s): \(error.localizedDescription)")
            return false
        }
    }

    func resetSelected(using airlift: AirliftBridge, permission: TCCPermission) async -> Bool {
        guard !isApplying, !isResetting else { return false }
        isResetting = true
        defer { isResetting = false }
        return await airlift.removeRemotePath(permission.remotePath, logFeature: "tcc")
    }

    /// Produces a square PNG with exactly 207 × 207 pixels (69 pt at 3× scale).
    private static func normalized207PNG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pointSize = CGSize(width: 69, height: 69)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pointSize))
        }.pngData()
    }
}

struct TCCView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    let onSelectImage: () -> Void
    @AppStorage("erosion.tcc.permissionSelection.v1") private var selectedPermissionRaw = "All"
    @AppStorage("erosion.tcc.prepare.completed.v1") private var didPrepare = false
    @StateObject private var preparer = TCCPermissionPreparer()
    @StateObject private var session = TCCSession.shared

    private var selectedPermission: TCCPermission {
        TCCPermission(rawValue: selectedPermissionRaw) ?? .all
    }

    private var previewImage: UIImage {
        if let data = session.customImageData(for: selectedPermission), let image = UIImage(data: data) {
            return image
        }
        if let image = UIImage(named: selectedPermission.assetName) { return image }
        return UIImage(systemName: "camera.fill") ?? UIImage()
    }

    var body: some View {
        Group {
            Section {
                VStack(spacing: 2) {
                    Text("TCC Permission")
                        .foregroundStyle(Color(.label))
                    Picker("TCC Permission", selection: $selectedPermissionRaw) {
                        ForEach(TCCPermission.allCases) { permission in
                            Text(permission.rawValue).tag(permission.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(.orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.black)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            } header: {
                HeaderLabel("TCC", symbol: "hand.raised.fingers.spread.fill")
            }

            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Button(action: onSelectImage) {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 69, height: 69)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose TCC image from Photos")

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedPermission.promptTitle)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(selectedPermission.promptDetail)
                            .font(.system(size: 16))
                            .foregroundColor(Color.white.opacity(0.48))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        promptButton("Don’t Allow")
                        promptButton("Allow")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section {
                Button(didPrepare ? "Prepared" : (preparer.isPreparing ? "Preparing…" : "Prepare")) {
                    Task {
                        await preparer.prepare()
                        didPrepare = true
                    }
                }
                .disabled(didPrepare || preparer.isPreparing || session.isApplying || session.isResetting)
                .foregroundStyle(didPrepare ? Color.gray : Color.accentColor)

                Button("Reset", role: .destructive) {
                    Task {
                        let succeeded = await session.resetSelected(using: airlift, permission: selectedPermission)
                        if succeeded {
                            Alertinator.shared.alert(
                                title: "Successfully reset TCC image(s)!",
                                body: selectedPermission == .all
                                    ? "The /var/mobile/tmp/com.apple.tccd directory was removed."
                                    : "The selected TCC image was removed."
                            )
                        } else {
                            Alertinator.shared.alert(
                                title: "Failed to reset TCC image(s)!",
                                body: AppMsg.opFailed
                            )
                        }
                    }
                }
                .tint(.red)
                .disabled(session.isApplying || session.isResetting)
            } header: {
                HeaderLabel("Actions", symbol: "bolt.fill")
            }
        }
    }

    private func promptButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.13))
            .clipShape(Capsule())
    }
}

@MainActor
private final class TCCPermissionPreparer: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    @Published private(set) var isPreparing = false

    private var locationManager: CLLocationManager?
    private var locationContinuation: CheckedContinuation<Void, Never>?
    private var bluetoothManager: CBCentralManager?
    private var bluetoothContinuation: CheckedContinuation<Void, Never>?

    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true

        // Queue each request so system permission sheets never overlap.
        await requestMicrophone()
        await requestCamera()
        await requestPhotos()
        await requestLocation()
        await requestContacts()
        await requestFaceID()
        await requestBluetooth()

        isPreparing = false
    }

    private func requestMicrophone() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { _ in continuation.resume() }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { _ in continuation.resume() }
            }
        }
    }

    private func requestCamera() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { _ in continuation.resume() }
        }
    }

    private func requestPhotos() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if #available(iOS 14.0, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in continuation.resume() }
            } else {
                PHPhotoLibrary.requestAuthorization { _ in continuation.resume() }
            }
        }
    }

    private func requestLocation() async {
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        guard status == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        finishLocationRequestIfNeeded(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        finishLocationRequestIfNeeded(status)
    }

    private func finishLocationRequestIfNeeded(_ status: CLAuthorizationStatus) {
        guard status != .notDetermined,
              let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume()
    }

    private func requestContacts() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CNContactStore().requestAccess(for: .contacts) { _, _ in continuation.resume() }
        }
    }

    private func requestFaceID() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Erosion is testing the Face ID system prompt."
            ) { _, _ in continuation.resume() }
        }
    }

    private func requestBluetooth() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bluetoothContinuation = continuation
            bluetoothManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown,
              central.state != .resetting,
              let continuation = bluetoothContinuation else { return }
        bluetoothContinuation = nil
        continuation.resume()
    }
}

/// Standalone TCC destination used to isolate the permission-image experiment from Find My.
/// Tapping the prompt image opens the photo picker; Apply performs the remote write.
struct TCCStandaloneView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @StateObject private var session = TCCSession.shared
    @AppStorage("erosion.tcc.permissionSelection.v1") private var selectedPermissionRaw = "All"
    @State private var showingImagePicker = false
    @State private var pickerPermissionRaw = "All"
    @State private var isApplying = false

    private var selectedPermission: TCCPermission {
        TCCPermission(rawValue: selectedPermissionRaw) ?? .all
    }

    var body: some View {
        List {
            TCCView(onSelectImage: {
                pickerPermissionRaw = selectedPermissionRaw
                showingImagePicker = true
            })
        }
        .listStyle(.insetGrouped)
        .navigationTitle("TCC")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isApplying ? "Applying…" : "Apply", role: .adaptiveConfirm) {
                    Task { await applySelectedImage() }
                }
                .disabled(isApplying || session.isApplying || session.isResetting || !session.hasCustomImage(for: selectedPermission))
            }
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePickerView { data in
                guard let permission = TCCPermission(rawValue: pickerPermissionRaw) else { return }
                session.selectCustomImage(data, for: permission)
            }
        }
    }

    @MainActor
    private func applySelectedImage() async {
        guard !isApplying, session.hasCustomImage(for: selectedPermission) else { return }
        isApplying = true
        let succeeded = await session.applySelectedImage(using: airlift, permission: selectedPermission)
        isApplying = false

        if succeeded {
            Alertinator.shared.alert(
                title: "Successfully applied TCC image(s)!",
                body: selectedPermission == .all
                    ? "The selected 207 × 207 image was written to all seven TCC paths in /var/mobile/tmp/com.apple.tccd/."
                    : "The selected 207 × 207 image was written to \(selectedPermission.remotePath)."
            )
            Haptic.shared.play(.soft)
        } else {
            Alertinator.shared.alert(
                title: "Failed to apply TCC image(s)!",
                body: AppMsg.opFailed
            )
        }
    }
}
