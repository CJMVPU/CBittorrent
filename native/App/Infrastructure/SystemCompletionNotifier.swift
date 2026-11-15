import UserNotifications

@MainActor
struct SystemCompletionNotifier: CompletionNotifier {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func completed(_ torrent: TorrentSnapshot) async {
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = torrent.name
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: torrent.id, content: content, trigger: nil))
    }
}
