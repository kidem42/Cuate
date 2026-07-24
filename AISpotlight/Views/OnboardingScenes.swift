import SwiftUI

// MARK: - Animated onboarding scenes
//
// Port of design/onboarding (build_cards.py): five animated scenes, one per
// status-bar menu feature. Animation model — ONE beat per scene: the scene
// gets a normalized phase `t` (0…1), every layer knows its own window inside
// that phase and derives its progress from it. The tour plays each scene once
// and freezes on the "result" frame (`hold`); replay is a button.
//
// `t`    — normalized phase 0…1 (already clamped to `hold` by the shell).
// `time` — seconds since scene start (for carets, shimmer, equalizer).

enum OnbSceneID: CaseIterable {
    case chat, shot, dictation, worldTime, image

    /// Full loop duration in seconds (timings inside scenes are % of this).
    var cycle: Double {
        switch self {
        case .chat: return 9.0
        case .shot: return 12.0
        case .dictation: return 9.5
        case .worldTime: return 8.5
        case .image: return 11.0
        }
    }

    /// Phase to freeze on — the frame that shows the end result.
    var hold: Double {
        switch self {
        case .chat: return 0.86
        case .shot: return 0.93
        case .dictation: return 0.82
        case .worldTime: return 0.86
        case .image: return 0.90
        }
    }
}

// MARK: - Palette & helpers

enum OnbStyle {
    static let text = Color(red: 0.114, green: 0.114, blue: 0.122)        // #1D1D1F
    static let sec = Color(red: 0.235, green: 0.235, blue: 0.263).opacity(0.62)
    static let sec2 = Color(red: 0.235, green: 0.235, blue: 0.263).opacity(0.35)
    static let blue = Color(red: 0, green: 0.443, blue: 0.890)            // #0071E3
    static let win = Color(red: 0.984, green: 0.984, blue: 0.992)         // #FBFBFD
    static let sep = Color.black.opacity(0.10)
    static let field = Color.black.opacity(0.055)
    static let green = Color(red: 0.106, green: 0.498, blue: 0.231)       // #1B7F3B

    static let stage = CGSize(width: 560, height: 300)
}

/// Progress of `t` inside the window `a…b`, clamped to 0…1.
@inline(__always) func onbSeg(_ t: Double, _ a: Double, _ b: Double) -> Double {
    if b <= a { return t >= b ? 1 : 0 }
    return min(1, max(0, (t - a) / (b - a)))
}

/// The mock's cubic-bezier(.24,.86,.3,1) — a strong ease-out.
@inline(__always) func onbEase(_ u: Double) -> Double { 1 - pow(1 - u, 2.6) }

/// Eased progress inside a window.
@inline(__always) func onbIn(_ t: Double, _ a: Double, _ b: Double) -> Double {
    onbEase(onbSeg(t, a, b))
}

// MARK: - Shared building blocks

/// Desktop wallpaper behind every scene.
struct OnbWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.122, green: 0.200, blue: 0.439), location: 0),
                    .init(color: Color(red: 0.141, green: 0.369, blue: 0.467), location: 0.52),
                    .init(color: Color(red: 0.063, green: 0.180, blue: 0.271), location: 1)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.494, green: 0.769, blue: 0.878).opacity(0.42), .clear],
                center: UnitPoint(x: 0.22, y: 0.06), startRadius: 0, endRadius: 300
            )
            RadialGradient(
                colors: [Color(red: 0.102, green: 0.290, blue: 0.455).opacity(0.6), .clear],
                center: UnitPoint(x: 0.88, y: 0.94), startRadius: 0, endRadius: 260
            )
        }
    }
}

/// Fake macOS menu bar. `glow` highlights the app's status icon (0…1),
/// `hot` keeps it highlighted for the whole scene.
struct OnbMenuBar: View {
    let app: String
    var hot = false
    var glow: Double = 0
    /// Drop the last menu title on scenes with a camera notch, so long
    /// translations can't slide under it.
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Text(app).font(.system(size: 10.5, weight: .bold))
            Text(L("obs.mb.file")).font(.system(size: 10)).opacity(0.8)
            Text(L("obs.mb.edit")).font(.system(size: 10)).opacity(0.8)
            if !compact {
                Text(L("obs.mb.view")).font(.system(size: 10)).opacity(0.8)
            }
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 19, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(hot ? 0.28 : 0.32 * glow))
                )
            Image(systemName: "wifi").font(.system(size: 10)).opacity(0.85)
            Image(systemName: "battery.100").font(.system(size: 11)).opacity(0.85)
            Text("9:41").font(.system(size: 10))
        }
        .foregroundColor(.white)
        // Extra leading inset: the real window's close button sits over
        // this corner (fullSizeContentView), keep the fake app name clear.
        .padding(.leading, 32)
        .padding(.trailing, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.14))
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1), alignment: .bottom)
    }
}

/// Floating hotkey cap at the bottom of the stage.
/// Windows: appear `a1…a2`, press dip at `p1…p2`, fade out `o1…o2`.
struct OnbKeycap: View {
    let label: String
    let t: Double
    var a1 = 0.03, a2 = 0.07, p1 = 0.09, p2 = 0.12, o1 = 0.14, o2 = 0.17

    var body: some View {
        let inU = onbIn(t, a1, a2)
        let outU = onbSeg(t, o1, o2)
        // press: dip to 0.92 and back
        let d = onbSeg(t, p1, p2)
        let dip = 1 - 0.08 * sin(d * .pi)
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.07, green: 0.078, blue: 0.102).opacity(0.7))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.22), lineWidth: 1))
            .scaleEffect((0.95 + 0.05 * inU) * dip)
            .offset(y: 6 * (1 - inU))
            .opacity(inU * (1 - outU))
    }
}

/// Host application window (light chrome, traffic lights, placeholder body).
struct OnbHostWindow<Content: View>: View {
    let title: String
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 1, green: 0.373, blue: 0.341)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.180)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251)).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(OnbStyle.sec)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color(red: 0.929, green: 0.929, blue: 0.941))
            .overlay(Rectangle().fill(OnbStyle.sep).frame(height: 1), alignment: .bottom)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .background(OnbStyle.win)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 11)
    }
}

/// Placeholder text line inside a host window.
struct OnbTextLine: View {
    var width: CGFloat
    var bold = false
    var body: some View {
        Capsule()
            .fill(OnbStyle.text.opacity(bold ? 0.4 : 0.2))
            .frame(width: width, height: bold ? 6 : 4)
    }
}

/// Assistant panel glass background.
struct OnbGlass: ViewModifier {
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(Color.white.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, y: 14)
    }
}

