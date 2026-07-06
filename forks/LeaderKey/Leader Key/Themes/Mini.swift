import Combine
import SwiftUI

enum Mini {
  static let size = 36.0
  static let margin = 8.0
  // machine-spirit: horizontal room per accreted letter of the summon chain.
  static let letterStep = 18.0

  class Window: MainWindow {
    private var accretionCancellable: AnyCancellable?

    required init(controller: Controller) {
      let rect = NSRect(x: 0, y: 0, width: Mini.size, height: Mini.size)
      super.init(controller: controller, contentRect: rect)
      let view = MainView().environmentObject(self.controller.userState)
      contentView = NSHostingView(rootView: view)

      // machine-spirit: the box grows leftward (bottom-right anchored) as
      // the summon chain accretes letters.
      accretionCancellable = Publishers.CombineLatest(
        controller.userState.$navigationPath, controller.userState.$display
      )
      .receive(on: RunLoop.main)
      .sink { [weak self] path, display in
        var count = path.compactMap { $0.key }.count
        if let display, display != path.last?.key { count += 1 }
        self?.accommodate(letterCount: count)
      }
    }

    private func accommodate(letterCount: Int) {
      let width = Mini.size + Double(max(0, letterCount - 1)) * Mini.letterStep
      guard abs(frame.width - width) > 0.5 else { return }
      var newFrame = frame
      newFrame.origin.x = frame.maxX - width
      newFrame.size.width = width
      setFrame(newFrame, display: true, animate: false)
    }

    override func show(on screen: NSScreen, after: (() -> Void)? = nil) {
      let newOriginX = screen.visibleFrame.maxX - Mini.size - Mini.margin
      let newOriginY = screen.visibleFrame.minY + Mini.margin
      self.setFrameOrigin(NSPoint(x: newOriginX, y: newOriginY))

      makeKeyAndOrderFront(nil)

      fadeIn {
        after?()
      }
    }

    override func hide(after: (() -> Void)? = nil) {
      fadeOut {
        super.hide(after: after)
      }
    }

    override func notFound() {
      shake()
    }

    override func cheatsheetOrigin(cheatsheetSize: NSSize) -> NSPoint {
      return NSPoint(
        x: frame.maxX - cheatsheetSize.width,
        y: frame.maxY + Mini.margin)
    }
  }

  struct MainView: View {
    @EnvironmentObject var userState: UserState

    // machine-spirit: the summon chain typed so far, glyph-mapped.
    private var letters: [String] {
      var sequence = userState.navigationPath.compactMap { $0.key }
      if let display = userState.display, display != sequence.last {
        sequence.append(display)
      }
      return sequence.map { KeyMaps.glyph(for: $0) ?? $0 }
    }

    var body: some View {
      ZStack {
        // machine-spirit: idle shows the summon sigil in place of the plain
        // dot; as keys land, the chain assembles letter by letter — dim
        // trail, bright head. Cheap and atomic: text + one spring.
        if userState.isShowingRefreshState {
          content.pulsate()
        } else {
          content
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .font(.system(size: 16, weight: .semibold, design: .rounded))
      .foregroundStyle(userState.currentGroup?.key == nil ? .secondary : .primary)
      .background(
        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
      )
    }

    @ViewBuilder private var content: some View {
      if letters.isEmpty {
        Image("SummonSigil")
          .resizable()
          .scaledToFit()
          .padding(3)
      } else {
        HStack(spacing: 2) {
          ForEach(Array(letters.enumerated()), id: \.offset) { index, glyph in
            Text(glyph)
              .fontDesign(.rounded)
              .fontWeight(.bold)
              .opacity(index == letters.count - 1 ? 1 : 0.5)
              .transition(.scale(scale: 1.7).combined(with: .opacity))
          }
        }
        .animation(.spring(duration: 0.18), value: letters.count)
      }
    }
  }
}

struct Invisible_MainView_Previews: PreviewProvider {
  static var previews: some View {
    VStack {
      MysteryBox.MainView().environmentObject(
        UserState(userConfig: UserConfig()))
    }.frame(width: Mini.size, height: Mini.size, alignment: .center)
  }
}
