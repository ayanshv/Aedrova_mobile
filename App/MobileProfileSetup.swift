import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct MobileProfileGate<Content: View>: View {
    let store: WorkspaceStore
    @ViewBuilder let content: () -> Content
    @State private var profile: MobileProfile?
    @State private var failed = false
    @State private var showingAccount = false

    var body: some View {
        Group {
            if store.isDemo || profile?.profileCompleted == true {
                content()
            } else if let profile {
                MobileProfileSetup(api: store.api, profile: profile) { self.profile = $0 }
            } else if failed {
                VStack(spacing: 12) {
                    Text("Couldn’t load your profile.")
                    Button("Try again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aedrovaScreen()
            } else {
                ProgressView("Loading your profile")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aedrovaScreen()
            }
        }
        .toolbar {
            if !store.isDemo && profile?.profileCompleted != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Account") { showingAccount = true }
                }
            }
        }
        .sheet(isPresented: $showingAccount) { AccountSettingsSheet(store: store) }
        .task { if !store.isDemo && profile == nil { await load() } }
    }

    private func load() async {
        failed = false
        do { profile = try await store.api.myProfile() }
        catch { if !Task.isCancelled { failed = true } }
    }
}

private struct MobileProfileSetup: View {
    let api: WorkspaceAPI
    let profile: MobileProfile
    let finished: (MobileProfile) -> Void
    @State private var name = ""
    @State private var username = ""
    @State private var title = ""
    @State private var bio = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photo: Data?
    @State private var photoForUpload: Data?
    @State private var uploadedPath: String?
    @State private var loadingPhoto = false
    @State private var saving = false
    @State private var notice: String?

    var body: some View {
        let preview = photo.flatMap(UIImage.init(data:))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AedrovaLockup()
                Text("Your profile").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Help teammates recognize you in your workspace.").foregroundStyle(MobileTheme.secondary)
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    HStack(spacing: 10) {
                        if let image = preview {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 44, height: 44).clipShape(.circle).accessibilityHidden(true)
                        } else {
                            Image(systemName: "person.crop.circle").font(.title).accessibilityHidden(true)
                        }
                        Text(preview == nil ? "Add a photo (optional)" : "Change photo")
                    }
                }
                .disabled(saving)
                TextField("Display name", text: $name).textContentType(.name)
                TextField("Username", text: $username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Use 3–32 lowercase letters, numbers, or underscores. Start with a letter or number.")
                    .font(.footnote).foregroundStyle(MobileTheme.secondary)
                TextField("Role or title (optional)", text: $title).textContentType(.jobTitle)
                TextField("Short bio (optional)", text: $bio, axis: .vertical).lineLimit(2...4)
                if let notice { Text(notice).font(.footnote).foregroundStyle(MobileTheme.secondary) }
                Button(saving ? "Saving…" : "Continue") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!valid || saving || loadingPhoto)
            }
            .textFieldStyle(.roundedBorder)
            .padding(24)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .aedrovaScreen()
        .task {
            name = profile.displayName ?? ""
            username = profile.username ?? ""
            title = profile.title ?? ""
            bio = profile.bio ?? ""
            if let path = profile.avatarPath, let previous = try? await api.profilePhoto(path: path), pickedPhoto == nil {
                photo = previous
            }
        }
        .task(id: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            loadingPhoto = true
            defer { if pickedPhoto == item { loadingPhoto = false } }
            do {
                guard let original = try await item.loadTransferable(type: Data.self),
                      let source = CGImageSourceCreateWithData(original as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 384
                      ] as CFDictionary),
                      let png = UIImage(cgImage: thumbnail).pngData() else { throw WorkspaceError.invalidInput }
                guard !Task.isCancelled, pickedPhoto == item else { return }
                photo = png
                photoForUpload = png
                uploadedPath = nil
                notice = nil
            } catch {
                if !Task.isCancelled { notice = "Couldn’t read that photo. Choose another image." }
            }
        }
    }

    private var valid: Bool {
        (1...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
            && username.range(of: #"^[a-z0-9][a-z0-9_]{2,31}$"#, options: .regularExpression) != nil
            && title.unicodeScalars.count <= 80 && bio.unicodeScalars.count <= 280
    }

    private func save() async {
        guard valid, !loadingPhoto, !saving else { return }
        saving = true
        notice = nil
        defer { saving = false }
        do {
            if let photoForUpload, uploadedPath == nil {
                uploadedPath = try await api.uploadProfilePhoto(photoForUpload)
            }
            let saved = try await api.saveProfile(name: name, username: username, title: title,
                                                  bio: bio, avatarPath: uploadedPath)
            finished(saved)
        } catch WorkspaceError.status(400) {
            notice = "This profile couldn’t be saved. Check your details or try a different username."
        } catch {
            notice = "Couldn’t save your profile. Try again."
        }
    }
}