/// Panel fly-in: translate + scale + blur, like the mock's c*panel keyframes.
struct OnbPanelIn: ViewModifier {
    let u: Double
    var dy: CGFloat = 9
    func body(content: Content) -> some View {
        content
            .opacity(u)
            .scaleEffect(0.965 + 0.035 * u)
            .offset(y: dy * (1 - u))
            .blur(radius: 7 * (1 - u))
    }
}

/// Panel header: provider picker + preset picker, as in the real panel.
struct OnbPanelHeader: View {
    let provider: ProviderID
    let providerName: String
    let preset: String

    var body: some View {
        HStack(spacing: 5) {
            ProviderLogo(provider: provider, size: 11)
            Text(providerName)
            Image(systemName: "chevron.down").font(.system(size: 6)).opacity(0.6)
            Spacer()
            Text(preset)
            Image(systemName: "chevron.down").font(.system(size: 6)).opacity(0.6)
            Image(systemName: "square.and.pencil").font(.system(size: 11)).padding(.leading, 6)
        }
        .font(.system(size: 9))
        .foregroundColor(OnbStyle.sec)
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 3)
    }
}

/// Composer strip at the bottom of the panel.
struct OnbComposer<FieldContent: View>: View {
    @ViewBuilder var field: FieldContent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip").font(.system(size: 12)).foregroundColor(OnbStyle.sec)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7).fill(OnbStyle.field).frame(height: 22)
                field.padding(.horizontal, 8)
            }
            .clipped()
            Image(systemName: "mic.fill")
                .font(.system(size: 10))
                .foregroundColor(OnbStyle.blue)
                .frame(width: 21, height: 21)
                .overlay(Circle().stroke(OnbStyle.blue, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])))
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10))
                .foregroundColor(.white)
                .frame(width: 21, height: 21)
                .background(Circle().fill(OnbStyle.blue))
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .overlay(Rectangle().fill(OnbStyle.sep).frame(height: 1), alignment: .top)
    }
}

/// Text typed by fraction `u`. By default reserves the full width up front so
/// nothing around it jumps while the characters appear; pass `reserve: false`
/// where a caret has to travel with the text (input fields).
struct OnbTyped: View {
    let text: String
    let u: Double
    var size: CGFloat = 10
    var color: Color = OnbStyle.text
    var reserve = true

    var body: some View {
        let shown = String(text.prefix(Int((Double(text.count) * u).rounded())))
        if reserve {
            Text(text).font(.system(size: size)).foregroundColor(color)
                .opacity(0)
                .overlay(
                    Text(shown).font(.system(size: size)).foregroundColor(color)
                        .frame(maxWidth: .infinity, alignment: .leading),
                    alignment: .leading
                )
        } else {
            Text(shown).font(.system(size: size)).foregroundColor(color)
        }
    }
}

/// Blinking caret (1.05 s period, like the mock).
struct OnbCaret: View {
    let time: Double
    var height: CGFloat = 10
    var color: Color = OnbStyle.text
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1, height: height)
            .opacity(time.truncatingRemainder(dividingBy: 1.05) < 0.525 ? 1 : 0)
    }
}

/// "Live" status shimmer (searching / recognizing …).
struct OnbStatus: View {
    let icon: String
    let label: String
    let time: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 9))
                .opacity(0.35 + 0.65 * abs(sin(.pi * time / 1.4)))
        }
        .foregroundColor(OnbStyle.blue)
    }
}

// MARK: - Scene 1 · Chat

struct OnbSceneChat: View {
    let t: Double
    let time: Double
    let hotkey: String

    var body: some View {
        let panelU = onbIn(t, 0.09, 0.17)
        let typeU = onbSeg(t, 0.18, 0.37)                 // question typed in field
        let clearU = onbSeg(t, 0.37, 0.40)                // field cleared on send
        let userU = onbIn(t, 0.38, 0.44)                  // question bubble
        let searchOn = onbSeg(t, 0.45, 0.48) - onbSeg(t, 0.58, 0.62)
        let botU = onbIn(t, 0.59, 0.64)
        let a1U = onbSeg(t, 0.63, 0.72)
        let a2U = onbSeg(t, 0.70, 0.79)
        let srcU = onbIn(t, 0.80, 0.84)

        ZStack(alignment: .topLeading) {
            OnbWallpaper()
            OnbMenuBar(app: L("obs.s1.app"), glow: onbSeg(t, 0.03, 0.07) - onbSeg(t, 0.14, 0.21))

            OnbHostWindow(title: L("obs.s1.winTitle"), size: CGSize(width: 266, height: 180)) {
                VStack(alignment: .leading, spacing: 6) {
                    OnbTextLine(width: 130, bold: true)
                    OnbTextLine(width: 215)
                    OnbTextLine(width: 180)
                    OnbTextLine(width: 200)
                    OnbTextLine(width: 112)
                    OnbTextLine(width: 168)
                    OnbTextLine(width: 142)
                }
                .padding(11)
            }
            .offset(x: 22, y: 44)

            // Assistant panel
            VStack(spacing: 0) {
                OnbPanelHeader(provider: .openai, providerName: "OpenAI", preset: "Assistant")
                VStack(spacing: 5) {
                    // user bubble
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L("obs.s1.q"))
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(OnbStyle.blue)
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 12, bottomLeadingRadius: 12,
                                bottomTrailingRadius: 4, topTrailingRadius: 12))
                        Text("9:41").font(.system(size: 7)).foregroundColor(OnbStyle.sec2)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(userU)
                    .scaleEffect(0.97 + 0.03 * userU)
                    .offset(y: 7 * (1 - userU))

                    ZStack(alignment: .topLeading) {
                        OnbStatus(icon: "globe", label: L("obs.s1.searching"), time: time)
                            .opacity(searchOn)
                        // bot answer
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "brain")
                                .font(.system(size: 12))
                                .foregroundColor(OnbStyle.blue)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                OnbTyped(text: L("obs.s1.a1"), u: a1U)
                                OnbTyped(text: L("obs.s1.a2"), u: a2U)
                                HStack(spacing: 3) {
                                    Image(systemName: "globe").font(.system(size: 8))
                                    Text("weather.com").font(.system(size: 8, weight: .medium))
                                }
                                .foregroundColor(OnbStyle.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(OnbStyle.blue.opacity(0.13)))
                                .padding(.top, 3)
                                .opacity(srcU)
                                .offset(y: 3 * (1 - srcU))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.055))
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 12, bottomLeadingRadius: 4,
                                bottomTrailingRadius: 12, topTrailingRadius: 12))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(botU)
                        .offset(y: 6 * (1 - botU))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)
                .padding(.bottom, 7)
                OnbComposer {
                    ZStack(alignment: .leading) {
                        Text(L("obs.s1.ph"))
                            .font(.system(size: 10))
                            .foregroundColor(OnbStyle.sec)
                            .opacity(typeU <= 0 ? 1 : (clearU >= 1 ? 1 : 0))
                        HStack(spacing: 0) {
                            OnbTyped(text: L("obs.s1.q"), u: typeU, reserve: false)
                                .fixedSize()
                            OnbCaret(time: time)
                        }
                        .opacity(typeU > 0 && clearU < 1 ? 1 : 0)
                    }
                }
            }
            .frame(width: 368)
            .modifier(OnbGlass())
            .modifier(OnbPanelIn(u: panelU))
            .offset(x: 172, y: 64)

            OnbKeycap(label: hotkey, t: t)
                .frame(maxWidth: .infinity)
                .offset(y: OnbStyle.stage.height - 36)
        }
        .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
        .clipped()
    }
}

