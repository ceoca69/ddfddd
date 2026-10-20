import SwiftUI
import UniformTypeIdentifiers

struct ExperimentalPasscodeView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var showImporter = false
    @State private var selectedDigit: String?
    @State private var showImagePicker = false
    @AppStorage("erosion.passcode.keySizeRaw") private var keySizeRaw = KPSize.defSize.rawValue
    @AppStorage("erosion.passcode.customWidth") private var custW = 0
    @AppStorage("erosion.passcode.customHeight") private var custH = 0
    @AppStorage("erosion.passcode.maskKeys") private var maskKeys = false
    @State private var showSizeAlert = false
    @State private var awaitingApplyResult = false

    private let digits = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", ""]]

    private var keySize: KPSize {
        KPSize(rawValue: keySizeRaw) ?? .defSize
    }

    private var keySizeBinding: Binding<KPSize> {
        Binding(
            get: { KPSize(rawValue: keySizeRaw) ?? .defSize },
            set: { keySizeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if airliftUIAccessRequired() && !airlift.airliftFeatureReady() {
                ContentUnavailableView("Airlift required", systemImage: "link.circle", description: Text("Enable LocalDevVPN and import a valid pairing file in Airlift."))
            } else {
                VStack(spacing: 18) {
                    keySizePicker
                    keypadPreview
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .navigationTitle("Custom Passcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showImporter = true
                            } label: {
                                Label("Import .passthm", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                maskKeys = true
                                Haptic.shared.play(.soft)
                            } label: {
                                Label("Mask Keys", systemImage: "circle")
                            }

                            Button {
                                airlift.getCurrentPasscodeKeys()
                            } label: {
                                Label("Get Current Keys", systemImage: "externaldrive")
                            }
                            .disabled(airlift.passcodeFlashRunning || airlift.readRunning)

                            Divider()

                            Button {
                                keySizeRaw = KPSize.defSize.rawValue
                                custW = 0
                                custH = 0
                                maskKeys = false
                                airlift.clearPasscodeKeys()
                                Haptic.shared.play(.soft)
                            } label: {
                                Label("Clear Keys", systemImage: "xmark")
                            }
                            .disabled(airlift.passcodeFlashRunning)

                            Button(role: .destructive) {
                                Alertinator.shared.alert(
                                    title: "Are you sure you'd like to reset your passcode keys?",
                                    body: "This removes the current contents of /var/mobile/Library/Caches/TelephonyUI-10 on the device. Your selected theme remains available to apply again.",
                                    actionLabel: "Confirm",
                                    action: {
                                        keySizeRaw = KPSize.defSize.rawValue
                                        custW = 0
                                        custH = 0
                                        maskKeys = false
                                        Task { _ = await airlift.resetPasscodeKeys() }
                                    }
                                )
                            } label: {
                                Label("Reset Keys", systemImage: "trash")
                            }
                            .disabled(airlift.passcodeFlashRunning)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Apply", role: .adaptiveConfirm) {
                            awaitingApplyResult = true
                            airlift.flashPasscodeTheme(
                                keySize: keySize,
                                customWidth: custW,
                                customHeight: custH,
                                maskKeys: maskKeys
                            )
                        }
                        .disabled(airlift.passcodeFlashRunning || airlift.passcodeTheme == nil || !airlift.airliftFeatureReady())
                    }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.archive, UTType(filenameExtension: "passthm") ?? .data], allowsMultipleSelection: false) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    airlift.loadPasscodeTheme(url: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                .sheet(isPresented: $showImagePicker) {
                    ImagePickerView { data in
                        guard let digit = selectedDigit, let image = UIImage(data: data) else { return }
                        airlift.setPasscodeKeyImage(digit: digit, image: image, data: data)
                    }
                }
                .onChange(of: airlift.passcodeFlashRunning) { wasRunning, isRunning in
                    guard awaitingApplyResult, wasRunning, !isRunning else { return }
                    awaitingApplyResult = false

                    let succeeded = airlift.passcodeLastApplySucceeded == true
                    if succeeded {
                        Alertinator.shared.alert(
                            title: "Successfully applied custom passcode keys!",
                            body: "Lock your device to see the new passcode artwork."
                        )
                        Haptic.shared.play(.soft)
                    } else {
                        Alertinator.shared.alert(
                            title: "Failed to apply custom passcode keys!",
                            body: AppMsg.opFailed
                        )
                    }
                }
            }
        }
    }

    private var keySizePicker: some View {
        VStack(spacing: 2) {
            Text("Key Size")
            Picker("", selection: keySizeBinding) {
                ForEach(KPSize.allCases, id: \.self) { size in
                    Text(size.label + (size == .custom ? " (\(custW)x\(custH))" : "")).tag(size)
                }
            }
            .alert("What would you like the custom size to be?", isPresented: $showSizeAlert) {
                TextField("Width", value: $custW, format: .number)
                    .keyboardType(.numberPad)
                TextField("Height", value: $custH, format: .number)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {
                    keySizeRaw = KPSize.defSize.rawValue
                }
                Button("Set") {
                    maskKeys = false
                }
            }
            .onChange(of: keySizeRaw) { _, rawValue in
                let newSize = KPSize(rawValue: rawValue) ?? .defSize
                if newSize == .custom {
                    showSizeAlert = true
                } else {
                    maskKeys = false
                }
            }
            .pickerStyle(.menu)
        }
        .padding(6)
        .background(Color(.systemBackground), in: .rect(cornerRadius: cornerRad.component))
    }

    private var keypadPreview: some View {
        let allDigits = digits.flatMap { $0 }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 16
        ) {
            ForEach(Array(allDigits.enumerated()), id: \.offset) { _, digit in
                if digit.isEmpty {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Button {
                        selectedDigit = digit
                        showImagePicker = true
                    } label: {
                        GeometryReader { geometry in
                            let diameter = min(geometry.size.width, geometry.size.height)
                            keypadKeyLabel(for: digit, diameter: diameter)
                                .frame(width: diameter, height: diameter)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose artwork for key \(digit)")
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 325)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func keypadKeyLabel(for digit: String, diameter: CGFloat) -> some View {
        if let image = previewImage(for: digit) {
            // Preserve the existing artwork scaling while sizing its circular key
            // background to the actual grid cell instead of a fixed 78-point circle.
            let denoVal: Float = isPad() ? 2.1 : 3.0
            Image(uiImage: image)
                .resizable()
                .frame(
                    width: CGFloat(Float(image.size.width) / denoVal),
                    height: CGFloat(Float(image.size.height) / denoVal)
                )
                .background {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: .circle)
                        .frame(width: diameter - 2, height: diameter - 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        } else {
            let keypadID = KeypadID.allCases.first { $0.dialerNumber == digit }
            VStack(spacing: max(1, diameter * 0.012)) {
                Text(digit)
                    .font(.system(size: diameter * 0.435, weight: .regular))
                if let letters = keypadID?.dialerLetters, !letters.isEmpty {
                    Text(letters)
                        .font(.system(size: diameter * 0.141, weight: .medium))
                        .tracking(diameter * 0.019)
                }
            }
            .frame(width: diameter - 2, height: diameter - 2)
            .aspectRatio(1, contentMode: .fit)
            .foregroundStyle(Color(.label))
            .glassEffect(.clear.interactive(), in: .circle)
        }
    }

    private func previewImage(for digit: String) -> UIImage? {
        guard let theme = airlift.passcodeTheme else { return nil }
        guard let data = theme.rawData[digit] ?? theme.keys[digit]?.pngData() else {
            return theme.keys[digit]
        }
        return UIImage(data: processPasscodeKeyData(
            data,
            size: keySize,
            customWidth: custW,
            customHeight: custH,
            mask: maskKeys
        )) ?? theme.keys[digit]
    }


}
