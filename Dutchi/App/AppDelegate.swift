import UIKit
import Firebase
import FirebaseAuth
import FirebaseDatabase
import RevenueCat

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("AppDelegate: didFinishLaunching")
        
        // Configure Firebase
        FirebaseApp.configure()
        
        // Configure Firebase Realtime Database URL
        // Replace with your actual Firebase Database URL from Firebase Console
        // Format: https://YOUR-PROJECT-ID-default-rtdb.firebaseio.com/
        if let app = FirebaseApp.app() {
            let databaseURL = "https://dutchi3-default-rtdb.firebaseio.com/"
            Database.database(app: app, url: databaseURL)
            print("Firebase Database configured with URL: \(databaseURL)")
        }
        
#if DEBUG
        // Allow local simulator testing only. Production builds must use real Firebase verification.
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
#else
        Auth.auth().settings?.isAppVerificationDisabledForTesting = false
#endif
        
        // Configure RevenueCat. Keep verbose logs out of production builds.
#if DEBUG
        Purchases.logLevel = .debug
#else
        Purchases.logLevel = .warn
#endif
        Purchases.configure(withAPIKey: "test_caUGMRHygGjdvEbKsxidlxVEIcW")
        print("RevenueCat configured")

        warmBackend()

        return true
    }

    private func warmBackend() {
        guard let u = URL(string: "https://dutchie-dpij.onrender.com/") else { return }
        URLSession.shared.dataTask(with: u) { _, _, _ in }.resume()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print("didRegisterForRemoteNotificationsWithDeviceToken")
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed (this is OK for reCAPTCHA mode): \(error.localizedDescription)")
    }

    
    
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification notification: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("didReceiveRemoteNotification")
        if Auth.auth().canHandleNotification(notification) {
            completionHandler(.noData)
            return
        }
        completionHandler(.noData)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        print("AppDelegate open url:", url.absoluteString)
        if Auth.auth().canHandle(url) {
            print("Firebase handled auth URL")
            return true
        }
        return false
    }
}