// MARK: - Scene 2 · Area screenshot → table

struct OnbSceneShot: View {
    let t: Double
    let time: Double
    let hotkey: String

    private var isEN: Bool { Localization.currentLanguage == .english }
    private func dec(_ s: String) -> String { isEN ? s.replacingOccurrences(of: ",", with: ".") : s }

    private var rows: [(String, String, String, String)] {
        [(L("obs.s2.r1"), dec("3,6"), dec("4,2"), "+17 %"),
         (L("obs.s2.r2"), dec("1,5"), dec("1,8"), "+20 %"),
         (L("obs.s2.r3"), dec("5,4"), dec("6,4"), "+19 %")]
    }

    // Marquee geometry (stage coordinates)
    private let marqOrigin = CGPoint(x: 24, y: 76)
    private let marqSize = CGSize(width: 262, height: 126)

    var body: some View {
        let dimU = onbSeg(t, 0.07, 0.10) - onbSeg(t, 0.25, 0.29)
        let marqU = onbSeg(t, 0.12, 0.23)                  // linear drag
        let marqOn = onbSeg(t, 0.10, 0.12) - onbSeg(t, 0.25, 0.28)
        let flashU = onbSeg(t, 0.25, 0.26) - onbSeg(t, 0.26, 0.30)
        let panelU = onbIn(t, 0.27, 0.34)
        let thumbU = onbIn(t, 0.29, 0.39)
        let actU = onbIn(t, 0.39, 0.44)
        let pressD = onbSeg(t, 0.45, 0.50)
        let ocrOn = onbSeg(t, 0.47, 0.50) - onbSeg(t, 0.56, 0.59)
        let tableOn = onbIn(t, 0.55, 0.58)
        let rowU = [onbSeg(t, 0.56, 0.59), onbSeg(t, 0.59, 0.62), onbSeg(t, 0.62, 0.65),
                    onbSeg(t, 0.65, 0.68), onbSeg(t, 0.68, 0.71)]
        let qTypeU = onbSeg(t, 0.72, 0.83)
        let qClearU = onbSeg(t, 0.83, 0.85)
        let userU = onbIn(t, 0.83, 0.87)
        let ansU = onbIn(t, 0.88, 0.92)

        ZStack(alignment: .topLeading) {
            OnbWallpaper()
            OnbMenuBar(app: "Numbers")

            OnbHostWindow(title: L("obs.s2.winTitle"), size: CGSize(width: 300, height: 206)) {
                VStack(alignment: .leading, spacing: 6) {
                    OnbTextLine(width: 120, bold: true)
                    docTable(font: 7.5)
                }
                .padding(11)
            }
            .offset(x: 16, y: 40)

            // Dim + marquee + crosshair + flash
            Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.45 * dimU)
                .frame(height: OnbStyle.stage.height - 24)
                .offset(y: 24)
            if marqOn > 0 {
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(Color(red: 0.47, green: 0.75, blue: 1).opacity(0.14))
                        .overlay(Rectangle().stroke(Color.white.opacity(0.96), lineWidth: 1.5))
                    Text("786 × 378")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.07, green: 0.078, blue: 0.102).opacity(0.75)))
                        .offset(y: 16)
                }
                .frame(width: max(1, marqSize.width * marqU), height: max(1, marqSize.height * marqU), alignment: .topLeading)
                .offset(x: marqOrigin.x, y: marqOrigin.y)
                .opacity(marqOn)

                // crosshair follows the drag corner
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.96)).frame(width: 1, height: 13)
                    Rectangle().fill(Color.white.opacity(0.96)).frame(width: 13, height: 1)
                }
                .offset(x: 18 + (280 - 18) * marqU, y: 70 + (196 - 70) * marqU)
                .opacity(marqOn)
            }
            Color.white.opacity(0.92 * flashU)
                .frame(height: OnbStyle.stage.height - 24)
                .offset(y: 24)

            // Panel
            VStack(alignment: .leading, spacing: 0) {
                OnbPanelHeader(provider: .anthropic, providerName: "Anthropic", preset: "Assistant")
                // attachment + actions
                HStack(alignment: .top, spacing: 7) {
                    docTable(font: 4)
                    .padding(4)
                    .frame(width: 74, height: 46, alignment: .topLeading)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(OnbStyle.sep, lineWidth: 1))
                    .scaleEffect(1 + 2.1 * (1 - thumbU))
                    .offset(x: -96 * (1 - thumbU), y: 58 * (1 - thumbU))
                    .opacity(thumbU > 0 ? 1 : 0)

                    HStack(spacing: 4) {
                        actionPill(icon: "text.viewfinder", label: L("panel.extractText"), hot: true)
                            .scaleEffect(1 - 0.07 * sin(pressD * .pi))
                        actionPill(icon: "person.and.background.dotted", label: IAL("ia.action.removeBg"), hot: false)
                        actionPill(icon: "arrow.up.backward.and.arrow.down.forward.rectangle", label: IAL("ia.action.upscale"), hot: false)
                    }
                    .opacity(actU)
                    .offset(y: 5 * (1 - actU))
                }
                .padding(.horizontal, 9)
                .padding(.top, 5)

                VStack(alignment: .leading, spacing: 5) {
                    OnbStatus(icon: "text.viewfinder", label: L("obs.s2.recognizing"), time: time)
                        .opacity(ocrOn)
                        .frame(height: ocrOn > 0.01 ? nil : 0)

                    // recognized table appears only once OCR "finishes"
                    // (the mock showed an empty bubble from the start — fixed here)
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "brain")
                            .font(.system(size: 12)).foregroundColor(OnbStyle.blue).padding(.top, 3)
                        mdTable(rowU: rowU)
                            .padding(7)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.055))
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 12, bottomLeadingRadius: 4,
                                bottomTrailingRadius: 12, topTrailingRadius: 12))
                    }
                    .opacity(tableOn)
                    .offset(y: 4 * (1 - tableOn))
                    .frame(height: tableOn > 0.01 ? nil : 0)

                    Text(L("obs.s2.q"))
                        .font(.system(size: 10)).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(OnbStyle.blue)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 12, bottomLeadingRadius: 12,
                            bottomTrailingRadius: 4, topTrailingRadius: 12))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(userU)
                        .offset(y: 6 * (1 - userU))
                        .frame(height: userU > 0.01 ? nil : 0)

                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "brain")
                            .font(.system(size: 12)).foregroundColor(OnbStyle.blue).padding(.top, 3)
                        Text(L("obs.s2.a"))
                            .font(.system(size: 10)).foregroundColor(OnbStyle.text)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.black.opacity(0.055))
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 12, bottomLeadingRadius: 4,
                                bottomTrailingRadius: 12, topTrailingRadius: 12))
                    }
                    .opacity(ansU)
                    .offset(y: 5 * (1 - ansU))
                    .frame(height: ansU > 0.01 ? nil : 0)
                }
                .padding(.horizontal, 9)
                .padding(.top, 5)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)

                OnbComposer {
                    HStack(spacing: 0) {
                        OnbTyped(text: L("obs.s2.q"), u: qTypeU, reserve: false).fixedSize()
                        OnbCaret(time: time)
                    }
                    .opacity(qClearU >= 1 ? 0 : 1)
                }
            }
            .frame(width: 386)
            .modifier(OnbGlass())
            .modifier(OnbPanelIn(u: panelU))
            .offset(x: 160, y: 24)

            OnbKeycap(label: hotkey, t: t, a1: 0.02, a2: 0.05, p1: 0.07, p2: 0.09, o1: 0.11, o2: 0.14)
                .frame(maxWidth: .infinity)
                .offset(y: OnbStyle.stage.height - 36)
        }
        .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
        .clipped()
    }

    private func actionPill(icon: String, label: String, hot: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.system(size: 8.5))
        }
        .foregroundColor(hot ? .white : OnbStyle.text)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hot ? OnbStyle.blue : Color.white.opacity(0.75))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(hot ? Color.clear : OnbStyle.sep, lineWidth: 1))
        .lineLimit(1)
        .fixedSize()
    }

    /// Document table in the host window / attachment thumb.
    private func docTable(font: CGFloat) -> some View {
        let pad = font * 0.55
        return VStack(spacing: 0) {
            tableRow(L("obs.s2.h.channel"), "Q2", "Q3", "Δ", font: font, pad: pad, header: true)
            ForEach(0..<3, id: \.self) { i in
                tableRow(rows[i].0, rows[i].1, rows[i].2, rows[i].3, font: font, pad: pad, header: false)
            }
        }
    }

    private func tableRow(_ a: String, _ b: String, _ c: String, _ d: String,
                          font: CGFloat, pad: CGFloat, header: Bool) -> some View {
        HStack(spacing: 0) {
            // Narrow number columns so the channel name still gets room in
            // the 74pt attachment thumbnail.
            Text(a).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(width: font * 3.6, alignment: .trailing)
            Text(c).frame(width: font * 3.6, alignment: .trailing)
            Text(d).frame(width: font * 4.6, alignment: .trailing)
        }
        .font(.system(size: font, weight: header ? .bold : .regular).monospacedDigit())
        .foregroundColor(header ? OnbStyle.sec : OnbStyle.text)
        .padding(.vertical, pad)
        .overlay(
            Rectangle().fill(Color.black.opacity(header ? 0.18 : 0.07)).frame(height: 1),
            alignment: .bottom
        )
        .lineLimit(1)
    }

    /// Markdown table in the chat, rows appearing one by one.
    private func mdTable(rowU: [Double]) -> some View {
        VStack(spacing: 0) {
            mdRow(L("obs.s2.h.channel"), "Q2", "Q3", "Δ", bold: true, u: rowU[0], header: true)
            mdRow(rows[0].0, rows[0].1, rows[0].2, rows[0].3, bold: false, u: rowU[1], header: false)
            mdRow(rows[1].0, rows[1].1, rows[1].2, rows[1].3, bold: false, u: rowU[2], header: false)
            mdRow(rows[2].0, rows[2].1, rows[2].2, rows[2].3, bold: false, u: rowU[3], header: false)
            mdRow(L("obs.s2.total"), dec("10,5"), dec("12,4"), "+18 %", bold: true, u: rowU[4], header: false)
        }
    }

    private func mdRow(_ a: String, _ b: String, _ c: String, _ d: String,
                       bold: Bool, u: Double, header: Bool) -> some View {
        HStack(spacing: 0) {
            Text(a).fontWeight(bold ? .bold : .regular).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(width: 44, alignment: .trailing)
            Text(c).fontWeight(bold && !header ? .bold : .regular).frame(width: 44, alignment: .trailing)
            Text(d).frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 8).monospacedDigit())
        .foregroundColor(OnbStyle.text)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .overlay(
            Rectangle().fill(Color.black.opacity(header ? 0.22 : 0.07)).frame(height: 1),
            alignment: .bottom
        )
        .opacity(u)
        .lineLimit(1)
    }
}

