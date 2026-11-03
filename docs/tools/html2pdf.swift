// Prints an HTML file to a paginated US Letter PDF with WebKit, backgrounds included.
// Usage: html2pdf <input.html> <output.pdf>
// make_pdfs.sh compiles this into a small app bundle and launches it with `open`, because
// WebKit needs to start its helper processes outside any shell sandbox.
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: html2pdf <input.html> <output.pdf>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL

@MainActor
final class Printer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.shouldPrintBackgrounds = true
        // 8.5 in at 96 px/in, so the layout matches the page width.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func start() {
        FileHandle.standardError.write("loading \(input.path)\n".data(using: .utf8)!)
        webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent().deletingLastPathComponent())
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Give images and fonts a moment to settle.
            try? await Task.sleep(for: .seconds(1.5))
            FileHandle.standardError.write("loaded; printing\n".data(using: .utf8)!)
            self.print()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("load failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    private func print() {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: self, didRun: #selector(done(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc nonisolated func done(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Swift.print(success ? "wrote \(output.path)" : "print failed")
        exit(success ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let printer = MainActor.assumeIsolated { Printer() }
MainActor.assumeIsolated { printer.start() }
app.run()
