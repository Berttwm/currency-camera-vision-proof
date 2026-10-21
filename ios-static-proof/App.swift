import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let identity = Bundle.main.object(forInfoDictionaryKey: "ProofRunIdentity") as? String ?? "missing"
        let progressURL = documents.appendingPathComponent("progress-" + identity + ".json")
        @Sendable func progress(_ stage: String) {
            let data = try? jsonData(["runIdentity": identity, "stage": stage, "time": Date().timeIntervalSince1970])
            try? data?.write(to: progressURL, options: .atomic)
        }
        progress("didFinishLaunching")
        let screen = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: controller.view.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = "Running static reader test"
        controller.view.addSubview(label)
        screen.rootViewController = controller
        screen.makeKeyAndVisible()
        window = screen
        Task.detached {
            let destination = documents.appendingPathComponent("result-" + identity + ".json")
            do {
                progress("background-task-started")
                let defaults = languageDefaults()
                progress("self-test-started")
                try selfTest()
                progress("self-test-complete")
                guard let inputs = Bundle.main.resourceURL?.appendingPathComponent("Inputs") else {
                    throw ProofError(description: "Missing input directory")
                }
                progress("menu-recognition-started")
                let result = try recognizeInputs(inputs, defaults: defaults, platform: "iOS Simulator")
                try require(result["runIdentity"] as? String == identity, "App/input run identity mismatch")
                progress("menu-recognition-complete")
                let bytes = try jsonData(result)
                try require(bytes.count < 4_000_000, "iOS JSON exceeds log cap")
                try bytes.write(to: destination, options: .atomic)
                progress("result-written")
            } catch {
                progress("caught-error: " + String(describing: error))
                let data = try? jsonData(["complete": false, "runIdentity": identity, "error": String(describing: error)])
                try? data?.write(to: destination, options: .atomic)
            }
        }
        return true
    }
}