// MARK: - Scene 3 · Dictation with translation

struct OnbSceneDictation: View {
    let t: Double
    let time: Double
    let hotkey: String

    private static let eqDurations: [Double] = [0.90, 0.72, 1.05, 0.83, 0.95, 0.68, 1.10, 0.78]

    var body: some View {
        let pillU = onbIn(t, 0.09, 0.15)
        let heardOn = onbIn(t, 0.15, 0.19)
        let h1U = onbSeg(t, 0.18, 0.34)
        let h2U = onbSeg(t, 0.50, 0.66)
        let p1U = onbSeg(t, 0.24, 0.42)
        let p2U = onbSeg(t, 0.56, 0.76)
        let langBlink = onbSeg(t, 0.26, 0.30) - onbSeg(t, 0.30, 0.36)
        let eqAlive = onbSeg(t, 0.12, 0.17)
        let doneU = onbIn(t, 0.76, 0.80)

        ZStack(alignment: .topLeading) {
            OnbWallpaper()
            OnbMenuBar(app: "Telegram", compact: true)

            // camera notch
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(Color(red: 0.031, green: 0.035, blue: 0.047))
                .frame(width: 108, height: 21)
                .overlay(Circle().fill(Color(red: 0.137, green: 0.153, blue: 0.184)).frame(width: 5, height: 5).offset(y: 2.5))
                .frame(maxWidth: .infinity)

            // dictation pill
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.271, blue: 0.227)).frame(width: 6, height: 6)
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { i in
                        let dur = Self.eqDurations[i]
                        let v = 0.16 + 0.84 * abs(sin(.pi * (time / dur + Double(i) * 0.13))) * eqAlive
                        Capsule()
                            .fill(Color(red: 0.498, green: 0.827, blue: 1))
                            .frame(width: 2, height: 13)
                            .scaleEffect(x: 1, y: v, anchor: .center)
                    }
                }
                .frame(height: 14)
                Text("EN → ES")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .fill(Color(red: 0.498, green: 0.827, blue: 1).opacity(0.75 * langBlink)))
                    )
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(red: 0.078, green: 0.086, blue: 0.11).opacity(0.86)))
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 10, y: 8)
            .scaleEffect(0.9 + 0.1 * pillU)
            .offset(y: 25 - 28 * (1 - pillU))
            .opacity(pillU)
            .frame(maxWidth: .infinity)

            // what is being heard (EN)
            HStack(spacing: 5) {
                Text(L("obs.s3.saying")).opacity(0.55)
                HStack(spacing: 0) {
                    OnbTyped(text: "Sorry for the delay,", u: h1U, size: 9, color: .white, reserve: false).fixedSize()
                    OnbTyped(text: " I'll send the file tonight", u: h2U, size: 9, color: .white, reserve: false).fixedSize()
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(red: 0.07, green: 0.078, blue: 0.102).opacity(0.55)))
            .opacity(heardOn)
            .frame(maxWidth: .infinity)
            .offset(y: 56)

            // Telegram window with the translation typed into its field
            OnbHostWindow(title: "Telegram — Lucía Fernández", size: CGSize(width: 370, height: 180)) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        tgBubble("¿Cómo va la presentación?", incoming: true)
                        tgBubble("¡Casi lista!", incoming: false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        tgBubble("¿Me la mandas hoy?", incoming: true)
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 8)
                    Spacer(minLength: 0)
                    // The point of the scene: the text landed in someone
                    // else's field and that app never noticed.
                    HStack(spacing: 5) {
                        Circle().fill(Color(red: 0.204, green: 0.780, blue: 0.349))
                            .frame(width: 5, height: 5)
                        Text(L("obs.s3.inserted"))
                            .font(.system(size: 8))
                            .foregroundColor(OnbStyle.sec)
                    }
                    .padding(.horizontal, 11)
                    .opacity(doneU)
                    .offset(y: 4 * (1 - doneU))
                    HStack(spacing: 6) {
                        HStack(spacing: 0) {
                            OnbTyped(text: "Perdona el retraso —", u: p1U, size: 9, reserve: false).fixedSize()
                            OnbTyped(text: " te envío el archivo esta noche.", u: p2U, size: 9, reserve: false).fixedSize()
                            OnbCaret(time: time, height: 9)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11))
                            .foregroundColor(OnbStyle.blue)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.98, green: 0.98, blue: 0.988))
                    .overlay(Rectangle().fill(OnbStyle.sep).frame(height: 1), alignment: .top)
                }
            }
            .offset(x: 96, y: 86)

            OnbKeycap(label: hotkey, t: t, a1: 0.02, a2: 0.05, p1: 0.07, p2: 0.10, o1: 0.12, o2: 0.15)
                .frame(maxWidth: .infinity)
                .offset(y: OnbStyle.stage.height - 36)
        }
        .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
        .clipped()
    }

    private func tgBubble(_ text: String, incoming: Bool) -> some View {
        Text(text)
            .font(.system(size: 8.5))
            .foregroundColor(OnbStyle.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(incoming
                        ? Color(red: 0.937, green: 0.937, blue: 0.949)
                        : Color(red: 0.851, green: 0.941, blue: 0.835))
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 9,
                bottomLeadingRadius: incoming ? 3 : 9,
                bottomTrailingRadius: incoming ? 9 : 3,
                topTrailingRadius: 9))
    }
}

