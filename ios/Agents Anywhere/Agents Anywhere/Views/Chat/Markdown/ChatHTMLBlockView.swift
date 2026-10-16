import SwiftUI
import WebKit

/// Renders a raw-HTML region (a VCP card) as static web content. JavaScript is
/// off: the cards are declarative markup, and their `input(...)` handlers only
/// exist in the web GUI. The inline height follows the rendered content up to a
/// cap; the full-screen sheet shows the whole card.
struct ChatHTMLBlockView: View {
    let html: String
    @State private var contentHeight: CGFloat = 140
    @State private var showsFullScreen = false

    var body: some View {
        ChatWebView(html: html) { height in
            contentHeight = min(420, max(120, height))
        }
        .frame(height: contentHeight)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button {
                showsFullScreen = true
            } label: {
                AppSymbol("arrow.up.left.and.arrow.down.right")
                    .font(.footnote)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "全屏查看"))
        }
        .sheet(isPresented: $showsFullScreen) {
            ChatHTMLFullScreen(html: html)
        }
    }
}

private struct ChatHTMLFullScreen: View {
    let html: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatWebView(html: html) { _ in }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "关闭")) { dismiss() }
                    }
                }
        }
    }
}

private struct ChatWebView: UIViewRepresentable {
    let html: String
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.heightHandler = onHeight
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.heightHandler = onHeight
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(Self.document(html), baseURL: nil)
    }

    static func document(_ body: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
        html,body{margin:0;padding:0;background:transparent;color:CanvasText;}
        body{padding:14px;font:15px/1.7 -apple-system,"PingFang SC",sans-serif;overflow-wrap:break-word;}
        img,svg{max-width:100%;height:auto;}
        </style></head><body>\(body)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var heightHandler: ((CGFloat) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            heightHandler?(webView.scrollView.contentSize.height)
        }
    }
}
