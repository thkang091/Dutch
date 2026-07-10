import Foundation
import FirebaseAuth
import FirebaseDatabase
import Combine
import UIKit

struct VerifiedDutchieUser {
    let uid: String
    let phoneNumber: String
    let name: String?
    let venmoUsername: String?
    let venmoLink: String?
    let zelleContact: String?
    let zelleLink: String?
    let imageData: Data?
}

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    

    enum AuthState: Equatable {
        case guest
        case sendingCode
        case awaitingCode(phoneNumber: String)
        case signedIn(uid: String, phoneNumber: String)
    }

    @Published private(set) var authState: AuthState = .guest
    @Published private(set) var firebaseUser: FirebaseAuth.User?
    @Published var verificationID: String?
    @Published var errorMessage: String?
    @Published var isBusy = false

    private weak var appState: AppState?
    private let groupManager: GroupManager
    private var authHandle: AuthStateDidChangeListenerHandle?

    private let lastPhoneKey = "dutchi.auth.lastVerifiedPhone"
    private let cachedUIDKey = "dutchi.auth.cachedUID"
    private let ref = Database.database().reference()

    private init(groupManager: GroupManager = .shared) {
        self.groupManager = groupManager
    }

    deinit {
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
    }
    

    var phoneNumber: String? {
        verifiedPhoneNumber
    }

    // MARK: - Bootstrap

    func configure(appState: AppState) {
        self.appState = appState

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.handleAuthStateChanged(user: user)
            }
        }

        handleAuthStateChanged(user: Auth.auth().currentUser)

        NotificationCenter.default.addObserver(
            forName: .groupDidLeave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncAll()
            }
        }
    }

    // MARK: - Public status

    var isAuthenticated: Bool {
        if case .signedIn = authState { return true }
        return false
    }

    var canUseGroupMode: Bool {
        guard isAuthenticated,
              let phone = verifiedPhoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty else {
            return false
        }
        return true
    }

    var verifiedPhoneNumber: String? {
        switch authState {
        case .signedIn(_, let phoneNumber):
            return phoneNumber
        default:
            return firebaseUser?.phoneNumber
        }
    }

    var currentUID: String? {
        firebaseUser?.uid
    }

    // MARK: - Group gate

    func requireAuthForGroupMode(prefilledPhone: String? = nil) -> String? {
        if canUseGroupMode {
            groupManager.enableGroupMode()
            syncAll()
            return nil
        }

        groupManager.disableGroupMode()
        return prefilledPhone ?? appState?.profile.zelleContactInfo ?? ""
    }

    // MARK: - Phone auth

    func sendVerificationCode(to rawPhoneNumber: String) async {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to verify your phone number.") else {
            return
        }

        let phone = normalizeUSPhone(rawPhoneNumber)

        guard !phone.isEmpty else {
            errorMessage = "Enter a valid phone number."
            return
        }

        isBusy = true
        errorMessage = nil

        do {
            // ✅ Use reCAPTCHA verification instead of APNs
            Auth.auth().settings?.isAppVerificationDisabledForTesting = false
            
            let verificationID = try await PhoneAuthProvider.provider()
                .verifyPhoneNumber(phone, uiDelegate: nil)

            self.verificationID = verificationID
            self.authState = .awaitingCode(phoneNumber: phone)
        } catch {
            print("❌ Phone verification error: \(error)")
            self.errorMessage = error.localizedDescription
        }

        isBusy = false
    }
    
    // Add this method to AuthManager class
    func resetVerificationState() {
        authState = .guest
        verificationID = nil
        errorMessage = nil
    }

    func verifyCode(_ code: String) async {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to verify your phone number.") else {
            return
        }

        guard let verificationID else {
            errorMessage = "Missing verification session."
            return
        }

        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the code you received."
            return
        }

        isBusy = true
        errorMessage = nil

        do {
            let credential = PhoneAuthProvider.provider().credential(
                withVerificationID: verificationID,
                verificationCode: trimmed
            )

            let result = try await Auth.auth().signIn(with: credential)
            self.firebaseUser = result.user

            if let phone = result.user.phoneNumber {
                self.authState = .signedIn(uid: result.user.uid, phoneNumber: phone)
                cacheVerifiedIdentity(uid: result.user.uid, phone: phone)
            } else {
                self.authState = .guest
            }

            syncAll()
        } catch {
            self.errorMessage = error.localizedDescription
        }

        isBusy = false
    }

    func signOut() throws {
        try Auth.auth().signOut()
        verificationID = nil
        firebaseUser = nil
        authState = .guest
        clearCachedIdentity()

        groupManager.disableGroupMode()
        syncAll()
    }

    func deleteCurrentAccount(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let user = Auth.auth().currentUser else {
            completion(.failure(NSError(
                domain: "DutchAuth",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No signed-in account found."]
            )))
            return
        }

        isBusy = true
        let uid = user.uid
        let phone = verifiedPhoneNumber
        let phoneKey = phone.map { phoneIndexKey(for: $0) }

        if let phoneKey, !phoneKey.isEmpty {
            ref.child("verifiedUsersByPhone").child(phoneKey).removeValue()
            ref.child("members").child(phoneKey).removeValue()
        }
        ref.child("verifiedUsers").child(uid).removeValue()

        user.delete { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false

                if let error {
                    completion(.failure(error))
                    return
                }

                self.verificationID = nil
                self.firebaseUser = nil
                self.authState = .guest
                self.clearCachedIdentity()
                self.groupManager.disableGroupMode()
                // Wipe all local data and trigger navigation to fresh start
                Task { @MainActor in
                    TrialManager.shared.wipeAllLocalData()
                }
                completion(.success(()))
            }
        }
    }

    // MARK: - Profile sync

    func syncProfileChangedFields() {
        syncAll()
    }

    func ensureCurrentUserExistsInGroup() {
        guard isAuthenticated else { return }
        guard var group = groupManager.activeGroup else { return }
        guard let appState else { return }

        let phone = verifiedPhoneNumber
        let profile = appState.profile

        // ✅ CRITICAL FIX: Check if current user exists by PHONE NUMBER, not just isCurrentUser flag
        let normalizedPhone = phone.map { normalizePhoneNumber($0) }
        
        let existingByPhone = group.members.firstIndex { member in
            guard let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedPhone
        }
        
        var needsUpdate = false

        if let existingIndex = existingByPhone {
            // User exists by phone - just update their info if needed
            let updated = mergedCurrentMember(
                existing: group.members[existingIndex],
                profile: profile,
                verifiedPhone: phone
            )
            
            // Make sure isCurrentUser is set
            var finalUpdated = updated
            finalUpdated.isCurrentUser = true
            
            if group.members[existingIndex] != finalUpdated {
                print("🔄 Updating current user member info")
                group.members[existingIndex] = finalUpdated
                needsUpdate = true
            }
        } else {
            // User doesn't exist at all - add them
            print("➕ Adding current user to group")
            let member = GroupMember(
                name: resolvedDisplayName(from: profile),
                phoneNumber: verifiedPhoneNumber,
                imageData: profile.avatarImage,
                isCurrentUser: true,
                profileName: resolvedDisplayName(from: profile),
                venmoUsername: cleanedVenmo(profile.venmoUsername),
                venmoLink: emptyToNil(profile.venmoPaymentLink),
                zelleEmail: emptyToNil(profile.zelleContactInfo),
                zelleLink: emptyToNil(profile.zellePaymentLink)
            )
            group.members.insert(member, at: 0)
            needsUpdate = true
        }

        if needsUpdate {
            print("💾 Saving group changes from ensureCurrentUserExistsInGroup")
            groupManager.updateGroupPreservingCurrentMode(group)
            if groupManager.isGroupModeEnabled {
                groupManager.syncMembersToAppState(appState)
            }
        } else {
            print("✅ Current user already in group - no update needed")
        }
    }
    
    // Helper to normalize phone numbers
    private func normalizePhoneNumber(_ phone: String) -> String {
        let digitsOnly = phone.filter { $0.isNumber }
        
        if digitsOnly.count == 10 {
            return "+1" + digitsOnly
        }
        
        if digitsOnly.count == 11, digitsOnly.first == "1" {
            return "+" + digitsOnly
        }
        
        if phone.hasPrefix("+") {
            return "+" + digitsOnly
        }
        
        return digitsOnly.isEmpty ? phone : "+" + digitsOnly
    }

    // MARK: - Private

    // ✅ CRITICAL FIX: Only sync when auth state actually changes
    private func handleAuthStateChanged(user: FirebaseAuth.User?) {
        let previousState = authState
        firebaseUser = user

        guard let user else {
            authState = .guest
            groupManager.disableGroupMode()
            appState?.stopObservingBalanceItemsFromFirebase()
            
            // ✅ Only sync if state actually changed
            if previousState != .guest {
                syncAll()
            }
            return
        }

        let phone = user.phoneNumber ?? UserDefaults.standard.string(forKey: lastPhoneKey) ?? ""

        if !phone.isEmpty {
            let newState: AuthState = .signedIn(uid: user.uid, phoneNumber: phone)
            authState = newState
            cacheVerifiedIdentity(uid: user.uid, phone: phone)
            TrialManager.shared.syncSubscriptionStatusWithFirebase()
            
            // ✅ Only sync if state actually changed
            if previousState != newState {
                syncAll()
            }
        } else {
            authState = .guest
            
            // ✅ Only sync if state actually changed
            if previousState != .guest {
                syncAll()
            }
        }
    }

    private func syncAll() {
        guard let appState else { return }

        syncProfileWithVerifiedIdentity(into: appState)
        syncCurrentPerson(into: appState)
        syncVerifiedUserProfile(from: appState)
        appState.syncBalanceItemsFromFirebaseIfPossible()
        appState.startObservingBalanceItemsFromFirebaseIfPossible()
        
        // ✅ CRITICAL: These functions write to Firebase, which triggers observers
        // Only call them when auth state changes, not on every observer callback
        groupManager.syncCurrentUserPaymentInfo(from: appState.profile)
        ensureCurrentUserExistsInGroup()
        groupManager.startObservingAvailableGroups()
        groupManager.syncMembersToAppState(appState)
    }

    func syncVerifiedUserProfile(from appState: AppState) {
        guard let uid = currentUID,
              let phone = verifiedPhoneNumber,
              !phone.isEmpty else { return }

        let phoneKey = phoneIndexKey(for: phone)
        let venmoUsername = cleanedVenmo(appState.profile.venmoUsername)
        let zelleContact = emptyToNil(appState.profile.zelleContactInfo) ?? phone

        var data: [String: Any] = [
            "uid": uid,
            "phoneNumber": phone,
            "phoneKey": phoneKey,
            "name": resolvedDisplayName(from: appState.profile),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]

        if let venmoUsername { data["venmoUsername"] = venmoUsername }
        if let venmoLink = emptyToNil(appState.profile.venmoPaymentLink) { data["venmoLink"] = venmoLink }
        if !zelleContact.isEmpty { data["zelleContact"] = zelleContact }
        if let zelleLink = emptyToNil(appState.profile.zellePaymentLink) { data["zelleLink"] = zelleLink }
        if let imageData = appState.profile.avatarImage {
            data["imageData"] = imageData.base64EncodedString()
        }

        ref.child("verifiedUsersByPhone").child(phoneKey).updateChildValues(data)
        ref.child("verifiedUsers").child(uid).updateChildValues(data)
        ref.child("members").child(phoneKey).updateChildValues(data)
    }

    func createPaymentRequest(
        fromName: String,
        fromPhone: String,
        toName: String,
        amount: Double,
        receiptId: String,
        payeePhone: String?,
        venmoUsername: String?,
        venmoLink: String?,
        zelleContact: String?,
        zelleLink: String?,
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to create a payment request.") else {
            completion(nil, nil, nil)
            return
        }

        let requestID = UUID().uuidString

        var data: [String: Any] = [
            "id": requestID,
            "fromName": fromName,
            "fromPhone": fromPhone,
            "toName": toName,
            "amount": amount,
            "receiptId": receiptId,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "status": "pending"
        ]

        if let payeePhone, !payeePhone.isEmpty { data["toPhone"] = payeePhone }
        if let venmoUsername, !venmoUsername.isEmpty { data["payeeVenmoUsername"] = venmoUsername }
        if let venmoLink, !venmoLink.isEmpty { data["payeeVenmoLink"] = venmoLink }
        if let zelleContact, !zelleContact.isEmpty { data["payeeZelleContact"] = zelleContact }
        if let zelleLink, !zelleLink.isEmpty { data["payeeZelleLink"] = zelleLink }

        ref.child("paymentRequests").child(requestID).setValue(data) { error, _ in
            if let error {
                print("❌ Failed to create payment request: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil, nil, nil) }
                return
            }
            let payURL = "dutchie://pay?request=\(requestID)"
            let downloadURL = "https://dutchieapp.com/download?payRequest=\(requestID)&receipt=\(receiptId)"
            print("✅ Created Dutch payment request: \(requestID)")
            DispatchQueue.main.async { completion(payURL, downloadURL, requestID) }
        }
    }

    func lookupVerifiedDutchieUser(phoneNumber: String, completion: @escaping (VerifiedDutchieUser?) -> Void) {
        lookupVerifiedDutchieUser(phoneNumber: phoneNumber, name: nil, completion: completion)
    }

    func lookupVerifiedDutchieUser(
        phoneNumber: String?,
        name: String?,
        completion: @escaping (VerifiedDutchieUser?) -> Void
    ) {
        let trimmedPhone = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let phoneKey = phoneIndexKey(for: trimmedPhone)

        if !phoneKey.isEmpty {
            lookupVerifiedDutchieUserByPhoneKey(phoneKey) { [weak self] user in
                if let user {
                    completion(user)
                } else {
                    self?.lookupVerifiedDutchieUserByName(name, completion: completion)
                }
            }
        } else {
            lookupVerifiedDutchieUserByName(name, completion: completion)
        }
    }

    private func lookupVerifiedDutchieUserByPhoneKey(
        _ phoneKey: String,
        completion: @escaping (VerifiedDutchieUser?) -> Void
    ) {
        // Query `members` first (canonical index), fall back to `verifiedUsersByPhone`.
        ref.child("members").child(phoneKey).observeSingleEvent(of: .value) { [weak self] snapshot in
            if let dict = snapshot.value as? [String: Any],
               let user = self?.verifiedDutchieUser(from: dict) {
                DispatchQueue.main.async { completion(user) }
            } else {
                self?.ref.child("verifiedUsersByPhone").child(phoneKey).observeSingleEvent(of: .value) { snapshot in
                    guard let dict = snapshot.value as? [String: Any],
                          let user = self?.verifiedDutchieUser(from: dict) else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    DispatchQueue.main.async { completion(user) }
                }
            }
        }
    }

    private func lookupVerifiedDutchieUserByName(
        _ name: String?,
        completion: @escaping (VerifiedDutchieUser?) -> Void
    ) {
        let normalizedName = normalizedLookupName(name)
        guard !normalizedName.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        ref.child("members").observeSingleEvent(of: .value) { [weak self] snapshot in
            for child in snapshot.children {
                guard let memberSnapshot = child as? DataSnapshot,
                      let dict = memberSnapshot.value as? [String: Any],
                      self?.normalizedLookupName(dict["name"] as? String) == normalizedName,
                      let user = self?.verifiedDutchieUser(from: dict) else {
                    continue
                }
                DispatchQueue.main.async { completion(user) }
                return
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func verifiedDutchieUser(from dict: [String: Any]) -> VerifiedDutchieUser? {
        guard let uid = dict["uid"] as? String,
              let phone = dict["phoneNumber"] as? String else {
            return nil
        }

        return VerifiedDutchieUser(
            uid: uid,
            phoneNumber: phone,
            name: dict["name"] as? String,
            venmoUsername: dict["venmoUsername"] as? String,
            venmoLink: dict["venmoLink"] as? String,
            zelleContact: dict["zelleContact"] as? String,
            zelleLink: dict["zelleLink"] as? String,
            imageData: (dict["imageData"] as? String).flatMap { Data(base64Encoded: $0) }
        )
    }

    private func normalizedLookupName(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func syncProfileWithVerifiedIdentity(into appState: AppState) {
        guard let phone = verifiedPhoneNumber, !phone.isEmpty else { return }

        if appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appState.profile.name = "You"
        }

        let currentZelle = appState.profile.zelleContactInfo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentZelle.isEmpty {
            appState.profile.zelleContactInfo = phone
        }
    }

    private func syncCurrentPerson(into appState: AppState) {
        let displayName = resolvedDisplayName(from: appState.profile)
        let phone = verifiedPhoneNumber

        if let index = appState.people.firstIndex(where: { $0.isCurrentUser }) {
            appState.people[index].name = displayName
            appState.people[index].phoneNumber = phone
            appState.people[index].contactImage = appState.profile.avatarImage
        } else {
            let me = Person(
                name: displayName,
                contactImage: appState.profile.avatarImage,
                phoneNumber: phone,
                isCurrentUser: true
            )
            appState.people.insert(me, at: 0)
        }
    }

    private func mergedCurrentMember(
        existing: GroupMember,
        profile: Profile,
        verifiedPhone: String?
    ) -> GroupMember {
        GroupMember(
            id: existing.id,
            name: resolvedDisplayName(from: profile),
            phoneNumber: verifiedPhone ?? existing.phoneNumber,
            imageData: profile.avatarImage ?? existing.imageData,
            isCurrentUser: true,
            profileName: resolvedDisplayName(from: profile),
            venmoUsername: cleanedVenmo(profile.venmoUsername) ?? existing.venmoUsername,
            venmoLink: emptyToNil(profile.venmoPaymentLink) ?? existing.venmoLink,
            zelleEmail: emptyToNil(profile.zelleContactInfo) ?? existing.zelleEmail,
            zelleLink: emptyToNil(profile.zellePaymentLink) ?? existing.zelleLink
        )
    }

    private func resolvedDisplayName(from profile: Profile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }

    private func cleanedVenmo(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cacheVerifiedIdentity(uid: String, phone: String) {
        UserDefaults.standard.set(uid, forKey: cachedUIDKey)
        UserDefaults.standard.set(phone, forKey: lastPhoneKey)
    }

    private func clearCachedIdentity() {
        UserDefaults.standard.removeObject(forKey: cachedUIDKey)
        UserDefaults.standard.removeObject(forKey: lastPhoneKey)
    }

    private func normalizeUSPhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)

        if digits.count == 10 {
            return "+1\(digits)"
        } else if digits.count == 11, digits.first == "1" {
            return "+\(digits)"
        } else if raw.hasPrefix("+"), digits.count >= 10 {
            return raw
        } else {
            return ""
        }
    }

    private func phoneIndexKey(for phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        if digits.count == 10 { return "1\(digits)" }
        if digits.count == 11, digits.first == "1" { return digits }
        return digits
    }
}