// MARK: - Scene 4 · World Time

struct OnbSceneWorldTime: View {
    let t: Double
    let time: Double
    /// Real hotkey strings shown in the status menu mock.
    let menuHotkeys: (panel: String, shot: String, area: String, dictate: String, translate: String)

    private struct City {
        let name: String, country: String, abbr: String
        let offset: Int
        let clock: String, date: String
        let chip: (String, String, String)
    }

    private var cities: [City] {
        let thu = (L("obs.s4.chipThu"), "23", L("obs.s4.chipMon"))
        let fri = (L("obs.s4.chipFri"), "24", L("obs.s4.chipMon"))
        return [
            City(name: L("obs.s4.c1"), country: L("obs.s4.c1c"), abbr: "MSK", offset: 0,
                 clock: "13:04", date: L("obs.s4.date"), chip: thu),
            City(name: L("obs.s4.c2"), country: L("obs.s4.c2c"), abbr: "BST", offset: -2,
                 clock: "11:04", date: L("obs.s4.date"), chip: thu),
            City(name: L("obs.s4.c3"), country: L("obs.s4.c3c"), abbr: "EDT", offset: -7,
                 clock: "06:04", date: L("obs.s4.date"), chip: thu),
            // Tokyo is still on the same day at 19:04 — only its midnight
            // chip lands on the next date inside the grid.
            City(name: L("obs.s4.c4"), country: L("obs.s4.c4c"), abbr: "JST", offset: 6,
                 clock: "19:04", date: L("obs.s4.date"), chip: fri)
        ]
    }

    // Grid geometry (panel-content coordinates)
    private let headW: CGFloat = 146
    private let bandW: CGFloat = 376
    private var cellW: CGFloat { bandW / 24 }
    private let nowCol = 13
    private let selCol = 15
    private let rowH: CGFloat = 26
    private let rowGap: CGFloat = 4

