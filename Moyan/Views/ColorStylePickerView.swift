import SwiftUI

/// 字体颜色 / 背景颜色选择面板（工具栏弹层）。
struct ColorStylePickerView: View {
    var onForeground: (String) -> Void
    var onBackground: (String?) -> Void
    var onReset: () -> Void

    private let swatch: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("字体颜色")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(MarkdownColorSupport.foregroundColors) { color in
                    Button {
                        onForeground(color.hex)
                    } label: {
                        Text("A")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(nsColor: color.nsColor))
                            .frame(width: swatch, height: swatch)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(color.label)
                }
            }

            Text("背景颜色")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    noneSwatch
                    ForEach(MarkdownColorSupport.backgroundLightColors) { color in
                        bgSwatch(color)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(MarkdownColorSupport.backgroundSolidColors) { color in
                        bgSwatch(color)
                    }
                }
            }

            Button(action: onReset) {
                Text("恢复默认")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var noneSwatch: some View {
        Button {
            onBackground(nil)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .background(Color.white.opacity(0.001))
                Path { path in
                    path.move(to: CGPoint(x: 4, y: swatch - 4))
                    path.addLine(to: CGPoint(x: swatch - 4, y: 4))
                }
                .stroke(Color.accentColor.opacity(0.85), lineWidth: 1.5)
            }
            .frame(width: swatch, height: swatch)
        }
        .buttonStyle(.plain)
        .help("无填充")
    }

    private func bgSwatch(_ color: MarkdownColorSupport.PaletteColor) -> some View {
        Button {
            onBackground(color.hex)
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: color.nsColor))
                .frame(width: swatch, height: swatch)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(color.label)
    }
}