    var body: some View {
        let menuOn = onbIn(t, 0.04, 0.09) - onbSeg(t, 0.20, 0.25)
        let hlU = onbSeg(t, 0.10, 0.13)
        let panelU = onbIn(t, 0.20, 0.28)
        let rowsU = [onbIn(t, 0.28, 0.34), onbIn(t, 0.31, 0.37), onbIn(t, 0.34, 0.40), onbIn(t, 0.37, 0.43)]
        let hovOn = onbSeg(t, 0.46, 0.49) - onbSeg(t, 0.58, 0.61)
        let hovX = onbSeg(t, 0.49, 0.58)                  // linear travel to the column
        let selOn = onbIn(t, 0.59, 0.62)
        let splitOn = onbSeg(t, 0.67, 0.70)
        let popU = onbIn(t, 0.73, 0.78)

        ZStack(alignment: .topLeading) {
            OnbWallpaper()
            OnbMenuBar(app: "Finder", hot: true)

            // Status-bar menu
            VStack(alignment: .leading, spacing: 0) {
                menuItem(icon: "brain", label: L("menu.open"), key: menuHotkeys.panel)
                menuItem(icon: "camera.viewfinder", label: L("menu.fullShot"), key: menuHotkeys.shot)
                menuItem(icon: "camera.viewfinder", label: L("menu.areaShot"), key: menuHotkeys.area)
                menuSep()
                menuItem(icon: "clock", label: WTL("wt.menu.open"), key: nil, highlight: hlU)
                menuSep()
                menuItem(icon: "mic.fill", label: L("menu.dictate"), key: menuHotkeys.dictate)
                menuItem(icon: "globe", label: L("menu.dictateTranslate"), key: menuHotkeys.translate)
            }
            .padding(4)
            .frame(width: 224)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(red: 0.98, green: 0.98, blue: 0.988).opacity(0.92))
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
            .opacity(menuOn)
            .offset(x: OnbStyle.stage.width - 224 - 14, y: 26 - 7 * (1 - onbIn(t, 0.04, 0.09)))

            // World Time panel
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 7))
                        Text(WTL("wt.search.placeholder"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.black.opacity(0.06)))
                    Spacer()
                    Text(WTL("wt.openCalendar")).foregroundColor(OnbStyle.blue).underline().fontWeight(.medium)
                    HStack(spacing: 1) {
                        Text("AM/PM").padding(.horizontal, 5).padding(.vertical, 1)
                        Text("24").fontWeight(.medium).foregroundColor(OnbStyle.text)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white)
                                .shadow(color: .black.opacity(0.18), radius: 0.8, y: 1))
                    }
                    .font(.system(size: 6.5))
                    .padding(1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.06)))
                    Text(WTL("wt.escHint")).opacity(0.55).font(.system(size: 6.5))
                }
                .font(.system(size: 7))
                .foregroundColor(OnbStyle.sec)
                .padding(.horizontal, 1)
                .padding(.bottom, 7)

                // day strip
                HStack(spacing: 2) {
                    ForEach(dayStrip.indices, id: \.self) { i in
                        let d = dayStrip[i]
                        Text(d.0)
                            .font(.system(size: 7, weight: d.1 == 1 ? .semibold : .regular))
                            .foregroundColor(d.1 == 2 ? Color(red: 1, green: 0.231, blue: 0.188).opacity(0.8)
                                             : (d.1 == 1 ? OnbStyle.text : OnbStyle.sec))
                            .padding(.horizontal, d.1 == 1 ? 8 : 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(d.1 == 1 ? 0.1 : 0)))
                    }
                }
                .padding(.leading, headW)
                .padding(.bottom, 7)

                // grid
                ZStack(alignment: .topLeading) {
                    VStack(spacing: rowGap) {
                        ForEach(0..<4, id: \.self) { i in
                            cityRow(cities[i])
                                .opacity(rowsU[i])
                                .offset(x: -8 * (1 - rowsU[i]))
                        }
                    }

                    let gridH = 4 * rowH + 3 * rowGap
                    // hover frame traveling to the selected column
                    columnFrame(stroke: Color.black.opacity(0.35), lineWidth: 1.2, fill: .clear, height: gridH)
                        .offset(x: headW - 2 + CGFloat(selCol) * cellW * hovX, y: -3)
                        .opacity(hovOn)
                    // selected column
                    columnFrame(stroke: Color.black.opacity(0.8), lineWidth: 1.5,
                                fill: Color.black.opacity(0.05), height: gridH)
                        .offset(x: headW - 2 + CGFloat(selCol) * cellW, y: -3)
                        .opacity(selOn)
                    // half-hour split
                    OnbDashedLine(vertical: true)
                        .foregroundColor(Color.black.opacity(0.42))
                        .frame(width: 1, height: gridH + 6)
                        .offset(x: headW + (CGFloat(selCol) + 0.5) * cellW, y: -3)
                        .opacity(splitOn)

                    // event popover
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 8))
                            Text(L("obs.s4.meeting")).font(.system(size: 7.5, weight: .semibold))
                        }
                        Text(L("obs.s4.meetingTitle"))
                            .font(.system(size: 6.5)).foregroundColor(OnbStyle.sec)
                            .padding(.horizontal, 5)
                            .frame(height: 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.05)))
                        HStack(spacing: 4) {
                            Spacer()
                            Text(L("local.cancel"))
                                .font(.system(size: 6.5)).foregroundColor(OnbStyle.sec)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)))
                            Text(L("obs.s4.create"))
                                .font(.system(size: 6.5, weight: .semibold)).foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(OnbStyle.blue))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(width: 154)
                    .background(
                        OnbPopoverShape(arrowX: 66.5)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
                    )
                    .overlay(OnbPopoverShape(arrowX: 66.5).stroke(Color.black.opacity(0.08), lineWidth: 1))
                    .offset(x: headW + (CGFloat(selCol) + 0.5) * cellW - 66.5, y: 124)
                    .opacity(popU)
                    .scaleEffect(0.96 + 0.04 * popU)
                }
                .padding(.top, 2)
            }
            .foregroundColor(OnbStyle.text)
            .padding(.top, 8)
            .padding(.horizontal, 9)
            // Bottom room for the event popover hanging under the grid.
            .padding(.bottom, 74)
            .frame(width: 540)
            .modifier(OnbGlass(cornerRadius: 12))
            .modifier(OnbPanelIn(u: panelU, dy: 10))
            .offset(x: 10, y: 34)
        }
        .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
        .clipped()
    }

    private var dayStrip: [(String, Int)] {
        [("20", 0), ("21", 0), ("22", 0), (L("obs.s4.stripSel"), 1), ("24", 0), ("25", 2), ("26", 2), ("27", 0)]
    }

    private func menuItem(icon: String, label: String, key: String?, highlight: Double = 0) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).frame(width: 12)
            Text(label).font(.system(size: 9.5))
            Spacer()
            if let key {
                Text(key)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(OnbStyle.sec)
            }
        }
        .foregroundColor(highlight > 0.5 ? .white : OnbStyle.text)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 5).fill(OnbStyle.blue.opacity(highlight)))
    }

    private func menuSep() -> some View {
        Rectangle().fill(Color.black.opacity(0.09)).frame(height: 1)
            .padding(.horizontal, 7).padding(.vertical, 3)
    }

    private func columnFrame(stroke: Color, lineWidth: CGFloat, fill: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: lineWidth))
            .frame(width: cellW + 4, height: height + 6)
    }

    private func cityRow(_ city: City) -> some View {
        HStack(spacing: 0) {
            // row header
            HStack(spacing: 5) {
                Group {
                    if city.offset == 0 {
                        Image(systemName: "house.fill").font(.system(size: 7))
                    } else {
                        Text(city.offset < 0 ? "−\(-city.offset)" : "+\(city.offset)")
                            .font(.system(size: 7, weight: .semibold).monospacedDigit())
                    }
                }
                .foregroundColor(OnbStyle.sec)
                .frame(width: 15, alignment: .trailing)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(city.name).font(.system(size: 8, weight: .semibold))
                            .lineLimit(1).fixedSize()
                        Text(city.abbr)
                            .font(.system(size: 5, weight: .medium))
                            .foregroundColor(OnbStyle.sec)
                            .padding(.horizontal, 3).padding(.vertical, 0.5)
                            .background(Capsule().fill(Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.16)))
                    }
                    Text(city.country).font(.system(size: 6)).foregroundColor(OnbStyle.sec)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(city.clock).font(.system(size: 8, weight: .semibold).monospacedDigit())
                    Text(city.date).font(.system(size: 6)).foregroundColor(OnbStyle.sec)
                        .lineLimit(1).fixedSize()
                }
            }
            .frame(width: headW - 7, alignment: .leading)
            .padding(.trailing, 7)

            // 24-hour band
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { col in
                    cell(col: col, city: city)
                }
            }
            .frame(width: bandW, height: rowH)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
        }
        .frame(height: rowH)
    }

    private func cell(col: Int, city: City) -> some View {
        let local = ((col + city.offset) % 24 + 24) % 24
        let isNow = col == nowCol
        return ZStack {
            cellBackground(local)
            if local == 0 {
                VStack(spacing: -0.5) {
                    Text(city.chip.0).font(.system(size: 4.5, weight: .bold))
                    Text(city.chip.1).font(.system(size: 7, weight: .bold))
                    Text(city.chip.2).font(.system(size: 4.5, weight: .bold))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(.white)
            } else {
                Text("\(local)")
                    .font(.system(size: 7.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(local < 6 || local >= 22 ? .white : OnbStyle.text)
            }
            if isNow {
                OnbDashedLine(vertical: false)
                    .foregroundColor(local < 6 || local >= 22 || local == 0
                                     ? Color.white.opacity(0.85) : Color.black.opacity(0.5))
                    .frame(height: 1.5)
                    .padding(.horizontal, 3)
                    .offset(y: rowH / 2 - 5)
            }
        }
        .frame(width: cellW, height: rowH)
        .overlay(Rectangle().fill(Color.white.opacity(col == 0 ? 0 : 0.22)).frame(width: 0.5), alignment: .leading)
    }

    @ViewBuilder private func cellBackground(_ local: Int) -> some View {
        if local == 0 {
            Color(red: 0.149, green: 0.2, blue: 0.631).opacity(0.85)
        } else if local < 6 || local >= 22 {
            Color(red: 0.251, green: 0.329, blue: 0.82).opacity(0.55)
        } else if local >= 9 && local < 18 {
            Color.white.opacity(0.32)
        } else {
            Color(red: 0.98, green: 0.8, blue: 0.388).opacity(0.38)
        }
    }
}

/// Dashed 1px line (the mock's repeating-linear-gradient).
struct OnbDashedLine: View {
    let vertical: Bool
    var body: some View {
        GeometryReader { geo in
            Path { p in
                if vertical {
                    p.move(to: .zero)
                    p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                } else {
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
            }
            .stroke(style: StrokeStyle(lineWidth: vertical ? 1 : geo.size.height, dash: [3, 2.5]))
        }
    }
}

/// Popover bubble with a top arrow.
struct OnbPopoverShape: Shape {
    let arrowX: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r: CGFloat = 8
        let a: CGFloat = 4.5
        let body = CGRect(x: rect.minX, y: rect.minY + a, width: rect.width, height: rect.height - a)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: r, height: r))
        p.move(to: CGPoint(x: arrowX - a, y: body.minY))
        p.addLine(to: CGPoint(x: arrowX, y: rect.minY))
        p.addLine(to: CGPoint(x: arrowX + a, y: body.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Scene 5 · Image operations

struct OnbSceneImage: View {
    let t: Double
    let time: Double

    private let photoSize = CGSize(width: 196, height: 132)

    var body: some View {
        let panelU = onbIn(t, 0.03, 0.09)
        let barU = onbIn(t, 0.08, 0.13)
        // 1 · remove background
        let hot1 = onbSeg(t, 0.15, 0.17) - onbSeg(t, 0.31, 0.35)
        let prog1 = onbSeg(t, 0.16, 0.31)
        let wipeU = onbSeg(t, 0.18, 0.30)
        let wipeOn = onbSeg(t, 0.18, 0.20) - onbSeg(t, 0.30, 0.32)
        let cutGlow = onbSeg(t, 0.31, 0.34) - onbSeg(t, 0.40, 0.45)
        let res1 = onbIn(t, 0.33, 0.36) - onbSeg(t, 0.49, 0.52)
        // 2 · upscale
        let hot2 = onbSeg(t, 0.43, 0.45) - onbSeg(t, 0.57, 0.61)
        let prog2 = onbSeg(t, 0.44, 0.57)
        let sharpU = onbSeg(t, 0.46, 0.58)
        let loupeOn = onbSeg(t, 0.45, 0.48) - onbSeg(t, 0.60, 0.64)
        let loupeU = onbSeg(t, 0.48, 0.57)
        let res2 = onbIn(t, 0.57, 0.60) - onbSeg(t, 0.70, 0.73)
        // 3 · remove objects
        let hot3 = onbSeg(t, 0.64, 0.66) - onbSeg(t, 0.79, 0.83)
        let prog3 = onbSeg(t, 0.65, 0.79)
        let brushW = onbSeg(t, 0.68, 0.74)
        let brushOn = onbSeg(t, 0.66, 0.68) - onbSeg(t, 0.78, 0.83)
        let blobGone = onbSeg(t, 0.77, 0.84)
        let res3 = onbIn(t, 0.83, 0.86)

        ZStack(alignment: .topLeading) {
            OnbWallpaper()
            OnbMenuBar(app: "AISpotlight")

            VStack(spacing: 0) {
                OnbPanelHeader(provider: .mistral, providerName: "Mistral", preset: "Assistant")

                HStack(alignment: .top, spacing: 12) {
                    // Photo
                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            OnbChecker()
                            // Background layer, wiped away to the right
                            ZStack(alignment: .topLeading) {
                                LinearGradient(
                                    colors: [Color(red: 0.965, green: 0.808, blue: 0.525),
                                             Color(red: 0.890, green: 0.545, blue: 0.420),
                                             Color(red: 0.557, green: 0.329, blue: 0.463)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                                Circle().fill(Color.white.opacity(0.62))
                                    .frame(width: 30, height: 30)
                                    .offset(x: 20, y: 16)
                                Ellipse().fill(Color.black.opacity(0.26))
                                    .frame(width: 92, height: 12)
                                    .blur(radius: 3)
                                    .offset(x: 52, y: photoSize.height - 34)
                            }
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: photoSize.width * (1 - wipeU))
                            }

                            // Mug (stays after background removal)
                            OnbMug()
                                .shadow(color: OnbStyle.blue.opacity(0.95 * cutGlow), radius: 2)
                                .shadow(color: OnbStyle.blue.opacity(0.5 * cutGlow), radius: 5)
                                .offset(x: 70, y: photoSize.height - 26 - 64)

                            // Brown blob to be erased
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.431, green: 0.294, blue: 0.18))
                                .frame(width: 28, height: 19)
                                .rotationEffect(.degrees(-8))
                                .opacity(1 - blobGone)
                                .blur(radius: 3 * blobGone)
                                .offset(x: photoSize.width - 18 - 28, y: photoSize.height - 30 - 19)

                            // Brush stroke over the blob
                            Capsule()
                                .fill(OnbStyle.blue.opacity(0.55))
                                .frame(width: max(0.1, 52 * brushW), height: 30)
                                .opacity(brushOn)
                                .offset(x: photoSize.width - 11 - 52 * brushW, y: photoSize.height - 25 - 30)

                            // Background-removal wipe bar
                            Rectangle()
                                .fill(LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.9)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: 16, height: photoSize.height)
                                .overlay(Rectangle().fill(Color.white).frame(width: 1.5), alignment: .trailing)
                                .shadow(color: Color.white.opacity(0.75), radius: 7)
                                .offset(x: -18 + (photoSize.width + 18) * wipeU)
                                .opacity(wipeOn)
                        }
                        .frame(width: photoSize.width, height: photoSize.height)
                        .blur(radius: 1.6 * (1 - sharpU))
                        .saturation(0.9 + 0.1 * sharpU)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(OnbStyle.sep, lineWidth: 1))

                        // Upscale loupe
                        Circle()
                            .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
                            .background(Circle().stroke(Color.black.opacity(0.22), lineWidth: 3.5))
                            .frame(width: 60, height: 60)
                            .shadow(color: .black.opacity(0.5), radius: 7, y: 5)
                            .offset(x: 8 + 120 * loupeU, y: 22 + 34 * loupeU)
                            .opacity(loupeOn)
                    }

                    // Actions + results + note
                    VStack(alignment: .leading, spacing: 9) {
                        // Wrapping action pills (two rows like the mock)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                imgPill(icon: "person.and.background.dotted",
                                        label: IAL("ia.action.removeBg"), hot: hot1, progress: prog1)
                                imgPill(icon: "arrow.up.backward.and.arrow.down.forward.rectangle",
                                        label: IAL("ia.action.upscale") + " ×4", hot: hot2, progress: prog2)
                            }
                            imgPill(icon: "eraser", label: IAL("ia.action.cleanup"), hot: hot3, progress: prog3)
                        }
                        .opacity(barU)
                        .offset(y: 5 * (1 - barU))

                        ZStack(alignment: .topLeading) {
                            resultLine(L("obs.s5.r1")).opacity(res1)
                            resultLine(L("obs.s5.r2")).opacity(res2)
                            resultLine(L("obs.s5.r3")).opacity(res3)
                        }
                        .frame(height: 15)

                        Text(L("obs.s5.note"))
                            .font(.system(size: 9))
                            .foregroundColor(OnbStyle.sec)
                            .lineSpacing(3)
                            .opacity(barU)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 7)

                OnbComposer {
                    Text(L("obs.s5.ph"))
                        .font(.system(size: 10))
                        .foregroundColor(OnbStyle.sec)
                }
            }
            .frame(width: 456)
            .modifier(OnbGlass())
            .modifier(OnbPanelIn(u: panelU))
            .offset(x: 52, y: 42)
        }
        .frame(width: OnbStyle.stage.width, height: OnbStyle.stage.height)
        .clipped()
    }

    private func imgPill(icon: String, label: String, hot: Double, progress: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 9.5))
        }
        .foregroundColor(hot > 0.5 ? .white : OnbStyle.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(hot > 0.5 ? OnbStyle.blue : Color.white.opacity(0.75))
                Rectangle()
                    .fill(hot > 0.5 ? Color.white.opacity(0.85) : OnbStyle.blue)
                    .frame(height: 2)
                    .scaleEffect(x: max(progress, 0.001), y: 1, anchor: .leading)
                    .opacity(progress > 0 && progress < 1 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(hot > 0.5 ? Color.clear : OnbStyle.sep, lineWidth: 1))
        .fixedSize()
    }

    private func resultLine(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
            Text(text).font(.system(size: 9))
        }
        .foregroundColor(OnbStyle.green)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Transparency checkerboard behind the photo.
struct OnbChecker: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let s: CGFloat = 6.5
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                                 with: .color(.black.opacity(0.08)))
                    }
                    x += s; col += 1
                }
                y += s; row += 1
            }
        }
    }
}

/// The mug that survives background removal.
struct OnbMug: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            // handle (drawn first, body covers its left side)
            UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14)
                .stroke(Color(red: 0.231, green: 0.341, blue: 0.443), lineWidth: 6)
                .frame(width: 21, height: 26)
                .offset(x: 56 - 6, y: 17)
            // body
            UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 17,
                                   bottomTrailingRadius: 17, topTrailingRadius: 7)
                .fill(LinearGradient(colors: [Color(red: 0.231, green: 0.341, blue: 0.443),
                                              Color(red: 0.106, green: 0.161, blue: 0.220)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 64)
            // rim
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(red: 0.318, green: 0.439, blue: 0.561))
                .frame(width: 56, height: 9)
        }
        .frame(width: 56 + 15, height: 64, alignment: .topLeading)
    }
}
